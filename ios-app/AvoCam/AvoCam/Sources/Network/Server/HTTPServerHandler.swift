//
//  HTTPServerHandler.swift
//  AvoCam
//
//  SwiftNIO channel handler for HTTP requests
//

import Foundation
import NIO
import NIOHTTP1

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
        let methodString = method.rawValue

        // Handle request asynchronously
        Task {
            let response = await server.handleHTTPRequest(
                path: path,
                method: methodString,
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
        print("HTTP handler error: \(error)")
        context.close(promise: nil)
    }
}
