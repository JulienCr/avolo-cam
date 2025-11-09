//
//  ExposureController.swift
//  AvoCam
//
//  Handles exposure (ISO and shutter) control for capture devices
//

import AVFoundation
import CoreMedia
import Foundation

/// Manages exposure settings (ISO and shutter speed) for capture devices
final class ExposureController {

    // MARK: - Properties

    private let logger: PerfLogger

    // Current exposure state
    private var isoMode: ExposureMode = .auto
    private var isoValue: Float = 0
    private var shutterMode: ExposureMode = .auto
    private var shutterValue: Double = 0

    // MARK: - Initialization

    init(logger: PerfLogger) {
        self.logger = logger
    }

    // MARK: - Public API

    /// Apply exposure settings to the device
    /// - Parameters:
    ///   - device: The capture device (must be locked for configuration by caller)
    ///   - isoMode: ISO mode (auto or manual)
    ///   - iso: ISO value (used if isoMode is manual)
    ///   - shutterMode: Shutter mode (auto or manual)
    ///   - shutterS: Shutter speed in seconds (used if shutterMode is manual)
    ///   - framerate: Current framerate (for auto shutter calculation)
    func applyExposure(
        device: AVCaptureDevice,
        isoMode: ExposureMode?,
        iso: Int?,
        shutterMode: ExposureMode?,
        shutterS: Double?,
        framerate: Int
    ) {
        // Update tracked state
        if let mode = isoMode {
            self.isoMode = mode
        }
        if let value = iso, self.isoMode == .manual {
            self.isoValue = Float(value)
        }
        if let mode = shutterMode {
            self.shutterMode = mode
        }
        if let value = shutterS, self.shutterMode == .manual {
            self.shutterValue = value
        }

        // Prepare values for application
        let targetISO = clampISO(self.isoValue, for: device)
        let targetDuration = clampShutterDuration(self.shutterValue, for: device)

        // Apply based on mode combination
        applyExposureMode(
            device: device,
            isoMode: self.isoMode,
            targetISO: targetISO,
            shutterMode: self.shutterMode,
            targetDuration: targetDuration,
            framerate: framerate
        )
    }

    // MARK: - Exposure Mode Application

    private func applyExposureMode(
        device: AVCaptureDevice,
        isoMode: ExposureMode,
        targetISO: Float,
        shutterMode: ExposureMode,
        targetDuration: CMTime,
        framerate: Int
    ) {
        logger.debug("applyExposureSettings: mode=(\(isoMode), \(shutterMode)), custom supported=\(device.isExposureModeSupported(.custom))")

        switch (isoMode, shutterMode) {
        case (.auto, .auto):
            // Both auto - use continuous auto exposure
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
                logger.info("✅ Exposure: Both auto (continuous)")
            } else {
                logger.error("Device does not support continuous auto exposure")
            }

        case (.manual, .auto):
            // Manual ISO, auto shutter - use custom with calculated shutter
            if device.isExposureModeSupported(.custom) {
                // Calculate shutter speed based on framerate (180° shutter angle)
                let autoShutter = CMTime(value: 1, timescale: CMTimeScale(framerate * 2))
                device.setExposureModeCustom(
                    duration: autoShutter,
                    iso: targetISO,
                    completionHandler: nil
                )
                logger.logExposure(
                    isoMode: "manual",
                    iso: Int(targetISO),
                    shutterMode: "auto",
                    shutter: "1/\(framerate * 2)"
                )
            } else {
                logger.error("Device does not support custom exposure mode")
            }

        case (.auto, .manual):
            // Auto ISO, manual shutter - use custom with device's current ISO
            if device.isExposureModeSupported(.custom) {
                let currentDeviceISO = device.iso
                device.setExposureModeCustom(
                    duration: targetDuration,
                    iso: currentDeviceISO,
                    completionHandler: nil
                )
                let shutterDisplay = formatShutterSpeed(targetDuration)
                logger.logExposure(
                    isoMode: "auto",
                    iso: Int(currentDeviceISO),
                    shutterMode: "manual",
                    shutter: shutterDisplay
                )
            } else {
                logger.error("Device does not support custom exposure mode")
            }

        case (.manual, .manual):
            // Both manual - use custom with both specified values
            if device.isExposureModeSupported(.custom) {
                device.setExposureModeCustom(
                    duration: targetDuration,
                    iso: targetISO,
                    completionHandler: nil
                )
                let shutterDisplay = formatShutterSpeed(targetDuration)
                logger.logExposure(
                    isoMode: "manual",
                    iso: Int(targetISO),
                    shutterMode: "manual",
                    shutter: shutterDisplay
                )
            } else {
                logger.error("Device does not support custom exposure mode")
            }
        }
    }

    // MARK: - Helpers

    private func clampISO(_ iso: Float, for device: AVCaptureDevice) -> Float {
        return min(max(iso, device.activeFormat.minISO), device.activeFormat.maxISO)
    }

    private func clampShutterDuration(_ shutterS: Double, for device: AVCaptureDevice) -> CMTime {
        let minD = device.activeFormat.minExposureDuration
        let maxD = device.activeFormat.maxExposureDuration
        var duration = CMTime(seconds: shutterS, preferredTimescale: 1_000_000)

        // Clamp duration to device-supported range
        if duration < minD { duration = minD }
        if duration > maxD { duration = maxD }

        return duration
    }

    private func formatShutterSpeed(_ duration: CMTime) -> String {
        if duration.seconds >= 1 {
            return String(format: "%.3fs", duration.seconds)
        } else {
            return "1/\(Int(1.0 / duration.seconds))"
        }
    }

    // MARK: - State Query

    func getCurrentState() -> (isoMode: ExposureMode, iso: Float, shutterMode: ExposureMode, shutter: Double) {
        return (isoMode: isoMode, iso: isoValue, shutterMode: shutterMode, shutter: shutterValue)
    }
}
