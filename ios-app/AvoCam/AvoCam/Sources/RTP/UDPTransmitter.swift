//
//  UDPTransmitter.swift
//  AvoCam
//
//  Ultra-low-latency UDP transmitter using Network.framework
//

import Foundation
import Network

/// Errors that can occur during UDP transmission
enum UDPTransmitterError: Error {
    case invalidHost
    case invalidPort
    case connectionFailed(Error)
    case notConnected
    case sendFailed(Error)
}

/// Network.framework UDP sender for RTP packets
actor UDPTransmitter {
    // MARK: - Properties

    private var connection: NWConnection?
    private var connectionState: NWConnection.State = .setup
    private let queue = DispatchQueue(label: "com.avocam.udp", qos: .userInteractive)

    // Telemetry
    private var sentPackets: Int64 = 0
    private var sentBytes: Int64 = 0
    private var sendErrors: Int64 = 0

    // MARK: - Connection State

    /// Check if UDP connection is ready
    var isConnected: Bool {
        return connectionState == .ready
    }

    // MARK: - Connection Management

    /// Connect to UDP destination
    /// - Parameters:
    ///   - host: Destination IP address or hostname
    ///   - port: Destination UDP port
    func connect(host: String, port: UInt16) async throws {
        print("🌐 Connecting UDP to \(host):\(port)")

        // Close existing connection if any
        if let existing = connection {
            existing.cancel()
            connection = nil
        }

        // Create endpoint
        guard let portObj = NWEndpoint.Port(rawValue: port) else {
            throw UDPTransmitterError.invalidPort
        }

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: portObj
        )

        // Configure UDP parameters
        let parameters = NWParameters.udp

        // Optimize for low latency
        parameters.allowLocalEndpointReuse = false
        parameters.includePeerToPeer = false

        // Set quality of service
        parameters.serviceClass = .responsiveData

        // Create connection
        let newConnection = NWConnection(to: endpoint, using: parameters)

        // Wait for connection to reach a terminal state using a single continuation
        // instead of a polling loop. Timeout via a racing Task.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @Sendable in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    // Guard against multiple resumes since stateUpdateHandler fires for every transition
                    var hasResumed = false

                    newConnection.stateUpdateHandler = { [weak self] state in
                        Task {
                            await self?.handleStateChange(state)
                        }

                        guard !hasResumed else { return }

                        switch state {
                        case .ready:
                            hasResumed = true
                            continuation.resume()
                        case .failed(let error):
                            hasResumed = true
                            continuation.resume(throwing: UDPTransmitterError.connectionFailed(error))
                        case .cancelled:
                            hasResumed = true
                            continuation.resume(throwing: UDPTransmitterError.connectionFailed(
                                NSError(domain: "UDPTransmitter", code: -2, userInfo: [
                                    NSLocalizedDescriptionKey: "Connection cancelled"
                                ])
                            ))
                        case .setup, .preparing, .waiting:
                            // Intermediate states -- keep waiting
                            break
                        @unknown default:
                            break
                        }
                    }

                    // Start connection on the dedicated queue
                    newConnection.start(queue: self.queue)
                }
            }

            // Timeout task
            group.addTask { @Sendable in
                try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                throw UDPTransmitterError.connectionFailed(
                    NSError(domain: "UDPTransmitter", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "Connection timeout"
                    ])
                )
            }

            // Wait for the first task to complete (either connected or timed out)
            // then cancel the remaining task
            try await group.next()
            group.cancelAll()
        }

        connection = newConnection
        connectionState = .ready

        print("✅ UDP connected to \(host):\(port)")
    }

    /// Disconnect UDP connection
    func disconnect() async {
        guard let conn = connection else { return }

        print("🔌 Disconnecting UDP")
        conn.cancel()
        connection = nil
        connectionState = .cancelled

        print("✅ UDP disconnected")
    }

    // MARK: - Data Transmission

    /// Send data via UDP (fire-and-forget for ultra-low latency)
    /// - Parameter data: Data to send
    /// - Note: Does not await send completion. Errors are tracked via telemetry counters,
    ///   not thrown per-packet. This avoids 30-40 sequential awaits per 4K frame.
    func send(_ data: Data) throws {
        guard let conn = connection else {
            throw UDPTransmitterError.notConnected
        }

        guard connectionState == .ready else {
            throw UDPTransmitterError.notConnected
        }

        let byteCount = data.count

        // Fire-and-forget: no await, errors tracked asynchronously via telemetry
        conn.send(
            content: data,
            completion: .contentProcessed { [weak self] error in
                guard let self = self else { return }
                Task {
                    if error != nil {
                        await self.recordSendError()
                    } else {
                        await self.recordSentData(bytes: byteCount)
                    }
                }
            }
        )
    }

    // MARK: - Telemetry

    /// Get transmission statistics
    /// - Returns: Tuple of (sentPackets, sentBytes, sendErrors)
    func getStats() -> (sentPackets: Int64, sentBytes: Int64, sendErrors: Int64) {
        return (sentPackets, sentBytes, sendErrors)
    }

    /// Reset telemetry counters
    func resetStats() {
        sentPackets = 0
        sentBytes = 0
        sendErrors = 0
    }

    // MARK: - Private Methods

    /// Handle connection state changes
    /// - Parameter state: New connection state
    private func handleStateChange(_ state: NWConnection.State) {
        connectionState = state

        switch state {
        case .setup:
            print("🔄 UDP state: setup")
        case .preparing:
            print("🔄 UDP state: preparing")
        case .ready:
            print("✅ UDP state: ready")
        case .waiting(let error):
            print("⏳ UDP state: waiting (\(error))")
        case .failed(let error):
            print("❌ UDP state: failed (\(error))")
        case .cancelled:
            print("🛑 UDP state: cancelled")
        @unknown default:
            print("⚠️ UDP state: unknown")
        }
    }

    /// Record successful data transmission
    /// - Parameter bytes: Number of bytes sent
    private func recordSentData(bytes: Int) {
        sentPackets += 1
        sentBytes += Int64(bytes)
    }

    /// Record send error
    private func recordSendError() {
        sendErrors += 1
    }
}
