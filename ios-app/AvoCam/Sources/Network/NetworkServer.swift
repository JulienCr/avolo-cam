//
//  NetworkServer.swift
//  AvoCam
//
//  HTTP REST + WebSocket server using SwiftNIO
//
//  ⚠️ TODO: Implement full SwiftNIO server
//  This is a simplified stub showing the required structure
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
    func handleGetStatus() -> StatusResponse
    func handleGetCapabilities() -> [Capability]
}

// MARK: - Network Server

class NetworkServer {
    // MARK: - Properties

    private let port: Int
    private let bearerToken: String
    private weak var requestHandler: NetworkRequestHandler?

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
    }

    // MARK: - Server Control

    func start() throws {
        print("🌐 Starting HTTP/WebSocket server on port \(port)")

        // TODO: Implement full SwiftNIO server
        // This is a stub - full implementation needed
        /*
        group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        guard let group = group else {
            throw NetworkError.serverStartFailed
        }

        bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPHandler(server: self))
                }
            }

        guard let bootstrap = bootstrap else {
            throw NetworkError.serverStartFailed
        }

        channel = try bootstrap.bind(host: "0.0.0.0", port: port).wait()
        */

        print("✅ Server started (stub - SwiftNIO implementation needed)")
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

    func broadcastTelemetry(_ telemetry: Telemetry) {
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
            ndiState: .idle, // TODO: Get from actual state
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
        // Authenticate
        guard let authHeader = headers["Authorization"],
              authHeader == "Bearer \(bearerToken)" else {
            return HTTPResponse(
                status: 401,
                body: errorJSON(code: "UNAUTHORIZED", message: "Invalid or missing bearer token")
            )
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
            return handleGetStatus()

        case ("GET", "/api/v1/capabilities"):
            return handleGetCapabilities()

        case ("POST", "/api/v1/stream/start"):
            return await handleStreamStart(body: body)

        case ("POST", "/api/v1/stream/stop"):
            return await handleStreamStop()

        case ("POST", "/api/v1/camera"):
            return await handleCameraSettings(body: body)

        case ("POST", "/api/v1/encoder/force_keyframe"):
            return handleForceKeyframe()

        case ("GET", "/api/v1/logs.zip"):
            return handleLogsDownload()

        case ("GET", "/"):
            return handleWebUI()

        default:
            return HTTPResponse(
                status: 404,
                body: errorJSON(code: "NOT_FOUND", message: "Endpoint not found")
            )
        }
    }

    // MARK: - Endpoint Handlers

    private func handleGetStatus() -> HTTPResponse {
        guard let handler = requestHandler else {
            return HTTPResponse(status: 500, body: errorJSON(code: "INTERNAL_ERROR", message: "No request handler"))
        }

        let status = handler.handleGetStatus()
        guard let jsonData = try? JSONEncoder().encode(status) else {
            return HTTPResponse(status: 500, body: errorJSON(code: "ENCODING_ERROR", message: "Failed to encode status"))
        }

        return HTTPResponse(status: 200, body: jsonData)
    }

    private func handleGetCapabilities() -> HTTPResponse {
        guard let handler = requestHandler else {
            return HTTPResponse(status: 500, body: errorJSON(code: "INTERNAL_ERROR", message: "No request handler"))
        }

        let capabilities = handler.handleGetCapabilities()
        guard let jsonData = try? JSONEncoder().encode(capabilities) else {
            return HTTPResponse(status: 500, body: errorJSON(code: "ENCODING_ERROR", message: "Failed to encode capabilities"))
        }

        return HTTPResponse(status: 200, body: jsonData)
    }

    private func handleStreamStart(body: Data?) async -> HTTPResponse {
        guard let body = body,
              let request = try? JSONDecoder().decode(StreamStartRequest.self, from: body) else {
            return HTTPResponse(status: 400, body: errorJSON(code: "INVALID_REQUEST", message: "Invalid stream start request"))
        }

        guard let handler = requestHandler else {
            return HTTPResponse(status: 500, body: errorJSON(code: "INTERNAL_ERROR", message: "No request handler"))
        }

        do {
            try await handler.handleStreamStart(request)
            return HTTPResponse(status: 200, body: successJSON(message: "Stream started"))
        } catch {
            return HTTPResponse(status: 500, body: errorJSON(code: "STREAM_START_FAILED", message: error.localizedDescription))
        }
    }

    private func handleStreamStop() async -> HTTPResponse {
        guard let handler = requestHandler else {
            return HTTPResponse(status: 500, body: errorJSON(code: "INTERNAL_ERROR", message: "No request handler"))
        }

        do {
            try await handler.handleStreamStop()
            return HTTPResponse(status: 200, body: successJSON(message: "Stream stopped"))
        } catch {
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

    private func handleForceKeyframe() -> HTTPResponse {
        guard let handler = requestHandler else {
            return HTTPResponse(status: 500, body: errorJSON(code: "INTERNAL_ERROR", message: "No request handler"))
        }

        handler.handleForceKeyframe()
        return HTTPResponse(status: 200, body: successJSON(message: "Keyframe forced"))
    }

    private func handleLogsDownload() -> HTTPResponse {
        // TODO: Implement rotating logs and zip creation
        return HTTPResponse(status: 501, body: errorJSON(code: "NOT_IMPLEMENTED", message: "Logs download not yet implemented"))
    }

    private func handleWebUI() -> HTTPResponse {
        // TODO: Serve embedded HTML web UI
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>AvoCam</title>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
        </head>
        <body>
            <h1>AvoCam Web UI</h1>
            <p>TODO: Implement web UI</p>
        </body>
        </html>
        """
        return HTTPResponse(status: 200, headers: ["Content-Type": "text/html"], body: html.data(using: .utf8) ?? Data())
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
    // TODO: Implement with SwiftNIO WebSocket channel

    func send(text: String) {
        // TODO: Send text frame via WebSocket
        // print("📤 WS send: \(text)")
    }

    func close() {
        // TODO: Close WebSocket connection
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

// MARK: - Implementation Notes

/*
 SwiftNIO Server Implementation TODO:

 1. HTTP Server Pipeline:
    - HTTPServerRequestDecoder
    - HTTPServerResponseEncoder
    - HTTPRequestHandler (custom handler)

 2. WebSocket Upgrade:
    - Detect "Upgrade: websocket" header
    - Perform WebSocket handshake
    - Replace HTTP pipeline with WebSocket pipeline
    - Add WebSocketHandler

 3. Request Routing:
    - Parse URI and method
    - Match against API endpoints
    - Call appropriate handler methods
    - Return HTTPResponse with proper status codes

 4. Authentication:
    - Check Authorization header
    - Validate Bearer token
    - Return 401 if invalid

 5. Rate Limiting:
    - Track last update time per client IP
    - Enforce 50-100ms debounce for camera settings
    - Return 429 if rate exceeded

 6. WebSocket Telemetry:
    - Maintain list of connected WS clients
    - Broadcast telemetry every 1 second
    - Handle client disconnect gracefully

 7. Error Handling:
    - Catch all errors and return proper HTTP status
    - Use uniform error format: {code, message}
    - Log errors for debugging

 Reference:
 https://github.com/apple/swift-nio-examples
 https://github.com/vapor/vapor (for inspiration)
 */
