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

    /// Latency in milliseconds (default: 120ms)
    let latency: Int

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

    /// Default SRT configuration for 1080p30
    static var `default`: SRTConfiguration {
        return SRTConfiguration(
            port: 9000,
            latency: 120,
            passphrase: nil,
            width: 1920,
            height: 1080,
            fps: 30,
            bitrate: 10_000_000
        )
    }

    /// Create configuration from stream start request
    /// - Parameter request: The stream start request
    /// - Returns: SRT configuration
    static func from(request: StreamStartRequest) -> SRTConfiguration {
        let components = request.resolution.split(separator: "x")
        let width = Int(components.first ?? "1920") ?? 1920
        let height = Int(components.last ?? "1080") ?? 1080

        return SRTConfiguration(
            port: request.srtPort ?? 9000,
            latency: request.srtLatency ?? 120,
            passphrase: request.srtPassphrase,
            width: width,
            height: height,
            fps: request.framerate,
            bitrate: request.bitrate
        )
    }

    /// Convert to SRTManager.Configuration
    func toManagerConfiguration() -> SRTManager.Configuration {
        return SRTManager.Configuration(
            port: port,
            latency: latency,
            passphrase: passphrase,
            width: width,
            height: height,
            fps: fps,
            bitrate: bitrate
        )
    }
}
