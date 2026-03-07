//
//  WebSocketClient.swift
//  AvoCam
//
//  Represents a connected WebSocket client
//

import Foundation
import NIO
import NIOWebSocket

@preconcurrency
nonisolated final class WebSocketClient: @unchecked Sendable {
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
