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
import os

// MARK: - Request Handler Protocol

protocol NetworkRequestHandler: AnyObject {
    func handleStreamStart(_ request: StreamStartRequest) async throws
    func handleStreamStop() async throws
    func handleCameraSettings(_ settings: CameraSettingsRequest) async throws
    func handleGetStatus() async -> StatusResponse
    func handleGetCapabilities() async -> [Capability]
    func handleGetVideoSettings() async -> VideoSettingsResponse
    func handleUpdateVideoSettings(_ request: VideoSettingsUpdateRequest) async throws
    func handleScreenBrightness(_ request: ScreenBrightnessRequest)
    func handleMeasureWhiteBalance() async throws -> WhiteBalanceMeasureResponse
    func handleUpdateAlias(_ request: AliasUpdateRequest) async throws -> AliasUpdateResponse
    func handleGetTorchLevel() async -> TorchLevelResponse
    func handleUpdateTorchLevel(_ request: TorchLevelUpdateRequest) async throws -> TorchLevelResponse
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

    // WebSocket clients (thread-safe access via lock)
    private let wsClients = OSAllocatedUnfairLock(uncheckedState: [WebSocketClient]())

    // HTTP Router
    private var router: HTTPRouter!
    private var authMiddleware: AuthMiddleware!

    /// Callback for tally updates from OBS (program, preview)
    var onTallyUpdate: ((Bool, Bool) async -> Void)?

    // MARK: - Initialization

    init(port: Int, bearerToken: String, requestHandler: NetworkRequestHandler?) {
        self.port = port
        self.bearerToken = bearerToken
        self.requestHandler = requestHandler
        self.isAuthenticationEnabled = false
    }

    func setAuthenticationEnabled(_ enabled: Bool) {
        self.isAuthenticationEnabled = enabled
        authMiddleware?.setEnabled(enabled)
    }

    // MARK: - Server Control

    func start() throws {
        Log.network.info("Starting HTTP/WebSocket server on port \(port)")

        // Initialize router with middleware and routes
        setupRouter()

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
                    shouldUpgrade: { [weak self] (channel: Channel, head: HTTPRequestHead) in
                        // Check for WebSocket upgrade request
                        guard head.uri == "/ws",
                              head.headers["upgrade"].first?.lowercased() == "websocket" else {
                            return channel.eventLoop.makeSucceededFuture(nil)
                        }

                        // If server was deallocated, reject the upgrade
                        guard let self = self else {
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
                    upgradePipelineHandler: { [weak self] (channel: Channel, _: HTTPRequestHead) in
                        // Add WebSocket handler to the pipeline
                        // NIO automatically removes HTTP decoder/encoder before calling this
                        guard let self = self else {
                            return channel.eventLoop.makeFailedFuture(NetworkError.serverStartFailed)
                        }
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
                ).flatMap { [weak self] in
                    guard let self = self else {
                        return channel.eventLoop.makeFailedFuture(NetworkError.serverStartFailed)
                    }
                    return channel.pipeline.addHandler(HTTPServerHandler(server: self), name: "HTTPHandler")
                }
            }

        guard let bootstrap = bootstrap else {
            throw NetworkError.serverStartFailed
        }

        channel = try bootstrap.bind(host: "0.0.0.0", port: port).wait()

        Log.network.info("Server started on port \(port)")
    }

    func stop() {
        // Close all WebSocket connections
        wsClients.withLock { clients in
            for client in clients {
                client.close()
            }
            clients.removeAll()
        }

        // Shutdown server
        try? channel?.close().wait()
        try? group?.syncShutdownGracefully()

        channel = nil
        bootstrap = nil
        group = nil

        Log.network.info("Server stopped")
    }

    // MARK: - WebSocket Management

    func addWebSocketClient(_ client: WebSocketClient) {
        let count = wsClients.withLock { clients -> Int in
            clients.append(client)
            return clients.count
        }

        Log.network.info("WebSocket client connected (total: \(count))")
    }

    func removeWebSocketClient(_ client: WebSocketClient) {
        let count = wsClients.withLock { clients -> Int in
            clients.removeAll { $0 === client }
            return clients.count
        }

        Log.network.info("WebSocket client disconnected (total: \(count))")
    }

    func broadcastTelemetry(_ telemetry: Telemetry, ndiState: NDIState, flashUdpPort: Int? = nil) {
        let clients = wsClients.withLock { Array($0) }

        // Encode telemetry to JSON
        let message = WebSocketTelemetryMessage(
            fps: telemetry.fps,
            bitrate: telemetry.bitrate,
            queueMs: telemetry.queueMs ?? 0,
            battery: telemetry.battery,
            tempC: telemetry.tempC,
            wifiRssi: telemetry.wifiRssi,
            cpuUsage: telemetry.cpuUsage,
            ndiState: ndiState,
            droppedFrames: telemetry.droppedFrames ?? 0,
            chargingState: telemetry.chargingState ?? .unplugged,
            flashUdpPort: flashUdpPort
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

    /// Broadcast frame timing info to subscribed WebSocket clients only (for Flash mode latency correlation)
    /// - Parameter frameInfo: Frame timing and RTP timestamp information
    func broadcastFrameInfo(_ frameInfo: WebSocketFrameInfo) {
        let clients = wsClients.withLock { $0.filter { $0.subscribedToFrameInfo } }
        guard !clients.isEmpty else { return }

        guard let jsonData = try? JSONEncoder().encode(frameInfo),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        for client in clients {
            client.send(text: jsonString)
        }
    }

    // MARK: - Tally Handling

    /// Handle tally update from OBS via WebSocket
    func handleTallyUpdate(program: Bool, preview: Bool) async {
        await onTallyUpdate?(program, preview)
    }

    // MARK: - Router Setup

    private func setupRouter() {
        router = HTTPRouter()

        // Add middleware in order
        router.use(CORSMiddleware())

        authMiddleware = AuthMiddleware(bearerToken: bearerToken, isEnabled: isAuthenticationEnabled)
        router.use(authMiddleware)

        router.use(RateLimitMiddleware())

        // Register routes temporarily (until Phase 5 DI integration)
        registerRoutes()
    }

    private func registerRoutes() {
        // Status endpoints
        router.get("/api/v1/status") { [weak self] _, _, _, _ in
            await self?.handleGetStatus() ?? HTTPResponse.internalError()
        }

        router.get("/api/v1/capabilities") { [weak self] _, _, _, _ in
            await self?.handleGetCapabilities() ?? HTTPResponse.internalError()
        }

        // Video settings endpoints
        router.get("/api/v1/video/settings") { [weak self] _, _, _, _ in
            await self?.handleGetVideoSettings() ?? HTTPResponse.internalError()
        }

        router.put("/api/v1/video/settings") { [weak self] _, _, _, body in
            await self?.handlePutVideoSettings(body: body) ?? HTTPResponse.internalError()
        }

        // Stream control endpoints
        router.post("/api/v1/stream/start") { [weak self] _, _, _, body in
            await self?.handleStreamStart(body: body) ?? HTTPResponse.internalError()
        }

        router.post("/api/v1/stream/stop") { [weak self] _, _, _, _ in
            await self?.handleStreamStop() ?? HTTPResponse.internalError()
        }

        // Camera control endpoints
        router.post("/api/v1/camera") { [weak self] _, _, _, body in
            await self?.handleCameraSettings(body: body) ?? HTTPResponse.internalError()
        }

        router.post("/api/v1/screen/brightness") { [weak self] _, _, _, body in
            self?.handleScreenBrightness(body: body) ?? HTTPResponse.internalError()
        }

        router.post("/api/v1/camera/wb/measure") { [weak self] _, _, _, _ in
            await self?.handleMeasureWhiteBalance() ?? HTTPResponse.internalError()
        }

        // Settings endpoints
        router.put("/api/v1/settings/alias") { [weak self] _, _, _, body in
            await self?.handleUpdateAlias(body: body) ?? HTTPResponse.internalError()
        }

        // Torch endpoints
        router.get("/api/v1/torch/level") { [weak self] _, _, _, _ in
            await self?.handleGetTorchLevel() ?? HTTPResponse.internalError()
        }

        router.put("/api/v1/torch/level") { [weak self] _, _, _, body in
            await self?.handlePutTorchLevel(body: body) ?? HTTPResponse.internalError()
        }

        // Diagnostics endpoints
        router.get("/api/v1/logs.zip") { [weak self] _, _, _, _ in
            self?.handleLogsDownload() ?? HTTPResponse.internalError()
        }

        // Web UI
        router.get("/") { _, _, _, _ in
            HTTPResponse.html(WebUI.getHTML())
        }
    }

    // MARK: - Request Handling

    func handleHTTPRequest(path: String, method: String, headers: [String: String], body: Data?) async -> HTTPResponse {
        return await router.route(path: path, method: method, headers: headers, body: body)
    }

    // MARK: - Temporary Endpoint Handlers
    // TODO: These will be removed in Phase 5 when DI is complete and controllers are used directly

    private func handleGetStatus() async -> HTTPResponse {
        guard let handler = requestHandler else {
            return HTTPResponse.internalError(code: "INTERNAL_ERROR", message: "No request handler")
        }

        let status = await handler.handleGetStatus()
        return HTTPResponse.json(status)
    }

    private func handleGetCapabilities() async -> HTTPResponse {
        guard let handler = requestHandler else {
            return HTTPResponse.internalError(code: "INTERNAL_ERROR", message: "No request handler")
        }

        let capabilities = await handler.handleGetCapabilities()
        return HTTPResponse.json(capabilities)
    }

    private func handleStreamStart(body: Data?) async -> HTTPResponse {
        guard let body = body,
              let request = try? JSONDecoder().decode(StreamStartRequest.self, from: body) else {
            Log.network.warning("Invalid stream start request body")
            return HTTPResponse.badRequest(code: "INVALID_REQUEST", message: "Invalid stream start request")
        }

        guard let handler = requestHandler else {
            Log.network.warning("No request handler available")
            return HTTPResponse.internalError(code: "INTERNAL_ERROR", message: "No request handler")
        }

        do {
            try await handler.handleStreamStart(request)
            Log.network.info("Stream started: \(request.resolution)@\(request.framerate)fps")
            return HTTPResponse.success(message: "Stream started")
        } catch {
            Log.network.error("Stream start failed: \(error.localizedDescription)")
            return HTTPResponse.internalError(code: "STREAM_START_FAILED", message: error.localizedDescription)
        }
    }

    private func handleStreamStop() async -> HTTPResponse {
        guard let handler = requestHandler else {
            Log.network.warning("No request handler available")
            return HTTPResponse.internalError(code: "INTERNAL_ERROR", message: "No request handler")
        }

        do {
            try await handler.handleStreamStop()
            Log.network.info("Stream stopped")
            return HTTPResponse.success(message: "Stream stopped")
        } catch {
            Log.network.error("Stream stop failed: \(error.localizedDescription)")
            return HTTPResponse.internalError(code: "STREAM_STOP_FAILED", message: error.localizedDescription)
        }
    }

    private func handleCameraSettings(body: Data?) async -> HTTPResponse {
        guard let body = body,
              let settings = try? JSONDecoder().decode(CameraSettingsRequest.self, from: body) else {
            return HTTPResponse.badRequest(code: "INVALID_REQUEST", message: "Invalid camera settings request")
        }

        guard let handler = requestHandler else {
            return HTTPResponse.internalError(code: "INTERNAL_ERROR", message: "No request handler")
        }

        do {
            try await handler.handleCameraSettings(settings)
            return HTTPResponse.success(message: "Camera settings updated")
        } catch {
            return HTTPResponse.internalError(code: "CAMERA_UPDATE_FAILED", message: error.localizedDescription)
        }
    }

    private func handleScreenBrightness(body: Data?) -> HTTPResponse {
        guard let body = body,
              let request = try? JSONDecoder().decode(ScreenBrightnessRequest.self, from: body) else {
            return HTTPResponse.badRequest(code: "INVALID_REQUEST", message: "Invalid screen brightness request")
        }

        guard let handler = requestHandler else {
            return HTTPResponse.internalError(code: "INTERNAL_ERROR", message: "No request handler")
        }

        handler.handleScreenBrightness(request)
        return HTTPResponse.success(message: "Screen brightness updated")
    }

    private func handleGetVideoSettings() async -> HTTPResponse {
        guard let handler = requestHandler else {
            return HTTPResponse.internalError(code: "INTERNAL_ERROR", message: "No request handler")
        }

        let settings = await handler.handleGetVideoSettings()
        return HTTPResponse.json(settings)
    }

    private func handlePutVideoSettings(body: Data?) async -> HTTPResponse {
        guard let body = body,
              let request = try? JSONDecoder().decode(VideoSettingsUpdateRequest.self, from: body) else {
            return HTTPResponse.badRequest(code: "INVALID_REQUEST", message: "Invalid video settings request")
        }

        guard let handler = requestHandler else {
            return HTTPResponse.internalError(code: "INTERNAL_ERROR", message: "No request handler")
        }

        do {
            try await handler.handleUpdateVideoSettings(request)
            return HTTPResponse.success(message: "Video settings updated")
        } catch {
            return HTTPResponse.internalError(code: "VIDEO_SETTINGS_UPDATE_FAILED", message: error.localizedDescription)
        }
    }

    private func handleMeasureWhiteBalance() async -> HTTPResponse {
        guard let handler = requestHandler else {
            Log.network.warning("No request handler available")
            return HTTPResponse.internalError(code: "INTERNAL_ERROR", message: "No request handler")
        }

        do {
            let result = try await handler.handleMeasureWhiteBalance()
            Log.network.info("White balance measured: SceneCCT_K = \(result.sceneCCT_K)K (physical), tint = \(String(format: "%.1f", result.tint))")
            return HTTPResponse.json(result)
        } catch {
            Log.network.error("White balance measure failed: \(error.localizedDescription)")
            return HTTPResponse.internalError(code: "MEASURE_FAILED", message: error.localizedDescription)
        }
    }

    private func handleUpdateAlias(body: Data?) async -> HTTPResponse {
        guard let body = body,
              let request = try? JSONDecoder().decode(AliasUpdateRequest.self, from: body) else {
            return HTTPResponse.badRequest(code: "INVALID_REQUEST", message: "Invalid alias update request")
        }

        // Validate alias (no empty strings, reasonable length)
        let trimmedAlias = request.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAlias.isEmpty, trimmedAlias.count <= 64 else {
            return HTTPResponse.badRequest(code: "INVALID_ALIAS", message: "Alias must be 1-64 characters")
        }

        guard let handler = requestHandler else {
            return HTTPResponse.internalError(code: "INTERNAL_ERROR", message: "No request handler")
        }

        do {
            let result = try await handler.handleUpdateAlias(request)
            Log.network.info("Alias updated to: \(result.alias)")
            return HTTPResponse.json(result)
        } catch {
            Log.network.error("Alias update failed: \(error.localizedDescription)")
            return HTTPResponse.internalError(code: "ALIAS_UPDATE_FAILED", message: error.localizedDescription)
        }
    }

    private func handleGetTorchLevel() async -> HTTPResponse {
        guard let handler = requestHandler else {
            return HTTPResponse.internalError(code: "INTERNAL_ERROR", message: "No request handler")
        }

        let response = await handler.handleGetTorchLevel()
        return HTTPResponse.json(response)
    }

    private func handlePutTorchLevel(body: Data?) async -> HTTPResponse {
        guard let body = body,
              let request = try? JSONDecoder().decode(TorchLevelUpdateRequest.self, from: body) else {
            return HTTPResponse.badRequest(code: "INVALID_REQUEST", message: "Invalid torch level request")
        }

        guard let handler = requestHandler else {
            return HTTPResponse.internalError(code: "INTERNAL_ERROR", message: "No request handler")
        }

        do {
            let response = try await handler.handleUpdateTorchLevel(request)
            Log.network.info("Torch level updated to: \(response.currentLevel)")
            return HTTPResponse.json(response)
        } catch {
            Log.network.error("Torch level update failed: \(error.localizedDescription)")
            return HTTPResponse.internalError(code: "TORCH_UPDATE_FAILED", message: error.localizedDescription)
        }
    }

    private func handleLogsDownload() -> HTTPResponse {
        // TODO: Implement rotating logs and zip creation
        return HTTPResponse.error(status: 501, code: "NOT_IMPLEMENTED", message: "Logs download not yet implemented")
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

        // Add CORS headers if not already present
        if allHeaders["Access-Control-Allow-Origin"] == nil {
            allHeaders["Access-Control-Allow-Origin"] = "*"
        }

        // Add Content-Type if not already present
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
    var subscribedToFrameInfo: Bool = false

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

    private weak var server: NetworkServer?
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
        guard let server = server else { return }

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
        Task { [weak server] in
            guard let server = server else { return }
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
        Log.network.error("HTTP handler error: \(error)")
        context.close(promise: nil)
    }
}

// MARK: - WebSocket Server Handler

@preconcurrency
final class WebSocketServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private weak var server: NetworkServer?
    private var wsClient: WebSocketClient?

    init(server: NetworkServer) {
        self.server = server
    }

    func handlerAdded(context: ChannelHandlerContext) {
        wsClient = WebSocketClient(channel: context.channel)
        if let client = wsClient {
            server?.addWebSocketClient(client)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        if let client = wsClient {
            server?.removeWebSocketClient(client)
        }
        wsClient = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)

        switch frame.opcode {
        case .text:
            var data = frame.unmaskedData
            if let text = data.readString(length: data.readableBytes) {
                handleWebSocketMessage(text: text, client: wsClient)
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

    private func handleWebSocketMessage(text: String, client: WebSocketClient?) {
        guard let data = text.data(using: .utf8) else {
            Log.network.warning("Invalid WebSocket message encoding")
            return
        }

        // Try to decode as a generic message to get the "op" field
        struct OpMessage: Codable { let op: String }
        guard let opMsg = try? JSONDecoder().decode(OpMessage.self, from: data) else {
            Log.network.warning("Invalid WebSocket message: missing 'op' field")
            return
        }

        switch opMsg.op {
        case "tally":
            // Handle tally update from OBS
            if let tallyMsg = try? JSONDecoder().decode(WebSocketTallyMessage.self, from: data) {
                Task { [weak server] in
                    await server?.handleTallyUpdate(program: tallyMsg.program, preview: tallyMsg.preview)
                }
            }

        case "set":
            // Handle camera control commands
            if let message = try? JSONDecoder().decode(WebSocketCommandMessage.self, from: data),
               let cameraSettings = message.camera {
                Task {
                    // Forward to request handler
                    // Note: This would require async support in the handler
                    Log.network.debug("WS camera command: \(cameraSettings)")
                }
            }

        case "subscribe":
            // Handle channel subscription (e.g., OBS subscribing to frame_info)
            struct SubscribeMessage: Codable { let op: String; let channels: [String] }
            if let subMsg = try? JSONDecoder().decode(SubscribeMessage.self, from: data) {
                if subMsg.channels.contains("frame_info") {
                    client?.subscribedToFrameInfo = true
                    Log.network.debug("WS client subscribed to frame_info")
                }
            }

        default:
            Log.network.warning("Unknown WebSocket op: \(opMsg.op)")
        }
    }

    private func handleWebSocketMessage(data: Data) {
        Log.network.debug("WS binary data received: \(data.count) bytes")
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Log.network.error("WebSocket handler error: \(error)")
        context.close(promise: nil)
    }
}
