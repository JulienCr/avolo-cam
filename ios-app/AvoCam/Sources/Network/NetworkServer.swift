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
import CommonCrypto

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

                return channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(HTTPServerHandler(server: self))
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

final class HTTPServerHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let server: NetworkServer
    private var requestParts: [HTTPServerRequestPart] = []
    private var headers: HTTPHeaders = HTTPHeaders()
    private var uri: String = ""
    private var method: HTTPMethod = .GET
    private var bodyBuffer: ByteBuffer?

    init(server: NetworkServer) {
        self.server = server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)
        requestParts.append(part)

        switch part {
        case .head(let head):
            self.uri = head.uri
            self.method = head.method
            self.headers = head.headers

            // Check for WebSocket upgrade
            if isWebSocketUpgrade(headers: head.headers) {
                handleWebSocketUpgrade(context: context, head: head)
                return
            }

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

    private func isWebSocketUpgrade(headers: HTTPHeaders) -> Bool {
        guard let upgrade = headers.first(name: "upgrade"),
              upgrade.lowercased() == "websocket" else {
            return false
        }
        return true
    }

    private func handleWebSocketUpgrade(context: ChannelHandlerContext, head: HTTPRequestHead) {
        // Extract WebSocket key
        guard let key = headers.first(name: "sec-websocket-key") else {
            sendHTTPResponse(context: context, response: HTTPResponse(status: 400, body: Data()))
            return
        }

        // Calculate accept key
        let acceptKey = calculateWebSocketAcceptKey(key: key)

        // Send upgrade response
        var upgradeHeaders = HTTPHeaders()
        upgradeHeaders.add(name: "Upgrade", value: "websocket")
        upgradeHeaders.add(name: "Connection", value: "Upgrade")
        upgradeHeaders.add(name: "Sec-WebSocket-Accept", value: acceptKey)

        let responseHead = HTTPResponseHead(
            version: head.version,
            status: .switchingProtocols,
            headers: upgradeHeaders
        )

        context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)

        // Remove HTTP handlers and add WebSocket handlers
        context.pipeline.removeHandler(self, promise: nil)

        let wsHandler = WebSocketServerHandler(server: server)
        _ = context.pipeline.addHandler(WebSocketFrameEncoder())
        _ = context.pipeline.addHandler(WebSocketFrameDecoder())
        _ = context.pipeline.addHandler(wsHandler)

        print("🔌 WebSocket upgrade complete")
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

        // Handle request asynchronously
        let path = uri.components(separatedBy: "?").first ?? uri
        Task {
            let response = await server.handleHTTPRequest(
                path: path,
                method: method.rawValue,
                headers: headersDict,
                body: bodyData
            )
            self.sendHTTPResponse(context: context, response: response)
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

    private func calculateWebSocketAcceptKey(key: String) -> String {
        let magicString = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = key + magicString
        guard let data = combined.data(using: .utf8) else {
            return ""
        }

        // Calculate SHA-1 hash
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &hash)
        }

        return Data(hash).base64EncodedString()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("❌ HTTP handler error: \(error)")
        context.close(promise: nil)
    }
}

// MARK: - WebSocket Server Handler

final class WebSocketServerHandler: ChannelInboundHandler {
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
