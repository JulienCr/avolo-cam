//
//  CaptureConfig.swift
//  AvoCam
//
//  Central configuration for capture system feature flags and defaults
//

import Foundation

/// Configuration for capture system behavior and optimizations
struct CaptureConfig {
    // MARK: - Performance Features

    /// Enable zero-copy buffer pool optimization (eliminates 8-12ms allocation latency at 4K)
    let enableBufferPool: Bool

    /// Enable sensor lock optimizations (disable HDR, continuous adjustments)
    let enableSensorLocks: Bool

    /// Enable os_signpost for latency tracking
    let enableSignposts: Bool

    // MARK: - Buffer Pool Settings

    /// Number of buffers in the pool (2x framerate headroom)
    let poolSize: Int

    // MARK: - Defaults

    static let `default` = CaptureConfig(
        enableBufferPool: true,
        enableSensorLocks: true,
        enableSignposts: true,
        poolSize: 6
    )

    // MARK: - Test Configuration

    /// Configuration for testing with all optimizations disabled
    static let testing = CaptureConfig(
        enableBufferPool: false,
        enableSensorLocks: false,
        enableSignposts: false,
        poolSize: 3
    )
}
