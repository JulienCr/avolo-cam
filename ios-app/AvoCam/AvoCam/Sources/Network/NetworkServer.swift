//
//  NetworkServer.swift
//  AvoCam
//
//  HTTP REST + WebSocket server using SwiftNIO (Refactored)
//  Bootstrap only - delegates to modular components
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

// MARK: - Server Configuration

struct ServerConfig {
    let port: Int
    let bearerToken: String
    var authenticationEnabled: Bool
    let rateLimitInterval: TimeInterval

    init(port: Int, bearerToken: String, authenticationEnabled: Bool = false, rateLimitInterval: TimeInterval = 0.05) {
        self.port = port
        self.bearerToken = bearerToken
        self.authenticationEnabled = authenticationEnabled
        self.rateLimitInterval = rateLimitInterval
    }
}

// MARK: - Network Server

class NetworkServer {
    // MARK: - Properties

    private let config: ServerConfig
    private weak var requestHandler: NetworkRequestHandler?

    // NIO Components
    private var group: MultiThreadedEventLoopGroup?
    private var bootstrap: ServerBootstrap?
    private var channel: Channel?

    // Modular components
    private let router: HTTPRouter
    private let webSocketHub: WebSocketHub
    private let telemetryBroadcaster: TelemetryBroadcaster
    private let statusController: StatusController
    private let streamController: StreamController
    private let cameraController: CameraController
    private let webUIProvider: WebUIProvider

    // MARK: - Initialization

    init(port: Int, bearerToken: String, requestHandler: NetworkRequestHandler?) {
        self.config = ServerConfig(port: port, bearerToken: bearerToken)
        self.requestHandler = requestHandler

        // Initialize modular components
        self.webSocketHub = WebSocketHub()
        self.telemetryBroadcaster = TelemetryBroadcaster(hub: webSocketHub)
        self.statusController = StatusController(handler: requestHandler)
        self.streamController = StreamController(handler: requestHandler)
        self.cameraController = CameraController(handler: requestHandler)
        self.webUIProvider = WebUIProvider()

        // Build middleware chain
        let middlewares: [HTTPMiddleware] = [
            CORSMiddleware(),
            AuthMiddleware(bearerToken: bearerToken, enabled: config.authenticationEnabled),
            RateLimitMiddleware(
                pathPredicate: { $0.contains("/camera") },
                minInterval: config.rateLimitInterval
            ),
            ContentTypeMiddleware()
        ]

        // Initialize router with middleware
        self.router = HTTPRouter(middlewares: middlewares)

        // Register routes
        registerRoutes()
    }

    // MARK: - Configuration

    func setAuthenticationEnabled(_ enabled: Bool) {
        // Note: Middleware chain is built at init time
        // For dynamic auth, we'd need to rebuild the router or use a ref type for config
        print("⚠️ Authentication setting change requires server restart")
    }

    // MARK: - Route Registration

    private func registerRoutes() {
        // Status endpoints
        router.get("/api/v1/status", handler: statusController.getStatus)
        router.get("/api/v1/capabilities", handler: statusController.getCapabilities)

        // Video settings endpoints
        router.get("/api/v1/video/settings", handler: statusController.getVideoSettings)
        router.put("/api/v1/video/settings", handler: statusController.updateVideoSettings)

        // Stream control endpoints
        router.post("/api/v1/stream/start", handler: streamController.startStream)
        router.post("/api/v1/stream/stop", handler: streamController.stopStream)
        router.post("/api/v1/encoder/force_keyframe", handler: streamController.forceKeyframe)

        // Camera settings endpoints
        router.post("/api/v1/camera", handler: cameraController.updateCameraSettings)
        router.post("/api/v1/camera/wb/measure", handler: cameraController.measureWhiteBalance)
        router.post("/api/v1/screen/brightness", handler: cameraController.updateScreenBrightness)

        // Settings endpoints
        router.put("/api/v1/settings/alias", handler: cameraController.updateAlias)

        // Torch endpoints
        router.get("/api/v1/torch/level", handler: statusController.getTorchLevel)
        router.put("/api/v1/torch/level", handler: statusController.updateTorchLevel)

        // Logs endpoint
        router.get("/api/v1/logs.zip", handler: statusController.downloadLogs)

        // Web UI
        router.get("/", handler: webUIProvider.serve)
    }

    // MARK: - Server Control

    func start() throws {
        print("🌐 Starting HTTP/WebSocket server on port \(config.port)")

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

                // Configure WebSocket upgrade
                let upgrader = NIOWebSocketServerUpgrader(
                    shouldUpgrade: { (channel: Channel, head: HTTPRequestHead) in
                        // Check for WebSocket upgrade request
                        guard head.uri == "/ws",
                              head.headers["upgrade"].first?.lowercased() == "websocket" else {
                            return channel.eventLoop.makeSucceededFuture(nil)
                        }

                        // Validate bearer token if authentication is enabled
                        if self.config.authenticationEnabled {
                            guard let authHeader = head.headers["authorization"].first,
                                  authHeader.hasPrefix("Bearer "),
                                  authHeader.dropFirst("Bearer ".count) == self.config.bearerToken else {
                                return channel.eventLoop.makeSucceededFuture(nil)
                            }
                        }

                        return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                    },
                    upgradePipelineHandler: { (channel: Channel, _: HTTPRequestHead) in
                        // Add WebSocket handler to the pipeline
                        let wsHandler = WebSocketServerHandler(hub: self.webSocketHub)
                        return channel.pipeline.addHandler(wsHandler).flatMap {
                            // Mark HTTP handler as upgraded
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

                // Configure HTTP pipeline with WebSocket upgrade support
                return channel.pipeline.configureHTTPServerPipeline(
                    withPipeliningAssistance: false,
                    withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in })
                ).flatMap {
                    channel.pipeline.addHandler(HTTPServerHandler(router: self.router), name: "HTTPHandler")
                }
            }

        guard let bootstrap = bootstrap else {
            throw NetworkError.serverStartFailed
        }

        channel = try bootstrap.bind(host: "0.0.0.0", port: config.port).wait()

        print("✅ Server started on port \(config.port)")
    }

    func stop() {
        // Close all WebSocket connections
        webSocketHub.closeAll()

        // Shutdown server
        try? channel?.close().wait()
        try? group?.syncShutdownGracefully()

        channel = nil
        bootstrap = nil
        group = nil

        print("⏹ Server stopped")
    }

    // MARK: - Telemetry Broadcasting

    /// Broadcast telemetry to all WebSocket clients
    func broadcastTelemetry(_ telemetry: Telemetry, ndiState: NDIState) {
        telemetryBroadcaster.broadcast(telemetry: telemetry, ndiState: ndiState)
    }
}
