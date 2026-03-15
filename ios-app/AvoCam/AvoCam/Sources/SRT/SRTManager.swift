//
//  SRTManager.swift
//  AvoCam
//
//  SRT streaming manager with hardware H.264 encoding using Eyevinn/swift-srt
//

import Foundation
import CoreMedia
import CoreVideo
import SwiftSRT

/// Errors that can occur during SRT operations
enum SRTError: Error, LocalizedError {
    case notInitialized
    case encoderConfigurationFailed
    case socketCreationFailed
    case bindFailed(String)
    case listenFailed
    case connectionFailed
    case sendFailed
    case invalidConfiguration

    var errorDescription: String? {
        switch self {
        case .notInitialized: return "SRT not initialized"
        case .encoderConfigurationFailed: return "Failed to configure H.264 encoder"
        case .socketCreationFailed: return "Failed to create SRT socket"
        case .bindFailed(let reason): return "Failed to bind SRT socket: \(reason)"
        case .listenFailed: return "Failed to listen on SRT socket"
        case .connectionFailed: return "SRT connection failed"
        case .sendFailed: return "Failed to send data via SRT"
        case .invalidConfiguration: return "Invalid SRT configuration"
        }
    }
}

/// SRT streaming manager with hardware-accelerated H.264 encoding
actor SRTManager {
    // MARK: - Properties

    private let encoder: H264Encoder
    private let tsMuxer: TSMuxer
    private var isRunning = false
    private var srtSocket: SRTSocket?
    private var connectedClient: SRTSocket?
    private let sendQueue = DispatchQueue(label: "com.avocam.srt.send", qos: .userInteractive)

    // Telemetry
    private var sentFrames: Int64 = 0
    private var droppedFrames: Int64 = 0
    private var sentBytes: Int64 = 0
    private var currentFps: Double = 0.0
    private var lastFrameTime: CFAbsoluteTime = 0
    private var frameCount: Int = 0
    private var fpsStartTime: CFAbsoluteTime = 0

    // Connection state
    private var acceptTask: Task<Void, Never>?
    private var currentConfig: Configuration?

    // Configuration
    struct Configuration {
        let port: Int
        let latency: Int       // general latency in milliseconds
        let rcvLatency: Int    // receive latency in milliseconds
        let peerLatency: Int   // peer latency in milliseconds
        let tlPktDrop: Bool    // drop too-late packets
        let passphrase: String?
        let width: Int
        let height: Int
        let fps: Int
        let bitrate: Int
        let gopSize: Int       // keyframe interval in frames (default: fps = 1 second)
    }

    // MARK: - Initialization

    init() {
        encoder = H264Encoder()
        tsMuxer = TSMuxer()
        Log.srt.info("SRTManager initialized with MPEG-TS muxer")
    }

    // MARK: - Lifecycle

    /// Start SRT streaming with the given configuration
    /// - Parameter config: SRT and encoding configuration
    func start(config: Configuration) async throws {
        Log.srt.info("Starting SRT stream: \(config.width)x\(config.height) @ \(config.fps)fps")
        Log.srt.info("SRT Port: \(config.port), Latency: \(config.latency)ms")

        currentConfig = config

        // Configure H.264 encoder first
        do {
            try await encoder.configure(
                width: config.width,
                height: config.height,
                fps: config.fps,
                bitrate: config.bitrate,
                gopSize: config.gopSize
            )
        } catch {
            Log.srt.error("Failed to configure encoder: \(error)")
            throw SRTError.encoderConfigurationFailed
        }

        // Set encoder callback to send NAL units via SRT
        await encoder.setCallback { [weak self] sampleBuffer in
            Task {
                await self?.sendEncodedFrame(sampleBuffer)
            }
        }

        // SRT expects latency in MICROSECONDS (1ms = 1000us)
        let latencyUs = config.latency * 1000
        let rcvLatencyUs = config.rcvLatency * 1000
        let peerLatencyUs = config.peerLatency * 1000
        let tlpktdrop = config.tlPktDrop ? 1 : 0

        // Create and configure SRT socket in listener mode
        do {
            let socket = SRTSocket()

            // Build the SRT URL for binding with all latency parameters
            let srtUrl = URL(string: "srt://0.0.0.0:\(config.port)?transtype=live&latency=\(latencyUs)&rcvlatency=\(rcvLatencyUs)&peerlatency=\(peerLatencyUs)&tlpktdrop=\(tlpktdrop)")!

            // Bind to the port
            try socket.bind(to: srtUrl)
            Log.srt.info("SRT socket bound to port \(config.port)")

            // Start listening for connections
            try socket.listen(withBacklog: 1)
            Log.srt.info("SRT listening for connections...")

            self.srtSocket = socket

            // Start accepting connections in background
            acceptTask = Task { [weak self] in
                await self?.acceptConnectionLoop()
            }

        } catch {
            Log.srt.error("Failed to setup SRT socket: \(error)")
            throw SRTError.socketCreationFailed
        }

        // Reset muxer state for new stream
        tsMuxer.reset()

        // Initialize telemetry
        sentFrames = 0
        droppedFrames = 0
        sentBytes = 0
        frameCount = 0
        fpsStartTime = CFAbsoluteTimeGetCurrent()
        isRunning = true

        // Log connection info
        Log.srt.info("SRT stream started successfully - waiting for OBS connection on port \(config.port)")
        Log.srt.info("Connect with: srt://<ip>:\(config.port)?mode=caller&transtype=live&latency=\(latencyUs)&rcvlatency=\(rcvLatencyUs)&peerlatency=\(peerLatencyUs)&tlpktdrop=\(tlpktdrop)")
    }

    /// Accept incoming SRT connections
    private func acceptConnectionLoop() async {
        while isRunning {
            guard let socket = srtSocket else {
                // Socket was closed, try to recreate it
                if isRunning, let config = currentConfig {
                    Log.srt.info("Attempting to recreate SRT listener...")
                    await recreateListener(config: config)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
                continue
            }

            // Don't accept new connections if we already have a client
            if connectedClient != nil {
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                continue
            }

            do {
                // Accept blocks until a client connects
                let client = try socket.accept()
                Log.srt.info("SRT client connected!")

                // Store the connected client
                self.connectedClient = client

            } catch {
                if isRunning && connectedClient == nil {
                    let errorString = "\(error)"
                    // Check if the socket became invalid (common after client disconnect)
                    if errorString.contains("einvsock") || errorString.contains("invalid") {
                        Log.srt.warning("SRT listener socket invalid, will recreate...")
                        // Close the invalid socket
                        srtSocket?.close()
                        srtSocket = nil
                        // Will be recreated on next loop iteration
                    } else {
                        Log.srt.warning("Error accepting SRT connection: \(error)")
                    }
                    // Brief delay before retrying
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
                }
            }
        }
    }

    /// Recreate the SRT listener socket
    private func recreateListener(config: Configuration) async {
        // Close any existing socket
        srtSocket?.close()
        srtSocket = nil

        do {
            let socket = SRTSocket()
            // SRT expects latency in MICROSECONDS (1ms = 1000us)
            let latencyUs = config.latency * 1000
            let rcvLatencyUs = config.rcvLatency * 1000
            let peerLatencyUs = config.peerLatency * 1000
            let tlpktdrop = config.tlPktDrop ? 1 : 0
            let srtUrl = URL(string: "srt://0.0.0.0:\(config.port)?transtype=live&latency=\(latencyUs)&rcvlatency=\(rcvLatencyUs)&peerlatency=\(peerLatencyUs)&tlpktdrop=\(tlpktdrop)")!

            try socket.bind(to: srtUrl)
            Log.srt.info("SRT socket re-bound to port \(config.port)")

            try socket.listen(withBacklog: 1)
            Log.srt.info("SRT listening for connections (recreated)...")

            self.srtSocket = socket
        } catch {
            Log.srt.error("Failed to recreate SRT listener: \(error)")
        }
    }

    private func setConnectedClient(_ client: SRTSocket) {
        self.connectedClient = client
    }

    /// Send a pixel buffer for encoding and transmission
    /// - Parameters:
    ///   - pixelBuffer: The pixel buffer to encode
    ///   - timestamp: Presentation timestamp
    ///   - duration: Frame duration
    func send(pixelBuffer: CVPixelBuffer, timestamp: CMTime, duration: CMTime) async {
        guard isRunning else { return }

        // Update FPS calculation
        frameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - fpsStartTime
        if elapsed >= 1.0 {
            currentFps = Double(frameCount) / elapsed
            frameCount = 0
            fpsStartTime = now
        }

        // Encode frame (callback will send via SRT)
        await encoder.encode(pixelBuffer: pixelBuffer, presentationTime: timestamp, duration: duration)
    }

    /// Stop SRT streaming
    func stop() async {
        guard isRunning else { return }

        Log.srt.info("Stopping SRT stream")
        isRunning = false

        // Cancel accept task
        acceptTask?.cancel()
        acceptTask = nil

        // Stop encoder
        await encoder.stop()

        // Close connected client
        connectedClient?.close()
        connectedClient = nil

        // Close listener socket
        srtSocket?.close()
        srtSocket = nil

        Log.srt.info("SRT stream stopped")
    }

    // MARK: - Telemetry

    /// Get current streaming statistics
    /// - Returns: Tuple of (fps, sentFrames, droppedFrames)
    func getStats() -> (fps: Double, sentFrames: Int64, droppedFrames: Int64) {
        return (currentFps, sentFrames, droppedFrames)
    }

    /// Check if a client is connected
    func isClientConnected() -> Bool {
        return connectedClient != nil
    }

    // MARK: - Private Methods

    /// Send an encoded frame via SRT
    /// - Parameter sampleBuffer: The encoded sample buffer
    private func sendEncodedFrame(_ sampleBuffer: CMSampleBuffer) async {
        guard isRunning else { return }

        // Check if we have a connected client
        guard let client = connectedClient else {
            // No client connected yet, drop frame silently
            return
        }

        // Mux H.264 into MPEG-TS format (required for VLC/OBS compatibility)
        let tsData = tsMuxer.mux(sampleBuffer: sampleBuffer)

        guard !tsData.isEmpty else {
            Log.srt.warning("TSMuxer returned empty data")
            droppedFrames += 1
            return
        }


        // SRT live mode has max payload of 1316 bytes (7 TS packets * 188 = 1316)
        let maxSRTPayload = 1316
        let tsPacketSize = 188
        let packetsPerSend = maxSRTPayload / tsPacketSize  // 7 packets

        // Send MPEG-TS packets in chunks that fit SRT's max payload
        var offset = 0
        var sendError = false
        var chunksSent = 0

        while offset < tsData.count && !sendError {
            let remainingBytes = tsData.count - offset
            let chunkSize = min(packetsPerSend * tsPacketSize, remainingBytes)

            // Ensure we send complete TS packets
            let alignedChunkSize = (chunkSize / tsPacketSize) * tsPacketSize
            guard alignedChunkSize > 0 else { break }

            let chunk = tsData.subdata(in: offset..<(offset + alignedChunkSize))

            do {
                try client.write(data: chunk)
                sentBytes += Int64(alignedChunkSize)
                chunksSent += 1
            } catch {
                Log.srt.warning("SRT send failed at chunk \(chunksSent): \(error)")
                sendError = true
                droppedFrames += 1
                connectedClient = nil
            }

            offset += alignedChunkSize
        }

        if !sendError {
            sentFrames += 1
        }
    }
}
