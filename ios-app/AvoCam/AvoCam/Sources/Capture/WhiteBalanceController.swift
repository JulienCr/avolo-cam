//
//  WhiteBalanceController.swift
//  AvoCam
//
//  Handles white balance control for capture devices
//

import AVFoundation
import Foundation

/// Manages white balance settings for capture devices
final class WhiteBalanceController {

    // MARK: - Properties

    private let logger: PerfLogger

    // MARK: - Initialization

    init(logger: PerfLogger) {
        self.logger = logger
    }

    // MARK: - Public API

    /// Apply white balance settings to the device
    /// - Parameters:
    ///   - device: The capture device (must be locked for configuration by caller)
    ///   - mode: White balance mode (auto or manual)
    ///   - sceneCCT_K: Scene color temperature in Kelvin (physical illumination, for manual mode)
    ///   - tint: Tint adjustment (for manual mode)
    func applyWhiteBalance(
        device: AVCaptureDevice,
        mode: WhiteBalanceMode,
        sceneCCT_K: Int?,
        tint: Double?
    ) {
        logger.debug("Applying white balance mode: \(mode)")

        switch mode {
        case .auto:
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
                logger.info("✅ White balance set to auto")
            }

        case .manual:
            logger.debug("WB checks: locked=\(device.isWhiteBalanceModeSupported(.locked)), customGains=\(device.isLockingWhiteBalanceWithCustomDeviceGainsSupported), hasKelvin=\(sceneCCT_K != nil)")

            if device.isWhiteBalanceModeSupported(.locked),
               device.isLockingWhiteBalanceWithCustomDeviceGainsSupported,
               let kelvin = sceneCCT_K
            {
                // Clamp to reasonable range for video
                let clampedCCT = min(max(kelvin, 2000), 10000)
                let tintValue = tint ?? 0.0

                // Use official Apple API to convert temperature/tint to gains
                // Apple expects physical scene illumination temperature (no inversion needed!)
                let tempTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                    temperature: Float(clampedCCT),
                    tint: Float(tintValue)
                )
                var gains = device.deviceWhiteBalanceGains(for: tempTint)

                // Clamp to device range
                gains = clampGains(gains, for: device)

                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)

                // Debug round-trip to verify applied values
                let rt = device.temperatureAndTintValues(for: gains)
                logger.logWhiteBalance(kelvin: clampedCCT, tint: tintValue)
                logger.debug("Applied: SceneCCT \(Int(rt.temperature))K, tint \(String(format: "%.1f", rt.tint))")
                logger.debug("Gains: R=\(String(format: "%.3f", gains.redGain)) G=\(String(format: "%.3f", gains.greenGain)) B=\(String(format: "%.3f", gains.blueGain))")
            } else {
                if !device.isWhiteBalanceModeSupported(.locked) {
                    logger.error("Device does not support locked white balance mode")
                }
                if !device.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                    logger.error("Device does not support locking white balance with custom gains")
                }
                if sceneCCT_K == nil {
                    logger.error("No white balance kelvin value provided")
                }
            }
        }
    }

    /// Measures white balance by enabling auto mode, waiting for convergence, then returning measured values
    /// Returns physical scene CCT (SceneCCT_K) - NOT UI Kelvin
    /// This is like "one-shot AWB" on professional cameras
    func measureWhiteBalance(device: AVCaptureDevice) async throws -> (sceneCCT_K: Int, tint: Double) {
        logger.info("📸 Measuring white balance (auto mode for 2 seconds)...")

        // Enable auto white balance
        try device.lockForConfiguration()
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        } else {
            device.unlockForConfiguration()
            throw CaptureError.whiteBalanceNotSupported
        }
        device.unlockForConfiguration()

        // Wait for white balance to converge (typically 1-2 seconds)
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Read the converged gains
        let gains = device.deviceWhiteBalanceGains

        // Convert gains back to temperature and tint using Apple's API
        // This returns the PHYSICAL scene illumination temperature (SceneCCT_K)
        let tempTint = device.temperatureAndTintValues(for: gains)

        let sceneCCT_K = Int(tempTint.temperature)
        let tint = Double(tempTint.tint)

        logger.debug("Measured WB gains: R=\(String(format: "%.3f", gains.redGain)) G=\(String(format: "%.3f", gains.greenGain)) B=\(String(format: "%.3f", gains.blueGain))")
        logger.info("✅ Measured WB: SceneCCT_K = \(sceneCCT_K)K (physical scene illumination), Tint = \(String(format: "%.1f", tint))")

        // Return physical scene CCT
        return (sceneCCT_K: sceneCCT_K, tint: tint)
    }

    // MARK: - Helpers

    /// Clamp white balance gains to device-safe range
    private func clampGains(
        _ gains: AVCaptureDevice.WhiteBalanceGains,
        for device: AVCaptureDevice
    ) -> AVCaptureDevice.WhiteBalanceGains {
        var g = gains
        let maxG = device.maxWhiteBalanceGain
        g.redGain   = max(1.0, min(g.redGain,   maxG))   // clamp R
        g.greenGain = max(1.0, min(g.greenGain, maxG))   // clamp G
        g.blueGain  = max(1.0, min(g.blueGain,  maxG))   // clamp B
        return g
    }
}
