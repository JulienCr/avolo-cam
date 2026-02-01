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

        // Disable congestion control for lowest latency (fire-and-forget)
        if let udpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolUDP.Options {
            // UDP options can be configured here if needed
            // For now, we use defaults which is suitable for RTP
        }

        // Set quality of service
        parameters.serviceClass = .responsiveData

        // Create connection
        let newConnection = NWConnection(to: endpoint, using: parameters)

        // Set up state handler
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var hasContinued = false

            newConnection.stateUpdateHandler = { [weak self] state in
                Task {
                    await self?.handleStateChange(state)

                    // Resume continuation on first state update
                    if !hasContinued {
                        hasContinued = true
                        continuation.resume()
                    }
                }
            }

            // Start connection
            newConnection.start(queue: queue)
        }

        connection = newConnection

        // Wait for connection to be ready (with timeout)
        let startTime = Date()
        let timeout: TimeInterval = 5.0

        while connectionState != .ready {
            if Date().timeIntervalSince(startTime) > timeout {
                throw UDPTransmitterError.connectionFailed(
                    NSError(domain: "UDPTransmitter", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "Connection timeout"
                    ])
                )
            }

            if case .failed(let error) = connectionState {
                throw UDPTransmitterError.connectionFailed(error)
            }

            if connectionState == .cancelled {
                throw UDPTransmitterError.connectionFailed(
                    NSError(domain: "UDPTransmitter", code: -2, userInfo: [
                        NSLocalizedDescriptionKey: "Connection cancelled"
                    ])
                )
            }

            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }

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

    /// Send data via UDP
    /// - Parameter data: Data to send
    func send(_ data: Data) async throws {
        guard let conn = connection else {
            throw UDPTransmitterError.notConnected
        }

        guard connectionState == .ready else {
            throw UDPTransmitterError.notConnected
        }

        // Send data (fire-and-forget for low latency)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            conn.send(
                content: data,
                completion: .contentProcessed { [weak self] error in
                    Task {
                        if let error = error {
                            await self?.recordSendError()
                            print("⚠️ UDP send error: \(error)")
                        } else {
                            await self?.recordSentData(bytes: data.count)
                        }
                        continuation.resume()
                    }
                }
            )
        }
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
