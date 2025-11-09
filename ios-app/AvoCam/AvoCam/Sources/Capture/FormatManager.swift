//
//  FormatManager.swift
//  AvoCam
//
//  Format selection and caching for AVCaptureDevice
//

import AVFoundation
import CoreMedia

/// Manages format selection, caching, and application for capture devices
final class FormatManager {

    // MARK: - Properties

    private var formatCache: [String: AVCaptureDevice.Format] = [:]
    private let logger: PerfLogger

    // MARK: - Initialization

    init(logger: PerfLogger) {
        self.logger = logger
    }

    // MARK: - Format Selection

    /// Find and apply the best format for the given device and parameters
    /// - Parameters:
    ///   - device: The capture device
    ///   - resolution: Target resolution (e.g., "1920x1080")
    ///   - framerate: Target framerate
    ///   - lens: Current lens (for cache key)
    /// - Throws: CaptureError if format not found or cannot be applied
    func configureFormat(
        device: AVCaptureDevice,
        resolution: String,
        framerate: Int,
        lens: String
    ) throws {
        let dims = try Resolution(string: resolution)

        // Check format cache first
        let cacheKey = formatCacheKey(
            deviceID: device.uniqueID,
            lens: lens,
            width: Int(dims.width),
            height: Int(dims.height),
            fps: framerate
        )

        let format: AVCaptureDevice.Format
        if let cachedFormat = formatCache[cacheKey] {
            format = cachedFormat
            logger.debug("Using cached format for \(cacheKey)")
        } else {
            // Find matching format using best-fit logic
            guard let foundFormat = findBestFormat(
                for: device,
                width: Int(dims.width),
                height: Int(dims.height),
                framerate: framerate
            ) else {
                throw CaptureError.formatNotSupported
            }
            format = foundFormat
            formatCache[cacheKey] = format
            logger.debug("Cached new format for \(cacheKey)")
        }

        // Apply format to device (device must be locked by caller)
        try applyFormat(format, to: device, framerate: framerate)
    }

    // MARK: - Format Finding

    /// Best-fit format chooser: tolerant to per-lens constraints
    /// 1. Filter by resolution (exact > nearest larger > nearest smaller)
    /// 2. Within those, pick format supporting requested fps (or closest not exceeding maxFrameRate)
    private func findBestFormat(
        for device: AVCaptureDevice,
        width: Int,
        height: Int,
        framerate: Int
    ) -> AVCaptureDevice.Format? {
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

    // MARK: - Format Application

    /// Apply the selected format to the device
    /// - Note: Device must be locked for configuration by caller
    private func applyFormat(
        _ format: AVCaptureDevice.Format,
        to device: AVCaptureDevice,
        framerate: Int
    ) throws {
        device.activeFormat = format

        // Set frame rate
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(framerate))
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration

        // Force sRGB color space to avoid wide color processing (iOS 10+)
        if #available(iOS 10.0, *), device.activeColorSpace != .sRGB {
            device.activeColorSpace = .sRGB
            logger.debug("Set color space to sRGB")
        }

        logger.logFormatConfigured(format)
    }

    // MARK: - Cache Management

    /// Generate cache key for format lookup
    private func formatCacheKey(
        deviceID: String,
        lens: String,
        width: Int,
        height: Int,
        fps: Int
    ) -> String {
        return "\(deviceID)_\(lens)_\(width)x\(height)_\(fps)fps"
    }

    /// Clear the format cache (useful when switching devices)
    func clearCache() {
        formatCache.removeAll()
        logger.debug("Format cache cleared")
    }

    // MARK: - Capabilities Query

    /// Get available framerates for a specific resolution on the device
    func getAvailableFramerates(
        for device: AVCaptureDevice,
        width: Int,
        height: Int
    ) -> [Int] {
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
    var formatPixelCount: Int {
        let dims = CMVideoFormatDescriptionGetDimensions(self.formatDescription)
        return Int(dims.width) * Int(dims.height)
    }
}
