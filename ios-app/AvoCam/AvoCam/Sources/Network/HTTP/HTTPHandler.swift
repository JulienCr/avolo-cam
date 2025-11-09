//
//  HTTPHandler.swift
//  AvoCam
//
//  NIO ChannelHandler bridge for HTTP requests
//

import Foundation
import NIO
import NIOHTTP1

// MARK: - HTTP Server Handler

@preconcurrency
final class HTTPServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    // MARK: - Properties

    private let router: HTTPRouter
    private var requestParts: [HTTPServerRequestPart] = []
    private var headers: NIOHTTP1.HTTPHeaders = NIOHTTP1.HTTPHeaders()
    private var uri: String = ""
    private var method: NIOHTTP1.HTTPMethod = .GET
    private var bodyBuffer: ByteBuffer?
    private var isUpgraded: Bool = false

    // MARK: - Initialization

    init(router: HTTPRouter) {
        self.router = router
    }

    // MARK: - Upgrade Handling

    func markAsUpgraded() {
        isUpgraded = true
    }

    // MARK: - Channel Read

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Ignore data if upgraded to WebSocket
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

    // MARK: - Request Processing

    private func processHTTPRequest(context: ChannelHandlerContext) {
        // Convert NIO types to abstract types
        let request = convertToHTTPRequest()

        // Capture values before reset
        let methodString = method.rawValue

        print("📥 HTTP \(methodString) \(request.path)")

        // Handle request asynchronously via router
        Task {
            let response = await router.route(request: request)

            // Send response on the channel's event loop
            context.eventLoop.execute {
                self.sendHTTPResponse(context: context, response: response)
            }
        }
    }

    // MARK: - Type Conversion

    private func convertToHTTPRequest() -> HTTPRequest {
        // Convert headers to dictionary
        var headersDict: [String: String] = [:]
        for (name, value) in headers {
            headersDict[name] = value
        }

        // Extract path (remove query string)
        let path = uri.components(separatedBy: "?").first ?? uri

        // Convert body buffer to Data
        let bodyData = bodyBuffer.flatMap { buffer in
            Data(buffer.readableBytesView)
        }

        // Convert NIO HTTPMethod to our HTTPMethod
        let httpMethod = HTTPMethod(rawValue: method.rawValue) ?? .GET

        return HTTPRequest(
            method: httpMethod,
            path: path,
            headers: headersDict,
            body: bodyData
        )
    }

    // MARK: - Response Sending

    private func sendHTTPResponse(context: ChannelHandlerContext, response: HTTPResponse) {
        // Create response head
        var nioHeaders = NIOHTTP1.HTTPHeaders()
        for (key, value) in response.headers {
            nioHeaders.add(name: key, value: value)
        }
        nioHeaders.add(name: "Content-Length", value: String(response.body.count))

        let responseHead = HTTPResponseHead(
            version: .http1_1,
            status: HTTPResponseStatus(statusCode: response.status.rawValue),
            headers: nioHeaders
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

    // MARK: - Reset

    private func reset() {
        requestParts.removeAll()
        headers = NIOHTTP1.HTTPHeaders()
        uri = ""
        method = .GET
        bodyBuffer = nil
    }

    // MARK: - Error Handling

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("❌ HTTP handler error: \(error)")
        context.close(promise: nil)
    }
}
