//
//  WebSocketHub.swift
//  AvoCam
//
//  WebSocket client registry and broadcast management
//

import Foundation
import NIO
import NIOWebSocket

// MARK: - WebSocket Client

class WebSocketClient {
    private let channel: Channel
    private let eventLoop: EventLoop

    init(channel: Channel) {
        self.channel = channel
        self.eventLoop = channel.eventLoop
    }

    /// Send text message to client
    func send(text: String) {
        let buffer = channel.allocator.buffer(string: text)
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
        channel.writeAndFlush(frame, promise: nil)
    }

    /// Send binary data to client
    func send(data: Data) {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let frame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)
        channel.writeAndFlush(frame, promise: nil)
    }

    /// Close connection
    func close() {
        _ = channel.close(mode: .all)
    }
}

// MARK: - WebSocket Hub

/// Thread-safe WebSocket client registry with broadcasting
class WebSocketHub {
    // MARK: - Properties

    private var clients: [WebSocketClient] = []
    private let lock = NSLock()

    // MARK: - Client Management

    /// Add a client to the hub
    func addClient(_ client: WebSocketClient) {
        lock.lock()
        clients.append(client)
        let count = clients.count
        lock.unlock()

        print("🔌 WebSocket client connected (total: \(count))")
    }

    /// Remove a client from the hub
    func removeClient(_ client: WebSocketClient) {
        lock.lock()
        clients.removeAll { $0 === client }
        let count = clients.count
        lock.unlock()

        print("🔌 WebSocket client disconnected (total: \(count))")
    }

    /// Get current client count
    var clientCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return clients.count
    }

    // MARK: - Broadcasting

    /// Broadcast text message to all connected clients
    func broadcast(text: String) {
        lock.lock()
        let clientsCopy = clients
        lock.unlock()

        for client in clientsCopy {
            client.send(text: text)
        }
    }

    /// Broadcast binary data to all connected clients
    func broadcast(data: Data) {
        lock.lock()
        let clientsCopy = clients
        lock.unlock()

        for client in clientsCopy {
            client.send(data: data)
        }
    }

    // MARK: - Lifecycle

    /// Close all connections and clear clients
    func closeAll() {
        lock.lock()
        let clientsCopy = clients
        clients.removeAll()
        lock.unlock()

        for client in clientsCopy {
            client.close()
        }

        print("🔌 All WebSocket clients closed")
    }
}
