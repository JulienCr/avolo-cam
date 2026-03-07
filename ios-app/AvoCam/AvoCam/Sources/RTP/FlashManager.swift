//
//  FlashManager.swift
//  AvoCam
//
//  Flash streaming manager with ultra-low-latency UDP/RTP transport
//

import Foundation
import CoreMedia
import CoreVideo

/// Errors that can occur during Flash streaming
enum FlashError: Error, LocalizedError {
    case notInitialized
    case encoderConfigurationFailed
    case connectionFailed(Error)
    case transmissionFailed
    case invalidConfiguration

    var errorDescription: String? {
        switch self {
        case .notInitialized: return "Flash not initialized"
        case .encoderConfigurationFailed: return "Failed to configure H.264 encoder"
        case .connectionFailed(let error): return "Connection failed: \(error.localizedDescription)"
        case .transmissionFailed: return "Failed to transmit RTP packet"
        case .invalidConfiguration: return "Invalid Flash configuration"
        }
    }
}

/// Flash streaming manager with H.264/RTP over UDP for ultra-low latency
actor FlashManager {
    // MARK: - Configuration

    struct Configuration {
        let destinationHost: String
        let destinationPort: UInt16  // Default: 5000
        let width: Int
        let height: Int
        let fps: Int
        let bitrate: Int
        let gopSize: Int             // Keyframe interval (frames)

        /// Create default Flash configuration
        static func `default`(host: String) -> Configuration {
            return Configuration(
                destinationHost: host,
                destinationPort: 5000,
                width: 1920,
                height: 1080,
                fps: 25,
                bitrate: 10_000_000,
                gopSize: 3
            )
        }
    }

    // MARK: - Properties

    private let encoder: H264Encoder
    private let packetizer: RTPPacketizer
    private let transmitter: UDPTransmitter
    private var isRunning = false
    private var currentConfig: Configuration?

    // Dynamic UDP port tracking (for multi-camera support)
    private(set) var activeUdpPort: UInt16 = 0

    // Telemetry
    private var sentFrames: Int64 = 0
    private var droppedFrames: Int64 = 0
    private var currentFps: Double = 0.0
    private var frameCount: Int = 0
    private var fpsStartTime: CFAbsoluteTime = 0

    // Frame info callback for WebSocket correlation
    typealias FrameInfoCallback = @Sendable (WebSocketFrameInfo) -> Void
    private var onFrameInfo: FrameInfoCallback?

    // MARK: - Initialization

    init() {
        encoder = H264Encoder()
        packetizer = RTPPacketizer()
        transmitter = UDPTransmitter()
        print("⚡️ FlashManager initialized (RTP/UDP streaming)")
    }

    // MARK: - Lifecycle

    /// Start Flash streaming with the given configuration
    /// - Parameter config: Flash streaming configuration
    func start(config: Configuration) async throws {
        print("🚀 Starting Flash stream: \(config.width)x\(config.height) @ \(config.fps)fps")
        print("🎯 Destination: \(config.destinationHost):\(config.destinationPort)")
        print("📊 Bitrate: \(config.bitrate / 1_000_000) Mbps, GOP: \(config.gopSize)")

        currentConfig = config

        // Validate configuration
        guard config.width > 0, config.height > 0, config.fps > 0, config.bitrate > 0 else {
            throw FlashError.invalidConfiguration
        }

        // Configure H.264 encoder
        do {
            try await encoder.configure(
                width: config.width,
                height: config.height,
                fps: config.fps,
                bitrate: config.bitrate,
                gopSize: config.gopSize
            )
        } catch {
            print("❌ Failed to configure encoder: \(error)")
            throw FlashError.encoderConfigurationFailed
        }

        // Set encoder callback to packetize and send
        await encoder.setCallback { [weak self] sampleBuffer in
            Task {
                await self?.handleEncodedFrame(sampleBuffer)
            }
        }

        // Connect UDP transmitter
        do {
            try await transmitter.connect(
                host: config.destinationHost,
                port: config.destinationPort
            )
        } catch {
            print("❌ Failed to connect UDP: \(error)")
            throw FlashError.connectionFailed(error)
        }

        // Store the active UDP port for multi-camera support
        activeUdpPort = config.destinationPort

        // Initialize telemetry
        sentFrames = 0
        droppedFrames = 0
        frameCount = 0
        fpsStartTime = CFAbsoluteTimeGetCurrent()
        isRunning = true

        print("✅ Flash stream started successfully")
        print("📺 Streaming RTP/H.264 to \(config.destinationHost):\(config.destinationPort)")
    }

    /// Send a pixel buffer for encoding and transmission
    /// - Parameters:
    ///   - pixelBuffer: The pixel buffer to encode
    ///   - timestamp: Presentation timestamp
    ///   - duration: Frame duration
    func send(pixelBuffer: CVPixelBuffer, timestamp: CMTime, duration: CMTime) async {
        guard isRunning else {
            print("⚠️ FLASH send: not running, skipping frame")
            return
        }

        // Update FPS calculation
        frameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - fpsStartTime
        if elapsed >= 1.0 {
            currentFps = Double(frameCount) / elapsed
            frameCount = 0
            fpsStartTime = now
        }

        // Encode frame (callback will handle packetization and transmission)
        await encoder.encode(pixelBuffer: pixelBuffer, presentationTime: timestamp, duration: duration)
    }

    /// Stop Flash streaming
    func stop() async {
        guard isRunning else { return }

        print("⏹ Stopping Flash stream")
        isRunning = false

        // Clear active UDP port
        activeUdpPort = 0

        // Stop encoder
        await encoder.stop()

        // Disconnect UDP
        await transmitter.disconnect()

        print("✅ Flash stream stopped")
    }

    /// Set callback for frame info notifications (for WebSocket correlation)
    /// - Parameter callback: Callback to invoke with frame timing information
    func setFrameInfoCallback(_ callback: @escaping FrameInfoCallback) {
        onFrameInfo = callback
    }

    // MARK: - Telemetry

    /// Get current streaming statistics
    /// - Returns: Tuple of (fps, sentFrames, droppedFrames)
    func getStats() -> (fps: Double, sentFrames: Int64, droppedFrames: Int64) {
        return (currentFps, sentFrames, droppedFrames)
    }

    /// Get detailed statistics including network stats
    /// - Returns: Dictionary of statistics
    func getDetailedStats() async -> [String: Any] {
        let (fps, sent, dropped) = getStats()
        let (packets, bytes, errors) = await transmitter.getStats()

        return [
            "fps": fps,
            "sentFrames": sent,
            "droppedFrames": dropped,
            "sentPackets": packets,
            "sentBytes": bytes,
            "sendErrors": errors,
            "isConnected": await transmitter.isConnected
        ]
    }

    // MARK: - Private Methods

    /// Handle encoded frame from H.264 encoder
    /// - Parameter sampleBuffer: Encoded H.264 sample buffer
    private func handleEncodedFrame(_ sampleBuffer: CMSampleBuffer) async {
        guard isRunning else { return }

        guard await transmitter.isConnected else {
            // Not connected, drop frame silently
            droppedFrames += 1
            return
        }

        do {
            // Packetize H.264 into RTP packets
            let rtpPackets = try await packetizer.packetize(sampleBuffer: sampleBuffer)

            // Debug: log packet info periodically
            if sentFrames % 30 == 0 {
                print("📤 FLASH TX: Frame \(sentFrames), \(rtpPackets.count) RTP packets")
                if let first = rtpPackets.first {
                    let header = first.data.prefix(16)
                    print("   First packet: \(first.data.count) bytes, header: \(header.map { String(format: "%02X", $0) }.joined(separator: " "))")
                }
            }

            // Send each RTP packet via UDP
            for packet in rtpPackets {
                do {
                    try await transmitter.send(packet.data)
                } catch {
                    print("⚠️ Failed to send RTP packet (seq: \(packet.sequenceNumber)): \(error)")
                    droppedFrames += 1
                    return
                }
            }

            // Frame sent successfully
            sentFrames += 1

            // Send frame info via WebSocket for latency correlation
            if let callback = onFrameInfo, let firstPacket = rtpPackets.first {
                let captureTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let captureNs = Int64(CMTimeGetSeconds(captureTime) * 1_000_000_000)
                let encodeNs = Int64(CFAbsoluteTimeGetCurrent() * 1_000_000_000)

                let frameInfo = WebSocketFrameInfo(
                    op: "frame_info",
                    frameIdx: sentFrames,
                    rtpTimestamp: firstPacket.timestamp,
                    captureTs: captureNs,
                    encodeTs: encodeNs
                )

                callback(frameInfo)
            }

        } catch {
            print("⚠️ Failed to packetize frame: \(error)")
            droppedFrames += 1
        }
    }
}
