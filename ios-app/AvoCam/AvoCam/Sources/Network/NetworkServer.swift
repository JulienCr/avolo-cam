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

// MARK: - Network Server

nonisolated class NetworkServer {
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
        print("Starting HTTP/WebSocket server on port \(port)")

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
                    shouldUpgrade: { (channel: Channel, head: HTTPRequestHead) in
                        guard head.uri == "/ws",
                              head.headers["upgrade"].first?.lowercased() == "websocket" else {
                            return channel.eventLoop.makeSucceededFuture(nil)
                        }

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
                        let wsHandler = WebSocketServerHandler(server: self)
                        return channel.pipeline.addHandler(wsHandler).flatMap {
                            channel.pipeline.context(name: "HTTPHandler").flatMap { context in
                                if let httpHandler = context.handler as? HTTPServerHandler {
                                    httpHandler.markAsUpgraded()
                                }
                                return channel.eventLoop.makeSucceededFuture(())
                            }.recover { _ in }
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

        print("Server started on port \(port)")
    }

    func stop() {
        wsClients.withLock { clients in
            for client in clients {
                client.close()
            }
            clients.removeAll()
        }

        try? channel?.close().wait()
        try? group?.syncShutdownGracefully()

        channel = nil
        bootstrap = nil
        group = nil

        print("Server stopped")
    }

    // MARK: - WebSocket Management

    func addWebSocketClient(_ client: WebSocketClient) {
        let count = wsClients.withLock { clients -> Int in
            clients.append(client)
            return clients.count
        }
        print("WebSocket client connected (total: \(count))")
    }

    func removeWebSocketClient(_ client: WebSocketClient) {
        let count = wsClients.withLock { clients -> Int in
            clients.removeAll { $0 === client }
            return clients.count
        }
        print("WebSocket client disconnected (total: \(count))")
    }

    func broadcastTelemetry(_ telemetry: Telemetry, ndiState: NDIState, flashUdpPort: Int? = nil) {
        let clients = wsClients.withLock { Array($0) }

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

        for client in clients {
            client.send(text: jsonString)
        }
    }

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

    func handleTallyUpdate(program: Bool, preview: Bool) async {
        print("Tally update: program=\(program), preview=\(preview)")
        await onTallyUpdate?(program, preview)
    }

    // MARK: - Router Setup

    private func setupRouter() {
        router = HTTPRouter()

        router.use(CORSMiddleware())

        authMiddleware = AuthMiddleware(bearerToken: bearerToken, isEnabled: isAuthenticationEnabled)
        router.use(authMiddleware)

        router.use(RateLimitMiddleware())

        registerRoutes()
    }

    private func registerRoutes() {
        router.get("/api/v1/status") { [weak self] _, _, _, _ in
            await self?.handleGetStatus() ?? .internalError()
        }

        router.get("/api/v1/capabilities") { [weak self] _, _, _, _ in
            await self?.handleGetCapabilities() ?? .internalError()
        }

        router.get("/api/v1/video/settings") { [weak self] _, _, _, _ in
            await self?.handleGetVideoSettings() ?? .internalError()
        }

        router.put("/api/v1/video/settings") { [weak self] _, _, _, body in
            await self?.handlePutVideoSettings(body: body) ?? .internalError()
        }

        router.post("/api/v1/stream/start") { [weak self] _, _, _, body in
            await self?.handleStreamStart(body: body) ?? .internalError()
        }

        router.post("/api/v1/stream/stop") { [weak self] _, _, _, _ in
            await self?.handleStreamStop() ?? .internalError()
        }

        router.post("/api/v1/camera") { [weak self] _, _, _, body in
            await self?.handleCameraSettings(body: body) ?? .internalError()
        }

        router.post("/api/v1/screen/brightness") { [weak self] _, _, _, body in
            self?.handleScreenBrightness(body: body) ?? .internalError()
        }

        router.post("/api/v1/camera/wb/measure") { [weak self] _, _, _, _ in
            await self?.handleMeasureWhiteBalance() ?? .internalError()
        }

        router.put("/api/v1/settings/alias") { [weak self] _, _, _, body in
            await self?.handleUpdateAlias(body: body) ?? .internalError()
        }

        router.get("/api/v1/torch/level") { [weak self] _, _, _, _ in
            await self?.handleGetTorchLevel() ?? .internalError()
        }

        router.put("/api/v1/torch/level") { [weak self] _, _, _, body in
            await self?.handlePutTorchLevel(body: body) ?? .internalError()
        }

        router.get("/api/v1/logs.zip") { [weak self] _, _, _, _ in
            self?.handleLogsDownload() ?? .internalError()
        }

        router.get("/") { _, _, _, _ in
            .html(WebUI.getHTML())
        }
    }

    // MARK: - Request Handling

    func handleHTTPRequest(path: String, method: String, headers: [String: String], body: Data?) async -> HTTPResponse {
        print("HTTP \(method) \(path)")
        return await router.route(path: path, method: method, headers: headers, body: body)
    }

    // MARK: - Endpoint Handlers

    private func handleGetStatus() async -> HTTPResponse {
        guard let handler = requestHandler else {
            return .internalError(message: "No request handler")
        }
        let status = await handler.handleGetStatus()
        return .json(status)
    }

    private func handleGetCapabilities() async -> HTTPResponse {
        guard let handler = requestHandler else {
            return .internalError(message: "No request handler")
        }
        let capabilities = await handler.handleGetCapabilities()
        return .json(capabilities)
    }

    private func handleStreamStart(body: Data?) async -> HTTPResponse {
        guard let body = body else {
            return .badRequest(code: "INVALID_REQUEST", message: "Missing request body")
        }

        let request: StreamStartRequest
        do {
            request = try JSONDecoder().decode(StreamStartRequest.self, from: body)
        } catch {
            return .badRequest(code: "INVALID_JSON", message: "Invalid stream start request: \(error.localizedDescription)")
        }

        guard let handler = requestHandler else {
            return .internalError(message: "No request handler")
        }

        do {
            try await handler.handleStreamStart(request)
            print("Stream started: \(request.resolution)@\(request.framerate)fps")
            return .success(message: "Stream started")
        } catch {
            print("Stream start failed: \(error.localizedDescription)")
            return .error(status: 500, code: "STREAM_START_FAILED", message: error.localizedDescription)
        }
    }

    private func handleStreamStop() async -> HTTPResponse {
        guard let handler = requestHandler else {
            return .internalError(message: "No request handler")
        }

        do {
            try await handler.handleStreamStop()
            print("Stream stopped")
            return .success(message: "Stream stopped")
        } catch {
            print("Stream stop failed: \(error.localizedDescription)")
            return .error(status: 500, code: "STREAM_STOP_FAILED", message: error.localizedDescription)
        }
    }

    private func handleCameraSettings(body: Data?) async -> HTTPResponse {
        guard let body = body else {
            return .badRequest(code: "INVALID_REQUEST", message: "Missing request body")
        }

        let settings: CameraSettingsRequest
        do {
            settings = try JSONDecoder().decode(CameraSettingsRequest.self, from: body)
        } catch {
            return .badRequest(code: "INVALID_JSON", message: "Invalid camera settings request: \(error.localizedDescription)")
        }

        guard let handler = requestHandler else {
            return .internalError(message: "No request handler")
        }

        do {
            try await handler.handleCameraSettings(settings)
            return .success(message: "Camera settings updated")
        } catch {
            return .error(status: 500, code: "CAMERA_UPDATE_FAILED", message: error.localizedDescription)
        }
    }

    private func handleScreenBrightness(body: Data?) -> HTTPResponse {
        guard let body = body else {
            return .badRequest(code: "INVALID_REQUEST", message: "Missing request body")
        }

        let request: ScreenBrightnessRequest
        do {
            request = try JSONDecoder().decode(ScreenBrightnessRequest.self, from: body)
        } catch {
            return .badRequest(code: "INVALID_JSON", message: "Invalid screen brightness request: \(error.localizedDescription)")
        }

        guard let handler = requestHandler else {
            return .internalError(message: "No request handler")
        }

        handler.handleScreenBrightness(request)
        return .success(message: "Screen brightness updated")
    }

    private func handleGetVideoSettings() async -> HTTPResponse {
        guard let handler = requestHandler else {
            return .internalError(message: "No request handler")
        }
        let settings = await handler.handleGetVideoSettings()
        return .json(settings)
    }

    private func handlePutVideoSettings(body: Data?) async -> HTTPResponse {
        guard let body = body else {
            return .badRequest(code: "INVALID_REQUEST", message: "Missing request body")
        }

        let request: VideoSettingsUpdateRequest
        do {
            request = try JSONDecoder().decode(VideoSettingsUpdateRequest.self, from: body)
        } catch {
            return .badRequest(code: "INVALID_JSON", message: "Invalid video settings request: \(error.localizedDescription)")
        }

        guard let handler = requestHandler else {
            return .internalError(message: "No request handler")
        }

        do {
            try await handler.handleUpdateVideoSettings(request)
            return .success(message: "Video settings updated")
        } catch {
            return .error(status: 500, code: "VIDEO_SETTINGS_UPDATE_FAILED", message: error.localizedDescription)
        }
    }

    private func handleMeasureWhiteBalance() async -> HTTPResponse {
        guard let handler = requestHandler else {
            return .internalError(message: "No request handler")
        }

        do {
            let result = try await handler.handleMeasureWhiteBalance()
            print("White balance measured: SceneCCT_K = \(result.sceneCCT_K)K, tint = \(String(format: "%.1f", result.tint))")
            return .json(result)
        } catch {
            print("White balance measure failed: \(error.localizedDescription)")
            return .error(status: 500, code: "MEASURE_FAILED", message: error.localizedDescription)
        }
    }

    private func handleUpdateAlias(body: Data?) async -> HTTPResponse {
        guard let body = body else {
            return .badRequest(code: "INVALID_REQUEST", message: "Missing request body")
        }

        let request: AliasUpdateRequest
        do {
            request = try JSONDecoder().decode(AliasUpdateRequest.self, from: body)
        } catch {
            return .badRequest(code: "INVALID_JSON", message: "Invalid alias update request: \(error.localizedDescription)")
        }

        let trimmedAlias = request.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAlias.isEmpty, trimmedAlias.count <= 64 else {
            return .badRequest(code: "INVALID_ALIAS", message: "Alias must be 1-64 characters")
        }

        guard let handler = requestHandler else {
            return .internalError(message: "No request handler")
        }

        do {
            let result = try await handler.handleUpdateAlias(request)
            print("Alias updated to: \(result.alias)")
            return .json(result)
        } catch {
            print("Alias update failed: \(error.localizedDescription)")
            return .error(status: 500, code: "ALIAS_UPDATE_FAILED", message: error.localizedDescription)
        }
    }

    private func handleGetTorchLevel() async -> HTTPResponse {
        guard let handler = requestHandler else {
            return .internalError(message: "No request handler")
        }
        let response = await handler.handleGetTorchLevel()
        return .json(response)
    }

    private func handlePutTorchLevel(body: Data?) async -> HTTPResponse {
        guard let body = body else {
            return .badRequest(code: "INVALID_REQUEST", message: "Missing request body")
        }

        let request: TorchLevelUpdateRequest
        do {
            request = try JSONDecoder().decode(TorchLevelUpdateRequest.self, from: body)
        } catch {
            return .badRequest(code: "INVALID_JSON", message: "Invalid torch level request: \(error.localizedDescription)")
        }

        guard let handler = requestHandler else {
            return .internalError(message: "No request handler")
        }

        do {
            let response = try await handler.handleUpdateTorchLevel(request)
            print("Torch level updated to: \(response.currentLevel)")
            return .json(response)
        } catch {
            print("Torch level update failed: \(error.localizedDescription)")
            return .error(status: 500, code: "TORCH_UPDATE_FAILED", message: error.localizedDescription)
        }
    }

    private func handleLogsDownload() -> HTTPResponse {
        return .error(status: 501, code: "NOT_IMPLEMENTED", message: "Logs download not yet implemented")
    }
}
