//
//  BufferPoolManager.swift
//  AvoCam
//
//  Manages pixel buffer pool for zero-copy optimization
//

import CoreVideo
import Foundation

/// Manages IOSurface-backed pixel buffer pool for zero-copy performance optimization
/// Eliminates 8-12ms allocation latency per frame at 4K
final class BufferPoolManager {

    // MARK: - Properties

    private var pool: CVPixelBufferPool?
    private let poolSize: Int
    private let logger: PerfLogger
    private let config: CaptureConfig

    // MARK: - Initialization

    init(config: CaptureConfig, logger: PerfLogger) {
        self.config = config
        self.poolSize = config.poolSize
        self.logger = logger
    }

    // MARK: - Pool Management

    /// Create IOSurface-backed pixel buffer pool
    /// - Parameters:
    ///   - width: Buffer width in pixels
    ///   - height: Buffer height in pixels
    func createPool(width: Int, height: Int) {
        guard config.enableBufferPool else {
            logger.debug("Buffer pool optimization disabled")
            return
        }

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],  // Enable IOSurface backing
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: poolSize
        ]

        var newPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            attributes as CFDictionary,
            &newPool
        )

        if status == kCVReturnSuccess, let newPool = newPool {
            pool = newPool

            // Prewarm pool by allocating and releasing all buffers
            prewarmPool(pool: newPool)

            logger.info("✅ PERF: Pixel buffer pool created and prewarmed (\(poolSize) buffers, \(width)x\(height), IOSurface-backed)")
        } else {
            logger.error("Failed to create pixel buffer pool: \(status)")
        }
    }

    /// Prewarm the buffer pool by allocating and releasing all buffers
    private func prewarmPool(pool: CVPixelBufferPool) {
        var prewarmBuffers: [CVPixelBuffer] = []
        for _ in 0..<poolSize {
            var buffer: CVPixelBuffer?
            if CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
               let buffer = buffer {
                prewarmBuffers.append(buffer)
            }
        }
        prewarmBuffers.removeAll()  // Release back to pool
    }

    /// Destroy the current pool (useful when reconfiguring)
    func destroyPool() {
        if pool != nil {
            pool = nil
            logger.debug("Buffer pool destroyed")
        }
    }

    /// Get the current pool (for external use if needed)
    func getPool() -> CVPixelBufferPool? {
        return pool
    }

    // MARK: - Health Metrics

    /// Get pool health information (for diagnostics)
    func getPoolHealth() -> (exists: Bool, size: Int) {
        return (exists: pool != nil, size: poolSize)
    }
}
