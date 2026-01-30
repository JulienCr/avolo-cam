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
        let latency: Int  // milliseconds
        let passphrase: String?
        let width: Int
        let height: Int
        let fps: Int
        let bitrate: Int
    }

    // MARK: - Initialization

    init() {
        encoder = H264Encoder()
        print("🎥 SRTManager initialized")
    }

    // MARK: - Lifecycle

    /// Start SRT streaming with the given configuration
    /// - Parameter config: SRT and encoding configuration
    func start(config: Configuration) async throws {
        print("🚀 Starting SRT stream: \(config.width)x\(config.height) @ \(config.fps)fps")
        print("🔌 SRT Port: \(config.port), Latency: \(config.latency)ms")

        currentConfig = config

        // Configure H.264 encoder first
        do {
            try await encoder.configure(
                width: config.width,
                height: config.height,
                fps: config.fps,
                bitrate: config.bitrate
            )
        } catch {
            print("❌ Failed to configure encoder: \(error)")
            throw SRTError.encoderConfigurationFailed
        }

        // Set encoder callback to send NAL units via SRT
        await encoder.setCallback { [weak self] sampleBuffer in
            Task {
                await self?.sendEncodedFrame(sampleBuffer)
            }
        }

        // Create and configure SRT socket in listener mode
        do {
            let socket = SRTSocket()

            // Build the SRT URL for binding
            let srtUrl = URL(string: "srt://0.0.0.0:\(config.port)")!

            // Bind to the port
            try socket.bind(to: srtUrl)
            print("✅ SRT socket bound to port \(config.port)")

            // Start listening for connections
            try socket.listen(withBacklog: 1)
            print("👂 SRT listening for connections...")

            self.srtSocket = socket

            // Start accepting connections in background
            acceptTask = Task { [weak self] in
                await self?.acceptConnectionLoop()
            }

        } catch {
            print("❌ Failed to setup SRT socket: \(error)")
            throw SRTError.socketCreationFailed
        }

        // Initialize telemetry
        sentFrames = 0
        droppedFrames = 0
        sentBytes = 0
        frameCount = 0
        fpsStartTime = CFAbsoluteTimeGetCurrent()
        isRunning = true

        print("✅ SRT stream started successfully - waiting for OBS connection on port \(config.port)")
    }

    /// Accept incoming SRT connections
    private func acceptConnectionLoop() async {
        guard let socket = srtSocket else { return }

        while isRunning {
            do {
                // Accept blocks until a client connects
                let client = try socket.accept()
                print("🔗 SRT client connected!")

                // Store the connected client
                await MainActor.run {
                    Task { await self.setConnectedClient(client) }
                }

            } catch {
                if isRunning {
                    print("⚠️ Error accepting SRT connection: \(error)")
                    // Brief delay before retrying
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                }
            }
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

        print("⏹ Stopping SRT stream")
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

        print("✅ SRT stream stopped")
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

        // Extract NAL units from CMSampleBuffer
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            print("⚠️ No data buffer in sample")
            droppedFrames += 1
            return
        }

        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )

        guard status == noErr, let pointer = dataPointer else {
            print("⚠️ Failed to get data pointer: \(status)")
            droppedFrames += 1
            return
        }

        // Convert to Data for sending
        let data = Data(bytes: pointer, count: length)

        // Send via SRT
        do {
            try client.write(data: data)
            sentFrames += 1
            sentBytes += Int64(length)

            // Log keyframes
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
               let firstAttachment = attachments.first {
                let isKeyframe = !(firstAttachment[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
                if isKeyframe {
                    print("🔑 Keyframe sent (\(length) bytes)")
                }
            }
        } catch {
            print("⚠️ SRT send failed: \(error)")
            droppedFrames += 1

            // Client may have disconnected
            connectedClient = nil
        }
    }
}
