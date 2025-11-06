//
//  NetworkServer.swift
//  AvoCam
//
//  HTTP REST + WebSocket server using SwiftNIO
//

import Foundation
import NIO
import NIOHTTP1
import NIOWebSocket

// MARK: - Request Handler Protocol

protocol NetworkRequestHandler: AnyObject {
    func handleStreamStart(_ request: StreamStartRequest) async throws
    func handleStreamStop() async throws
    func handleCameraSettings(_ settings: CameraSettingsRequest) async throws
    func handleForceKeyframe()
    func handleGetStatus() async -> StatusResponse
    func handleGetCapabilities() async -> [Capability]
    func handleGetVideoSettings() async -> VideoSettingsResponse
    func handleUpdateVideoSettings(_ request: VideoSettingsUpdateRequest) async throws
    func handleScreenBrightness(_ request: ScreenBrightnessRequest)
}

// MARK: - Network Server

class NetworkServer {
    // MARK: - Properties

    private let port: Int
    private let bearerToken: String
    private weak var requestHandler: NetworkRequestHandler?
    private var isAuthenticationEnabled: Bool = false

    private var group: MultiThreadedEventLoopGroup?
    private var bootstrap: ServerBootstrap?
    private var channel: Channel?

    // WebSocket clients
    private var wsClients: [WebSocketClient] = []
    private let wsClientsLock = NSLock()

    // Rate limiting
    private var lastCameraUpdateTime: Date = Date.distantPast
    private let minCameraUpdateInterval: TimeInterval = 0.05 // 50ms debounce

    // MARK: - Initialization

    init(port: Int, bearerToken: String, requestHandler: NetworkRequestHandler?) {
        self.port = port
        self.bearerToken = bearerToken
        self.requestHandler = requestHandler
        self.isAuthenticationEnabled = false
    }
    
    func setAuthenticationEnabled(_ enabled: Bool) {
        self.isAuthenticationEnabled = enabled
    }

    // MARK: - Server Control

    func start() throws {
        print("🌐 Starting HTTP/WebSocket server on port \(port)")

        group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        guard let group = group else {
            throw NetworkError.serverStartFailed
        }

        bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                guard let self = self else {
                    return channel.eventLoop.makeFailedFuture(NetworkError.serverStartFailed)
                }

                // Configure HTTP pipeline with WebSocket upgrade support
                let upgrader = NIOWebSocketServerUpgrader(
                    shouldUpgrade: { (channel: Channel, head: HTTPRequestHead) in
                        // Check for WebSocket upgrade request
                        guard head.uri == "/ws",
                              head.headers["upgrade"].first?.lowercased() == "websocket" else {
                            return channel.eventLoop.makeSucceededFuture(nil)
                        }

                        // Validate bearer token if authentication is enabled
                        if self.isAuthenticationEnabled {
                            guard let authHeader = head.headers["authorization"].first,
                                  authHeader.hasPrefix("Bearer "),
                                  authHeader.dropFirst("Bearer ".count) == self.bearerToken else {
                                return channel.eventLoop.makeSucceededFuture(nil)
                            }
                        }

                        return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                    },
                    upgradePipelineHandler: { (channel: Channel, _: HTTPRequestHead) in
                        // Add WebSocket handler to the pipeline
                        // NIO automatically removes HTTP decoder/encoder before calling this
                        let wsHandler = WebSocketServerHandler(server: self)
                        return channel.pipeline.addHandler(wsHandler).flatMap {
                            // After adding WS handler, try to remove HTTP handler
                            // If it fails, mark it as upgraded so it ignores future data
                            channel.pipeline.context(name: "HTTPHandler").flatMap { context in
                                if let httpHandler = context.handler as? HTTPServerHandler {
                                    httpHandler.markAsUpgraded()
                                }
                                return channel.eventLoop.makeSucceededFuture(())
                            }.recover { _ in
                                // Handler doesn't exist or can't be accessed, that's OK
                            }
                        }
                    }
                )

                return channel.pipeline.configureHTTPServerPipeline(
                    withPipeliningAssistance: false,
                    withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in })
                ).flatMap {
                    channel.pipeline.addHandler(HTTPServerHandler(server: self), name: "HTTPHandler")
                }
            }

        guard let bootstrap = bootstrap else {
            throw NetworkError.serverStartFailed
        }

        channel = try bootstrap.bind(host: "0.0.0.0", port: port).wait()

        print("✅ Server started on port \(port)")
    }

    func stop() {
        // Close all WebSocket connections
        wsClientsLock.lock()
        for client in wsClients {
            client.close()
        }
        wsClients.removeAll()
        wsClientsLock.unlock()

        // Shutdown server
        try? channel?.close().wait()
        try? group?.syncShutdownGracefully()

        channel = nil
        bootstrap = nil
        group = nil

        print("⏹ Server stopped")
    }

    // MARK: - WebSocket Management

    func addWebSocketClient(_ client: WebSocketClient) {
        wsClientsLock.lock()
        wsClients.append(client)
        wsClientsLock.unlock()

        print("🔌 WebSocket client connected (total: \(wsClients.count))")
    }

    func removeWebSocketClient(_ client: WebSocketClient) {
        wsClientsLock.lock()
        wsClients.removeAll { $0 === client }
        wsClientsLock.unlock()

        print("🔌 WebSocket client disconnected (total: \(wsClients.count))")
    }

    func broadcastTelemetry(_ telemetry: Telemetry, ndiState: NDIState) {
        wsClientsLock.lock()
        let clients = wsClients
        wsClientsLock.unlock()

        // Encode telemetry to JSON
        let message = WebSocketTelemetryMessage(
            fps: telemetry.fps,
            bitrate: telemetry.bitrate,
            queueMs: telemetry.queueMs ?? 0,
            battery: telemetry.battery,
            tempC: telemetry.tempC,
            wifiRssi: telemetry.wifiRssi,
            ndiState: ndiState,
            droppedFrames: telemetry.droppedFrames ?? 0,
            chargingState: telemetry.chargingState ?? .unplugged
        )

        guard let jsonData = try? JSONEncoder().encode(message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        // Send to all connected clients
        for client in clients {
            client.send(text: jsonString)
        }
    }

    // MARK: - Request Handling

    func handleHTTPRequest(path: String, method: String, headers: [String: String], body: Data?) async -> HTTPResponse {
        // Log incoming request
        print("📥 HTTP \(method) \(path)")

        // Authenticate if enabled
        if isAuthenticationEnabled {
            guard let authHeader = headers["Authorization"],
                  authHeader == "Bearer \(bearerToken)" else {
                print("⚠️ Authentication failed for \(method) \(path)")
                return HTTPResponse(
                    status: 401,
                    body: errorJSON(code: "UNAUTHORIZED", message: "Invalid or missing bearer token")
                )
            }
        }

        // Rate limiting for camera settings
        if path.contains("/camera") {
            let now = Date()
            if now.timeIntervalSince(lastCameraUpdateTime) < minCameraUpdateInterval {
                return HTTPResponse(
                    status: 429,
                    body: errorJSON(code: "RATE_LIMITED", message: "Too many camera updates, wait \(Int(minCameraUpdateInterval * 1000))ms")
                )
            }
            lastCameraUpdateTime = now
        }

        // Route request
        switch (method, path) {
        case ("GET", "/api/v1/status"):
            return await handleGetStatus()

        case ("GET", "/api/v1/capabilities"):
            return await handleGetCapabilities()

        case ("GET", "/api/v1/video/settings"):
            return await handleGetVideoSettings()

        case ("PUT", "/api/v1/video/settings"):
            return await handlePutVideoSettings(body: body)

        case ("POST", "/api/v1/stream/start"):
            return await handleStreamStart(body: body)

        case ("POST", "/api/v1/stream/stop"):
            return await handleStreamStop()

        case ("POST", "/api/v1/camera"):
            return await handleCameraSettings(body: body)

        case ("POST", "/api/v1/screen/brightness"):
            return handleScreenBrightness(body: body)

        case ("POST", "/api/v1/encoder/force_keyframe"):
            return handleForceKeyframe()

        case ("GET", "/api/v1/logs.zip"):
            return handleLogsDownload()

        case ("GET", "/"):
            return handleWebUI()

        default:
            print("❌ 404 Not Found: \(method) \(path)")
            return HTTPResponse(
                status: 404,
                body: errorJSON(code: "NOT_FOUND", message: "Endpoint not found: \(method) \(path)")
            )
        }
    }

    // MARK: - Endpoint Handlers

    private func handleGetStatus() async -> HTTPResponse {
        guard let handler = requestHandler else {
            return HTTPResponse(status: 500, body: errorJSON(code: "INTERNAL_ERROR", message: "No request handler"))
        }

        let status = await handler.handleGetStatus()
        guard let jsonData = try? JSONEncoder().encode(status) else {
            return HTTPResponse(status: 500, body: errorJSON(code: "ENCODING_ERROR", message: "Failed to encode status"))
        }

        return HTTPResponse(status: 200, body: jsonData)
    }

    private func handleGetCapabilities() async -> HTTPResponse {
        guard let handler = requestHandler else {
            return HTTPResponse(status: 500, body: errorJSON(code: "INTERNAL_ERROR", message: "No request handler"))
        }

        let capabilities = await handler.handleGetCapabilities()
        guard let jsonData = try? JSONEncoder().encode(capabilities) else {
            return HTTPResponse(status: 500, body: errorJSON(code: "ENCODING_ERROR", message: "Failed to encode capabilities"))
        }

        return HTTPResponse(status: 200, body: jsonData)
    }

    private func handleStreamStart(body: Data?) async -> HTTPResponse {
        guard let body = body,
              let request = try? JSONDecoder().decode(StreamStartRequest.self, from: body) else {
            print("⚠️ Invalid stream start request body")
            return HTTPResponse(status: 400, body: errorJSON(code: "INVALID_REQUEST", message: "Invalid stream start request"))
        }

        guard let handler = requestHandler else {
            print("⚠️ No request handler available")
            return HTTPResponse(status: 500, body: errorJSON(code: "INTERNAL_ERROR", message: "No request handler"))
        }

        do {
            try await handler.handleStreamStart(request)
            print("✅ Stream started: \(request.resolution)@\(request.framerate)fps")
            return HTTPResponse(status: 200, body: successJSON(message: "Stream started"))
        } catch {
            print("❌ Stream start failed: \(error.localizedDescription)")
            return HTTPResponse(status: 500, body: errorJSON(code: "STREAM_START_FAILED", message: error.localizedDescription))
        }
    }

    private func handleStreamStop() async -> HTTPResponse {
        guard let handler = requestHandler else {
            print("⚠️ No request handler available")
            return HTTPResponse(status: 500, body: errorJSON(code: "INTERNAL_ERROR", message: "No request handler"))
        }

        do {
            try await handler.handleStreamStop()
            print("✅ Stream stopped")
            return HTTPResponse(status: 200, body: successJSON(message: "Stream stopped"))
        } catch {
            print("❌ Stream stop failed: \(error.localizedDescription)")
            return HTTPResponse(status: 500, body: errorJSON(code: "STREAM_STOP_FAILED", message: error.localizedDescription))
        }
    }

    private func handleCameraSettings(body: Data?) async -> HTTPResponse {
        guard let body = body,
              let settings = try? JSONDecoder().decode(CameraSettingsRequest.self, from: body) else {
            return HTTPResponse(status: 400, body: errorJSON(code: "INVALID_REQUEST", message: "Invalid camera settings request"))
        }

        guard let handler = requestHandler else {
            return HTTPResponse(status: 500, body: errorJSON(code: "INTERNAL_ERROR", message: "No request handler"))
        }

        do {
            try await handler.handleCameraSettings(settings)
            return HTTPResponse(status: 200, body: successJSON(message: "Camera settings updated"))
        } catch {
            return HTTPResponse(status: 500, body: errorJSON(code: "CAMERA_UPDATE_FAILED", message: error.localizedDescription))
        }
    }

    private func handleScreenBrightness(body: Data?) -> HTTPResponse {
        guard let body = body,
              let request = try? JSONDecoder().decode(ScreenBrightnessRequest.self, from: body) else {
            return HTTPResponse(status: 400, body: errorJSON(code: "INVALID_REQUEST", message: "Invalid screen brightness request"))
        }

        guard let handler = requestHandler else {
            return HTTPResponse(status: 500, body: errorJSON(code: "INTERNAL_ERROR", message: "No request handler"))
        }

        handler.handleScreenBrightness(request)
        return HTTPResponse(status: 200, body: successJSON(message: "Screen brightness updated"))
    }

    private func handleForceKeyframe() -> HTTPResponse {
        guard let handler = requestHandler else {
            return HTTPResponse(status: 500, body: errorJSON(code: "INTERNAL_ERROR", message: "No request handler"))
        }

        handler.handleForceKeyframe()
        return HTTPResponse(status: 200, body: successJSON(message: "Keyframe forced"))
    }

    private func handleGetVideoSettings() async -> HTTPResponse {
        guard let handler = requestHandler else {
            return HTTPResponse(status: 500, body: errorJSON(code: "INTERNAL_ERROR", message: "No request handler"))
        }

        let settings = await handler.handleGetVideoSettings()
        guard let jsonData = try? JSONEncoder().encode(settings) else {
            return HTTPResponse(status: 500, body: errorJSON(code: "ENCODING_ERROR", message: "Failed to encode video settings"))
        }

        return HTTPResponse(status: 200, body: jsonData)
    }

    private func handlePutVideoSettings(body: Data?) async -> HTTPResponse {
        guard let body = body,
              let request = try? JSONDecoder().decode(VideoSettingsUpdateRequest.self, from: body) else {
            return HTTPResponse(status: 400, body: errorJSON(code: "INVALID_REQUEST", message: "Invalid video settings request"))
        }

        guard let handler = requestHandler else {
            return HTTPResponse(status: 500, body: errorJSON(code: "INTERNAL_ERROR", message: "No request handler"))
        }

        do {
            try await handler.handleUpdateVideoSettings(request)
            return HTTPResponse(status: 200, body: successJSON(message: "Video settings updated"))
        } catch {
            return HTTPResponse(status: 500, body: errorJSON(code: "VIDEO_SETTINGS_UPDATE_FAILED", message: error.localizedDescription))
        }
    }

    private func handleLogsDownload() -> HTTPResponse {
        // TODO: Implement rotating logs and zip creation
        return HTTPResponse(status: 501, body: errorJSON(code: "NOT_IMPLEMENTED", message: "Logs download not yet implemented"))
    }

    private func handleWebUI() -> HTTPResponse {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>AvoCam Control</title>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
            <meta charset="UTF-8">
            <style>
                * {
                    margin: 0;
                    padding: 0;
                    box-sizing: border-box;
                }
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
                    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                    min-height: 100vh;
                    padding: 20px;
                    color: #333;
                }
                .container {
                    max-width: 600px;
                    margin: 0 auto;
                }
                .card {
                    background: white;
                    border-radius: 16px;
                    padding: 24px;
                    margin-bottom: 16px;
                    box-shadow: 0 8px 32px rgba(0,0,0,0.1);
                }
                h1 {
                    font-size: 28px;
                    color: white;
                    margin-bottom: 20px;
                    text-align: center;
                    text-shadow: 0 2px 4px rgba(0,0,0,0.2);
                }
                h2 {
                    font-size: 20px;
                    margin-bottom: 16px;
                    color: #667eea;
                }
                .status-grid {
                    display: grid;
                    grid-template-columns: repeat(2, 1fr);
                    gap: 12px;
                    margin-bottom: 20px;
                }
                .status-item {
                    padding: 12px;
                    background: #f8f9fa;
                    border-radius: 8px;
                }
                .status-label {
                    font-size: 12px;
                    color: #666;
                    text-transform: uppercase;
                    letter-spacing: 0.5px;
                    margin-bottom: 4px;
                }
                .status-value {
                    font-size: 24px;
                    font-weight: 600;
                    color: #333;
                    font-family: 'SF Mono', Monaco, monospace;
                }
                .status-value.streaming {
                    color: #10b981;
                }
                .status-value.idle {
                    color: #6b7280;
                }
                button {
                    width: 100%;
                    padding: 16px;
                    border: none;
                    border-radius: 12px;
                    font-size: 16px;
                    font-weight: 600;
                    cursor: pointer;
                    transition: all 0.2s;
                    margin-bottom: 12px;
                }
                button:active {
                    transform: scale(0.98);
                }
                .btn-primary {
                    background: #667eea;
                    color: white;
                }
                .btn-primary:hover {
                    background: #5568d3;
                }
                .btn-danger {
                    background: #ef4444;
                    color: white;
                }
                .btn-danger:hover {
                    background: #dc2626;
                }
                .btn-secondary {
                    background: #f3f4f6;
                    color: #374151;
                }
                .btn-secondary:hover {
                    background: #e5e7eb;
                }
                .settings-row {
                    margin-bottom: 16px;
                }
                label {
                    display: block;
                    font-size: 14px;
                    font-weight: 500;
                    color: #374151;
                    margin-bottom: 8px;
                }
                input, select {
                    width: 100%;
                    padding: 12px;
                    border: 2px solid #e5e7eb;
                    border-radius: 8px;
                    font-size: 16px;
                    transition: border-color 0.2s;
                }
                input:focus, select:focus {
                    outline: none;
                    border-color: #667eea;
                }
                .connection-status {
                    display: inline-block;
                    padding: 6px 12px;
                    border-radius: 20px;
                    font-size: 12px;
                    font-weight: 600;
                    margin-bottom: 12px;
                }
                .connection-status.connected {
                    background: #d1fae5;
                    color: #065f46;
                }
                .connection-status.disconnected {
                    background: #fee2e2;
                    color: #991b1b;
                }
                .info-text {
                    font-size: 14px;
                    color: #6b7280;
                    text-align: center;
                    margin-top: 12px;
                }
            </style>
        </head>
        <body>
            <div class="container">
                <h1>🎥 AvoCam Control</h1>

                <div class="card">
                    <h2>Status</h2>
                    <div id="connection-indicator" class="connection-status disconnected">Disconnected</div>
                    <div class="status-grid">
                        <div class="status-item">
                            <div class="status-label">State</div>
                            <div id="ndi-state" class="status-value idle">Idle</div>
                        </div>
                        <div class="status-item">
                            <div class="status-label">FPS</div>
                            <div id="fps" class="status-value">0.0</div>
                        </div>
                        <div class="status-item">
                            <div class="status-label">Bitrate</div>
                            <div id="bitrate" class="status-value">0.0 Mbps</div>
                        </div>
                        <div class="status-item">
                            <div class="status-label">Battery</div>
                            <div id="battery" class="status-value">--</div>
                        </div>
                        <div class="status-item">
                            <div class="status-label">Temperature</div>
                            <div id="temp" class="status-value">--</div>
                        </div>
                        <div class="status-item">
                            <div class="status-label">WiFi RSSI</div>
                            <div id="wifi" class="status-value">--</div>
                        </div>
                    </div>
                </div>

                <div class="card">
                    <h2>Stream Control</h2>
                    <button id="btn-start" class="btn-primary">▶️ Start Stream</button>
                    <button id="btn-stop" class="btn-danger">⏹ Stop Stream</button>
                    <button id="btn-keyframe" class="btn-secondary">🔑 Force Keyframe</button>
                </div>

                <div class="card">
                    <h2>Camera Settings</h2>
                    <div class="settings-row">
                        <label for="wb-mode">White Balance</label>
                        <select id="wb-mode">
                            <option value="auto">Auto</option>
                            <option value="manual">Manual</option>
                        </select>
                    </div>
                    <div class="settings-row" id="wb-kelvin-row" style="display: none;">
                        <label for="wb-kelvin">WB Temperature (K)</label>
                        <input type="number" id="wb-kelvin" value="5000" min="2000" max="10000" step="100">
                    </div>
                    <div class="settings-row" id="wb-tint-row" style="display: none;">
                        <label for="wb-tint">Tint (Green ← -100 to +100 → Magenta)</label>
                        <input type="number" id="wb-tint" value="0" min="-100" max="100" step="1">
                    </div>
                    <div class="settings-row">
                        <label for="iso">ISO (0 = Auto)</label>
                        <input type="number" id="iso" value="0" min="0" max="3200" step="50">
                    </div>
                    <div class="settings-row">
                        <label for="zoom">Zoom Factor</label>
                        <input type="number" id="zoom" value="1.0" min="1.0" max="10.0" step="0.1">
                    </div>
                    <button id="btn-apply-settings" class="btn-primary">Apply Settings</button>
                </div>

                <div class="info-text">
                    Use the Tauri Controller app for multi-camera management
                </div>
            </div>

            <script>
                let ws = null;
                const wsUrl = `ws://${window.location.host}/ws`;

                // Connect to WebSocket
                function connectWebSocket() {
                    try {
                        ws = new WebSocket(wsUrl);

                        ws.onopen = () => {
                            console.log('Connected to WebSocket');
                            document.getElementById('connection-indicator').textContent = 'Connected';
                            document.getElementById('connection-indicator').className = 'connection-status connected';
                        };

                        ws.onmessage = (event) => {
                            try {
                                const telemetry = JSON.parse(event.data);
                                updateTelemetry(telemetry);
                            } catch (e) {
                                console.error('Failed to parse telemetry:', e);
                            }
                        };

                        ws.onerror = (error) => {
                            console.error('WebSocket error:', error);
                        };

                        ws.onclose = () => {
                            console.log('WebSocket closed, reconnecting...');
                            document.getElementById('connection-indicator').textContent = 'Disconnected';
                            document.getElementById('connection-indicator').className = 'connection-status disconnected';
                            setTimeout(connectWebSocket, 2000);
                        };
                    } catch (e) {
                        console.error('Failed to connect:', e);
                        setTimeout(connectWebSocket, 2000);
                    }
                }

                // Load camera status and populate form
                async function loadCameraStatus() {
                    try {
                        const status = await apiCall('/api/v1/status');
                        console.log('Camera status loaded:', status);

                        // Populate camera settings form
                        if (status.current) {
                            const current = status.current;

                            // White balance
                            document.getElementById('wb-mode').value = current.wb_mode;
                            if (current.wb_mode === 'manual') {
                                document.getElementById('wb-kelvin-row').style.display = 'block';
                                document.getElementById('wb-tint-row').style.display = 'block';
                                if (current.wb_kelvin) {
                                    document.getElementById('wb-kelvin').value = current.wb_kelvin;
                                }
                                if (current.wb_tint !== null && current.wb_tint !== undefined) {
                                    document.getElementById('wb-tint').value = current.wb_tint;
                                }
                            }

                            // ISO
                            if (current.iso !== null && current.iso !== undefined) {
                                document.getElementById('iso').value = current.iso;
                            }

                            // Zoom
                            if (current.zoom_factor) {
                                document.getElementById('zoom').value = current.zoom_factor;
                            }
                        }
                    } catch (e) {
                        console.error('Failed to load camera status:', e);
                    }
                }

                // Update telemetry display
                function updateTelemetry(telemetry) {
                    document.getElementById('fps').textContent = telemetry.fps.toFixed(1);
                    document.getElementById('bitrate').textContent = (telemetry.bitrate / 1000000).toFixed(1) + ' Mbps';
                    document.getElementById('battery').textContent = (telemetry.battery * 100).toFixed(0) + '%';
                    document.getElementById('temp').textContent = telemetry.temp_c.toFixed(1) + '°C';
                    document.getElementById('wifi').textContent = telemetry.wifi_rssi + ' dBm';

                    const stateEl = document.getElementById('ndi-state');
                    stateEl.textContent = telemetry.ndi_state.charAt(0).toUpperCase() + telemetry.ndi_state.slice(1);
                    stateEl.className = 'status-value ' + telemetry.ndi_state;
                }

                // API calls
                async function apiCall(endpoint, method = 'GET', body = null) {
                    try {
                        const options = {
                            method,
                            headers: {}
                        };
                        if (body) {
                            options.headers['Content-Type'] = 'application/json';
                            options.body = JSON.stringify(body);
                        }
                        const response = await fetch(endpoint, options);
                        if (!response.ok) {
                            const error = await response.json();
                            throw new Error(error.message || 'Request failed');
                        }
                        return await response.json();
                    } catch (e) {
                        alert('Error: ' + e.message);
                        throw e;
                    }
                }

                // Event handlers
                document.getElementById('btn-start').addEventListener('click', async () => {
                    await apiCall('/api/v1/stream/start', 'POST', {
                        resolution: '1920x1080',
                        framerate: 30,
                        bitrate: 10000000,
                        codec: 'h264'
                    });
                });

                document.getElementById('btn-stop').addEventListener('click', async () => {
                    await apiCall('/api/v1/stream/stop', 'POST');
                });

                document.getElementById('btn-keyframe').addEventListener('click', async () => {
                    await apiCall('/api/v1/encoder/force_keyframe', 'POST');
                });

                document.getElementById('btn-apply-settings').addEventListener('click', async () => {
                    const settings = {
                        wb_mode: document.getElementById('wb-mode').value,
                        iso: parseInt(document.getElementById('iso').value),
                        zoom_factor: parseFloat(document.getElementById('zoom').value)
                    };
                    if (settings.wb_mode === 'manual') {
                        settings.wb_kelvin = parseInt(document.getElementById('wb-kelvin').value);
                        settings.wb_tint = parseFloat(document.getElementById('wb-tint').value);
                    }
                    await apiCall('/api/v1/camera', 'POST', settings);
                });

                // Show/hide WB kelvin and tint inputs based on mode
                document.getElementById('wb-mode').addEventListener('change', (e) => {
                    const isManual = e.target.value === 'manual';
                    document.getElementById('wb-kelvin-row').style.display = isManual ? 'block' : 'none';
                    document.getElementById('wb-tint-row').style.display = isManual ? 'block' : 'none';
                });

                // Initialize
                loadCameraStatus();
                connectWebSocket();
            </script>
        </body>
        </html>
        """
        return HTTPResponse(status: 200, headers: ["Content-Type": "text/html"], body: html.data(using: String.Encoding.utf8) ?? Data())
    }

    // MARK: - Helpers

    private func errorJSON(code: String, message: String) -> Data {
        let error = ErrorResponse(code: code, message: message)
        return (try? JSONEncoder().encode(error)) ?? Data()
    }

    private func successJSON(message: String) -> Data {
        let response = ["success": true, "message": message] as [String : Any]
        return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
    }
}

// MARK: - HTTP Response

struct HTTPResponse {
    let status: Int
    let headers: [String: String]
    let body: Data

    init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        var allHeaders = headers
        if allHeaders["Content-Type"] == nil {
            allHeaders["Content-Type"] = "application/json"
        }
        self.headers = allHeaders
        self.body = body
    }
}

// MARK: - WebSocket Client

class WebSocketClient {
    private let channel: Channel
    private let eventLoop: EventLoop

    init(channel: Channel) {
        self.channel = channel
        self.eventLoop = channel.eventLoop
    }

    func send(text: String) {
        let buffer = channel.allocator.buffer(string: text)
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
        channel.writeAndFlush(frame, promise: nil)
    }

    func send(data: Data) {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let frame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)
        channel.writeAndFlush(frame, promise: nil)
    }

    func close() {
        _ = channel.close(mode: .all)
    }
}

// MARK: - Errors

enum NetworkError: LocalizedError {
    case serverStartFailed
    case invalidRequest

    var errorDescription: String? {
        switch self {
        case .serverStartFailed:
            return "Failed to start server"
        case .invalidRequest:
            return "Invalid request"
        }
    }
}

// MARK: - HTTP Server Handler

@preconcurrency
final class HTTPServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let server: NetworkServer
    private var requestParts: [HTTPServerRequestPart] = []
    private var headers: HTTPHeaders = HTTPHeaders()
    private var uri: String = ""
    private var method: HTTPMethod = .GET
    private var bodyBuffer: ByteBuffer?
    private var isUpgraded: Bool = false

    init(server: NetworkServer) {
        self.server = server
    }

    func markAsUpgraded() {
        isUpgraded = true
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Ignore data if we've been upgraded to WebSocket
        // Must check BEFORE unwrapping, as upgraded connections send IOData not HTTPServerRequestPart
        guard !isUpgraded else {
            context.fireChannelRead(data)
            return
        }

        let part = self.unwrapInboundIn(data)
        requestParts.append(part)

        switch part {
        case .head(let head):
            self.uri = head.uri
            self.method = head.method
            self.headers = head.headers

            // WebSocket upgrades are now handled automatically by NIOWebSocketServerUpgrader

        case .body(var buffer):
            if bodyBuffer == nil {
                bodyBuffer = buffer
            } else {
                bodyBuffer?.writeBuffer(&buffer)
            }

        case .end:
            // Process complete HTTP request
            processHTTPRequest(context: context)
            reset()
        }
    }


    private func processHTTPRequest(context: ChannelHandlerContext) {
        // Convert headers to dictionary
        var headersDict: [String: String] = [:]
        for (name, value) in headers {
            headersDict[name] = value
        }

        // Convert body buffer to Data
        let bodyData = bodyBuffer.flatMap { buffer in
            Data(buffer.readableBytesView)
        }

        // Capture values before they get reset (reset() is called after this method returns)
        let path = uri.components(separatedBy: "?").first ?? uri
        let methodString = method.rawValue  // Capture method string NOW before reset()

        // Handle request asynchronously
        Task {
            let response = await server.handleHTTPRequest(
                path: path,
                method: methodString,  // Use captured value
                headers: headersDict,
                body: bodyData
            )
            // Send response on the channel's event loop
            context.eventLoop.execute {
                self.sendHTTPResponse(context: context, response: response)
            }
        }
    }

    private func sendHTTPResponse(context: ChannelHandlerContext, response: HTTPResponse) {
        // Create response head
        var headers = HTTPHeaders()
        for (key, value) in response.headers {
            headers.add(name: key, value: value)
        }
        headers.add(name: "Content-Length", value: String(response.body.count))

        let responseHead = HTTPResponseHead(
            version: .http1_1,
            status: HTTPResponseStatus(statusCode: response.status),
            headers: headers
        )

        context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)

        // Write body if present
        if !response.body.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: response.body.count)
            buffer.writeBytes(response.body)
            context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }

        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func reset() {
        requestParts.removeAll()
        headers = HTTPHeaders()
        uri = ""
        method = .GET
        bodyBuffer = nil
    }


    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("❌ HTTP handler error: \(error)")
        context.close(promise: nil)
    }
}

// MARK: - WebSocket Server Handler

@preconcurrency
final class WebSocketServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let server: NetworkServer
    private var wsClient: WebSocketClient?

    init(server: NetworkServer) {
        self.server = server
    }

    func handlerAdded(context: ChannelHandlerContext) {
        wsClient = WebSocketClient(channel: context.channel)
        if let client = wsClient {
            server.addWebSocketClient(client)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        if let client = wsClient {
            server.removeWebSocketClient(client)
        }
        wsClient = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)

        switch frame.opcode {
        case .text:
            var data = frame.unmaskedData
            if let text = data.readString(length: data.readableBytes) {
                handleWebSocketMessage(text: text)
            }

        case .binary:
            var data = frame.unmaskedData
            if let bytes = data.readBytes(length: data.readableBytes) {
                handleWebSocketMessage(data: Data(bytes))
            }

        case .connectionClose:
            context.close(promise: nil)

        case .ping:
            let pongFrame = WebSocketFrame(fin: true, opcode: .pong, data: frame.data)
            context.writeAndFlush(self.wrapOutboundOut(pongFrame), promise: nil)

        case .pong:
            // Ignore pong frames
            break

        default:
            break
        }
    }

    private func handleWebSocketMessage(text: String) {
        // Decode WebSocket command
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(WebSocketCommandMessage.self, from: data) else {
            print("⚠️ Invalid WebSocket message")
            return
        }

        // Handle camera control commands
        if message.op == "set", let cameraSettings = message.camera {
            Task {
                // Forward to request handler
                // Note: This would require async support in the handler
                print("📥 WS camera command: \(cameraSettings)")
            }
        }
    }

    private func handleWebSocketMessage(data: Data) {
        print("📥 WS binary data received: \(data.count) bytes")
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("❌ WebSocket handler error: \(error)")
        context.close(promise: nil)
    }
}
