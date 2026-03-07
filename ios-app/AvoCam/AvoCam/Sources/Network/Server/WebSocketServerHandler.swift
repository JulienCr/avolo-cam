//
//  WebSocketServerHandler.swift
//  AvoCam
//
//  SwiftNIO channel handler for WebSocket connections
//

import Foundation
import NIO
import NIOWebSocket

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
            break

        default:
            break
        }
    }

    private func handleWebSocketMessage(text: String, client: WebSocketClient?) {
        guard let data = text.data(using: .utf8) else {
            print("Invalid WebSocket message encoding")
            return
        }

        struct OpMessage: Codable { let op: String }
        guard let opMsg = try? JSONDecoder().decode(OpMessage.self, from: data) else {
            print("Invalid WebSocket message: missing 'op' field")
            return
        }

        switch opMsg.op {
        case "tally":
            if let tallyMsg = try? JSONDecoder().decode(WebSocketTallyMessage.self, from: data) {
                Task { [weak self] in
                    await self?.server.handleTallyUpdate(program: tallyMsg.program, preview: tallyMsg.preview)
                }
            }

        case "set":
            if let message = try? JSONDecoder().decode(WebSocketCommandMessage.self, from: data),
               let cameraSettings = message.camera {
                Task {
                    print("WS camera command: \(cameraSettings)")
                }
            }

        case "subscribe":
            struct SubscribeMessage: Codable { let op: String; let channels: [String] }
            if let subMsg = try? JSONDecoder().decode(SubscribeMessage.self, from: data) {
                if subMsg.channels.contains("frame_info") {
                    client?.subscribedToFrameInfo = true
                    print("WS client subscribed to frame_info")
                }
            }

        default:
            print("Unknown WebSocket op: \(opMsg.op)")
        }
    }

    private func handleWebSocketMessage(data: Data) {
        print("WS binary data received: \(data.count) bytes")
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("WebSocket handler error: \(error)")
        context.close(promise: nil)
    }
}
