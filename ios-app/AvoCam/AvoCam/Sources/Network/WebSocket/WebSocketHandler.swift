//
//  WebSocketHandler.swift
//  AvoCam
//
//  Per-connection WebSocket handler
//

import Foundation
import NIO
import NIOWebSocket

// MARK: - WebSocket Server Handler

@preconcurrency
final class WebSocketServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    // MARK: - Properties

    private let hub: WebSocketHub
    private var client: WebSocketClient?

    // MARK: - Initialization

    init(hub: WebSocketHub) {
        self.hub = hub
    }

    // MARK: - Lifecycle

    func handlerAdded(context: ChannelHandlerContext) {
        client = WebSocketClient(channel: context.channel)
        if let client = client {
            hub.addClient(client)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        if let client = client {
            hub.removeClient(client)
        }
        client = nil
    }

    // MARK: - Channel Read

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)

        switch frame.opcode {
        case .text:
            handleTextFrame(frame: frame)

        case .binary:
            handleBinaryFrame(frame: frame)

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

    // MARK: - Frame Handling

    private func handleTextFrame(frame: WebSocketFrame) {
        var data = frame.unmaskedData
        guard let text = data.readString(length: data.readableBytes) else {
            print("⚠️ Failed to read WebSocket text frame")
            return
        }

        handleWebSocketMessage(text: text)
    }

    private func handleBinaryFrame(frame: WebSocketFrame) {
        var data = frame.unmaskedData
        guard let bytes = data.readBytes(length: data.readableBytes) else {
            print("⚠️ Failed to read WebSocket binary frame")
            return
        }

        handleWebSocketMessage(data: Data(bytes))
    }

    // MARK: - Message Processing

    private func handleWebSocketMessage(text: String) {
        // Decode WebSocket command
        guard let data = text.data(using: .utf8) else {
            print("⚠️ Invalid WebSocket text encoding")
            return
        }

        do {
            let message = try JSONCodec.shared.decode(WebSocketCommandMessage.self, from: data)
            handleCommand(message: message)
        } catch {
            print("⚠️ Invalid WebSocket message: \(error)")
        }
    }

    private func handleWebSocketMessage(data: Data) {
        print("📥 WS binary data received: \(data.count) bytes")
        // Binary commands not currently used
    }

    private func handleCommand(message: WebSocketCommandMessage) {
        // Handle camera control commands
        if message.op == "set", let cameraSettings = message.camera {
            Task {
                // Forward to request handler
                // Note: This would require async support in the handler
                print("📥 WS camera command: \(cameraSettings)")
            }
        }
    }

    // MARK: - Error Handling

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("❌ WebSocket handler error: \(error)")
        context.close(promise: nil)
    }
}
