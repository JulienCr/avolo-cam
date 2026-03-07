//
//  CaptureManager+Format.swift
//  AvoCam
//
//  CaptureManager extension for format selection and capabilities
//

@preconcurrency import AVFoundation
import CoreMedia
import os

// MARK: - Format Configuration & Capabilities

extension CaptureManager {

    /// Synchronous format configuration for use on sessionQueue (actor-isolated convenience)
    func configureFormatSync(device: AVCaptureDevice, resolution: String, framerate: Int) throws {
        try Self.configureFormatSyncStatic(
            device: device, resolution: resolution, framerate: framerate,
            lens: currentLens, formatCache: formatCache,
            enableSensorLockOptimizations: enableSensorLockOptimizations,
            enableBufferPoolOptimization: enableBufferPoolOptimization,
            poolSize: poolSize,
            bufferPoolLock: bufferPoolLock,
            pixelBufferPoolSetter: { [self] pool in
                nonisolated(unsafe) let sendablePool = pool
                bufferPoolLock.withLock {
                    pixelBufferPool = sendablePool
                }
            }
        )
    }

    /// Nonisolated static format configuration for use from sessionQueue closure
    /// All actor-isolated state is passed in as parameters to avoid isolation violations
    nonisolated static func configureFormatSyncStatic(
        device: AVCaptureDevice,
        resolution: String,
        framerate: Int,
        lens: String,
        formatCache: [String: AVCaptureDevice.Format],
        enableSensorLockOptimizations: Bool,
        enableBufferPoolOptimization: Bool,
        poolSize: Int,
        bufferPoolLock: OSAllocatedUnfairLock<Void>,
        pixelBufferPoolSetter: (CVPixelBufferPool) -> Void
    ) throws {
        guard let parsed = resolution.parseResolution() else {
            throw CaptureError.invalidResolution
        }
        let dimensions = (width: Int32(parsed.width), height: Int32(parsed.height))

        // Check format cache first
        let cacheKey = formatCacheKey(deviceID: device.uniqueID, lens: lens,
                                       width: Int(dimensions.width), height: Int(dimensions.height), fps: framerate)
        let format: AVCaptureDevice.Format
        if let cachedFormat = formatCache[cacheKey] {
            format = cachedFormat
            print("✅ Using cached format for \(cacheKey)")
        } else {
            // Find matching format using best-fit logic
            guard
                let foundFormat = findFormat(
                    for: device, width: Int(dimensions.width), height: Int(dimensions.height),
                    framerate: framerate)
            else {
                throw CaptureError.formatNotSupported
            }
            format = foundFormat
            // Note: format cache update happens back on actor after configure() returns
            print("✅ Found new format for \(cacheKey)")
        }

        try device.lockForConfiguration()
        device.activeFormat = format

        // Set frame rate
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(framerate))
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration

        // Force sRGB color space to avoid wide color processing (iOS 10+)
        if #available(iOS 10.0, *), device.activeColorSpace != .sRGB {
            device.activeColorSpace = .sRGB
            print("✅ Set color space to sRGB")
        }

        // PERF: Apply sensor lock optimizations (disable HDR, lock sampling)
        // Must be called while device is locked
        // Create a temporary instance-like call via a helper (applySensorLockOptimizationsLocked is nonisolated)
        if enableSensorLockOptimizations {
            applySensorLockOptimizationsLockedStatic(device: device)
        }

        device.unlockForConfiguration()

        // PERF: Create zero-copy buffer pool with IOSurface backing
        if enableBufferPoolOptimization {
            createPixelBufferPoolStatic(
                width: Int(dimensions.width), height: Int(dimensions.height),
                poolSize: poolSize, pixelBufferPoolSetter: pixelBufferPoolSetter
            )
        }

        print("✅ Configured format: \(format.formatDescription)")
    }

    /// Nonisolated static sensor lock optimizations
    nonisolated private static func applySensorLockOptimizationsLockedStatic(device: AVCaptureDevice) {
        if #available(iOS 13.0, *) {
            if device.activeFormat.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = false
                print("✅ PERF: HDR auto-adjust disabled")
            }
        }
        if device.hasFlash && device.flashMode != .off {
            device.flashMode = .off
        }
        if device.isExposureModeSupported(.locked) || device.isExposureModeSupported(.custom) {
            device.setExposureTargetBias(0, completionHandler: nil)
        }
        device.isSubjectAreaChangeMonitoringEnabled = false
        print("✅ PERF: Sensor optimizations applied (bias locked, subject monitoring off, torch managed by tally)")
    }

    /// Nonisolated static pixel buffer pool creation
    nonisolated private static func createPixelBufferPoolStatic(
        width: Int, height: Int, poolSize: Int,
        pixelBufferPoolSetter: (CVPixelBufferPool) -> Void
    ) {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: poolSize
        ]

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            attributes as CFDictionary,
            &pool
        )

        if status == kCVReturnSuccess, let pool = pool {
            pixelBufferPoolSetter(pool)

            // Prewarm pool by allocating and releasing all buffers
            var prewarmBuffers: [CVPixelBuffer] = []
            for _ in 0..<poolSize {
                var buffer: CVPixelBuffer?
                if CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
                   let buffer = buffer {
                    prewarmBuffers.append(buffer)
                }
            }
            prewarmBuffers.removeAll()

            print("✅ PERF: Pixel buffer pool created and prewarmed (\(poolSize) buffers, \(width)x\(height), IOSurface-backed)")
        } else {
            print("⚠️ Failed to create pixel buffer pool: \(status)")
        }
    }

    /// Generate cache key for format lookup
    nonisolated static func formatCacheKey(deviceID: String, lens: String, width: Int, height: Int, fps: Int) -> String {
        return "\(deviceID)_\(lens)_\(width)x\(height)_\(fps)fps"
    }

    /// Instance convenience wrapper
    func formatCacheKey(deviceID: String, lens: String, width: Int, height: Int, fps: Int) -> String {
        return Self.formatCacheKey(deviceID: deviceID, lens: lens, width: width, height: height, fps: fps)
    }

    /// Best-fit format chooser: tolerant to per-lens constraints
    /// 1. Filter by resolution (exact > nearest larger > nearest smaller)
    /// 2. Within those, pick format supporting requested fps (or closest not exceeding maxFrameRate)
    nonisolated static func findFormat(for device: AVCaptureDevice, width: Int, height: Int, framerate: Int)
        -> AVCaptureDevice.Format?
    {
        let targetPixels = width * height

        // Separate formats by resolution match type
        var exactMatch: [AVCaptureDevice.Format] = []
        var largerMatch: [AVCaptureDevice.Format] = []
        var smallerMatch: [AVCaptureDevice.Format] = []

        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let w = Int(dims.width)
            let h = Int(dims.height)

            if w == width && h == height {
                exactMatch.append(format)
            } else {
                let pixels = w * h
                if pixels > targetPixels {
                    largerMatch.append(format)
                } else {
                    smallerMatch.append(format)
                }
            }
        }

        // Sort larger/smaller by distance from target
        largerMatch.sort { abs($0.formatPixelCount - targetPixels) < abs($1.formatPixelCount - targetPixels) }
        smallerMatch.sort { abs($0.formatPixelCount - targetPixels) < abs($1.formatPixelCount - targetPixels) }

        // Try exact, then larger, then smaller
        let candidates = exactMatch + largerMatch + smallerMatch

        // Within candidates, pick the one that best matches framerate
        for format in candidates {
            let ranges = format.videoSupportedFrameRateRanges
            for range in ranges {
                if Double(framerate) >= range.minFrameRate && Double(framerate) <= range.maxFrameRate {
                    return format
                }
            }
        }

        // If no exact fps match, pick first candidate with closest fps not exceeding maxFrameRate
        return candidates.first { format in
            format.videoSupportedFrameRateRanges.contains { range in
                range.maxFrameRate >= Double(framerate) * 0.9  // 10% tolerance
            }
        } ?? candidates.first  // Last resort: any format
    }

    // MARK: - Capabilities

    func getCapabilities() -> [Capability] {
        guard let device = videoDevice else {
            return []
        }

        var capabilities: [Capability] = []
        let commonResolutions = [
            (1280, 720, "1280x720"),
            (1920, 1080, "1920x1080"),
            (2560, 1440, "2560x1440"),
            (3840, 2160, "3840x2160"),
        ]

        // Determine available lenses based on camera position
        let availableLenses: [String]
        if currentCameraPosition == .front {
            // Front camera: only wide available
            availableLenses = ["wide"]
        } else if isUsingVirtualDevice {
            // Back camera with virtual device: all lenses via zoom
            availableLenses = ["wide", "ultra_wide", "telephoto"]
        } else {
            // Back camera without virtual device: only current lens
            availableLenses = [currentLens]
        }

        for (width, height, resString) in commonResolutions {
            let supportedFPS = getAvailableFramerates(for: device, width: width, height: height)

            if !supportedFPS.isEmpty {
                for lens in availableLenses {
                    capabilities.append(
                        Capability(
                            resolution: resString,
                            fps: supportedFPS,
                            codec: ["h264", "hevc"],
                            lens: lens,
                            maxZoom: Double(device.activeFormat.videoMaxZoomFactor)
                        ))
                }
            }
        }

        return capabilities
    }

    private func getAvailableFramerates(for device: AVCaptureDevice, width: Int, height: Int)
        -> [Int]
    {
        var framerates: Set<Int> = []

        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width == width && dimensions.height == height else {
                continue
            }

            for range in format.videoSupportedFrameRateRanges {
                // Common framerates: 24, 25, 30, 60
                let commonRates = [24, 25, 30, 60]
                for rate in commonRates {
                    if Double(rate) >= range.minFrameRate && Double(rate) <= range.maxFrameRate {
                        framerates.insert(rate)
                    }
                }
            }
        }

        return Array(framerates).sorted()
    }
}

// MARK: - AVCaptureDevice.Format Extension

private extension AVCaptureDevice.Format {
    nonisolated var formatPixelCount: Int {
        let dims = CMVideoFormatDescriptionGetDimensions(self.formatDescription)
        return Int(dims.width) * Int(dims.height)
    }
}
