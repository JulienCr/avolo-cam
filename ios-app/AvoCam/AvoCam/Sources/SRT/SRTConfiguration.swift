//
//  SRTConfiguration.swift
//  AvoCam
//
//  SRT configuration models
//

import Foundation

/// SRT streaming configuration
struct SRTConfiguration {
    /// Port number for SRT listener
    let port: Int

    /// General latency in milliseconds
    let latency: Int

    /// Receive latency in milliseconds (nil = use latency)
    let rcvLatency: Int?

    /// Peer latency in milliseconds (nil = use latency)
    let peerLatency: Int?

    /// Drop too-late packets (essential for live streaming)
    let tlPktDrop: Bool

    /// Optional encryption passphrase
    let passphrase: String?

    /// Video width in pixels
    let width: Int

    /// Video height in pixels
    let height: Int

    /// Target frame rate
    let fps: Int

    /// Target bitrate in bits per second
    let bitrate: Int

    /// GOP size in frames (keyframe interval, default: fps = 1 second)
    let gopSize: Int

    /// Effective receive latency (uses rcvLatency if set, otherwise latency)
    var effectiveRcvLatency: Int {
        return rcvLatency ?? latency
    }

    /// Effective peer latency (uses peerLatency if set, otherwise latency)
    var effectivePeerLatency: Int {
        return peerLatency ?? latency
    }

    /// Default SRT configuration for 1080p30
    static var `default`: SRTConfiguration {
        return SRTConfiguration(
            port: 9000,
            latency: 120,
            rcvLatency: nil,
            peerLatency: nil,
            tlPktDrop: true,
            passphrase: nil,
            width: 1920,
            height: 1080,
            fps: 25,
            bitrate: 10_000_000,
            gopSize: 25  // 1 second GOP for stable streaming
        )
    }

    /// Create configuration from stream start request
    /// - Parameter request: The stream start request
    /// - Returns: SRT configuration
    static func from(request: StreamStartRequest) -> SRTConfiguration {
        let (width, height) = request.resolution.parseResolution() ?? (1920, 1080)

        // Default GOP to framerate (1 second) if not specified
        let defaultGop = request.framerate

        return SRTConfiguration(
            port: request.srtPort ?? 9000,
            latency: request.srtLatency ?? 120,
            rcvLatency: request.srtRcvLatency,
            peerLatency: request.srtPeerLatency,
            tlPktDrop: request.srtTlPktDrop ?? true,
            passphrase: request.srtPassphrase,
            width: width,
            height: height,
            fps: request.framerate,
            bitrate: request.bitrate,
            gopSize: request.srtGopSize ?? defaultGop
        )
    }

    /// Convert to SRTManager.Configuration
    func toManagerConfiguration() -> SRTManager.Configuration {
        return SRTManager.Configuration(
            port: port,
            latency: latency,
            rcvLatency: effectiveRcvLatency,
            peerLatency: effectivePeerLatency,
            tlPktDrop: tlPktDrop,
            passphrase: passphrase,
            width: width,
            height: height,
            fps: fps,
            bitrate: bitrate,
            gopSize: gopSize
        )
    }
}
