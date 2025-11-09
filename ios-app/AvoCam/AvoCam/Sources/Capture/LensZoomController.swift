//
//  LensZoomController.swift
//  AvoCam
//
//  Handles lens switching and zoom control for capture devices
//

import AVFoundation
import Foundation

/// Manages lens switching and zoom factor application
final class LensZoomController {

    // MARK: - Properties

    private let logger: PerfLogger

    // MARK: - Initialization

    init(logger: PerfLogger) {
        self.logger = logger
    }

    // MARK: - Public API

    /// Determine if a lens change requires reconfiguration or can be handled via zoom
    /// - Parameters:
    ///   - newLens: The requested lens
    ///   - currentLens: The current active lens
    ///   - position: Camera position
    ///   - isVirtualDevice: Whether using a virtual multi-camera device
    /// - Returns: (needsReconfigure, targetZoom) tuple
    func evaluateLensChange(
        newLens: String,
        currentLens: String,
        position: AVCaptureDevice.Position,
        isVirtualDevice: Bool
    ) -> (needsReconfigure: Bool, targetZoom: CGFloat?) {

        // Guard: front camera only supports wide
        if position == .front && newLens != Lens.wide {
            logger.warning("Front camera only supports 'wide' lens, ignoring request for '\(newLens)'")
            return (needsReconfigure: false, targetZoom: nil)
        }

        // No change needed
        if newLens == currentLens {
            return (needsReconfigure: false, targetZoom: nil)
        }

        // Virtual device can switch via zoom
        if isVirtualDevice {
            logger.info("📷 Switching to \(newLens) lens via zoom")
            return (needsReconfigure: false, targetZoom: nil)  // Zoom will be applied separately
        }

        // Physical device needs reconfiguration
        logger.info("📷 Switching to \(newLens) lens - reconfigure needed")
        return (needsReconfigure: true, targetZoom: nil)
    }

    /// Apply zoom factor to device
    /// - Parameters:
    ///   - device: The capture device (must be locked for configuration by caller)
    ///   - zoomFactor: Desired zoom factor
    ///   - isVirtualDevice: Whether using a virtual device
    /// - Returns: Detected lens for virtual devices, or nil
    func applyZoom(
        device: AVCaptureDevice,
        zoomFactor: CGFloat,
        isVirtualDevice: Bool
    ) -> String? {
        let clampedZoom = min(max(zoomFactor, device.minAvailableVideoZoomFactor), device.activeFormat.videoMaxZoomFactor)
        device.videoZoomFactor = clampedZoom

        let uiZoom = clampedZoom / 2.0

        if isVirtualDevice {
            let detectedLens = lensForZoomFactor(clampedZoom, device: device)
            logger.logZoomApplied(uiZoom: uiZoom, deviceZoom: Double(clampedZoom), lens: detectedLens)
            return detectedLens
        } else {
            logger.logZoomApplied(uiZoom: uiZoom, deviceZoom: Double(clampedZoom), lens: "current")
            return nil
        }
    }

    /// Apply lens-specific zoom for virtual devices
    /// - Parameters:
    ///   - device: The capture device (must be locked for configuration by caller)
    ///   - lens: Target lens
    ///   - isVirtualDevice: Whether using a virtual device
    /// - Returns: True if zoom was applied
    func applyLensZoom(
        device: AVCaptureDevice,
        lens: String,
        isVirtualDevice: Bool
    ) -> Bool {
        guard isVirtualDevice, let lensZoom = zoomFactorForLens(lens, device: device) else {
            return false
        }

        let clampedZoom = min(max(lensZoom, device.minAvailableVideoZoomFactor), device.activeFormat.videoMaxZoomFactor)
        device.videoZoomFactor = clampedZoom

        let uiZoom = clampedZoom / 2.0
        logger.logZoomApplied(uiZoom: uiZoom, deviceZoom: Double(clampedZoom), lens: lens)

        return true
    }

    /// Reset to base zoom for physical lens
    /// - Parameter device: The capture device (must be locked for configuration by caller)
    func resetToBaseZoom(device: AVCaptureDevice, lens: String) {
        let baseZoom: CGFloat = 1.0
        let clampedZoom = min(max(baseZoom, device.minAvailableVideoZoomFactor), device.activeFormat.videoMaxZoomFactor)
        device.videoZoomFactor = clampedZoom
        logger.info("✅ Physical lens '\(lens)' at base zoom \(String(format: "%.1f", clampedZoom))x (no digital zoom)")
    }

    // MARK: - Lens <-> Zoom Mapping

    /// Get zoom factor for a lens on virtual devices
    /// Device zoom values: ultra-wide=1.0, wide=2.0, telephoto=10.0
    private func zoomFactorForLens(_ lens: String, device: AVCaptureDevice) -> CGFloat? {
        // Device zoom factors (what AVFoundation actually uses)
        // Ultra-wide is at 1.0x, wide is at 2.0x (2x zoom from ultra-wide)
        let targetZoom: CGFloat
        switch lens {
        case Lens.ultraWide:
            targetZoom = 1.0   // Ultra-wide baseline
        case Lens.telephoto:
            targetZoom = 10.0  // Telephoto (5x UI = 10x device)
        case Lens.wide:
            fallthrough
        default:
            targetZoom = 2.0   // Wide (1x UI = 2x device)
        }

        // Clamp to device's available zoom range
        let clampedZoom = min(max(targetZoom, device.minAvailableVideoZoomFactor), device.activeFormat.videoMaxZoomFactor)
        return clampedZoom
    }

    /// Detect which lens is active based on the device zoom factor
    /// Device thresholds: 1.5 (between ultra-wide and wide), 6.0 (between wide and tele)
    private func lensForZoomFactor(_ zoomFactor: CGFloat, device: AVCaptureDevice) -> String {
        // Detection based on device zoom values
        // ultra-wide=1.0, wide=2.0, telephoto=10.0
        // Thresholds: 1.5 (midpoint between 1.0 and 2.0), 6.0 (midpoint between 2.0 and 10.0)

        if zoomFactor < 1.5 {
            return Lens.ultraWide  // < 1.5x device zoom
        } else if zoomFactor >= 6.0 {
            return Lens.telephoto   // >= 6.0x device zoom
        } else {
            return Lens.wide        // 1.5x - 6.0x device zoom
        }
    }

    // MARK: - Virtual Device Info

    /// Get virtual device switch-over factors for logging
    func getVirtualDeviceSwitchFactors(device: AVCaptureDevice) -> [NSNumber] {
        return device.virtualDeviceSwitchOverVideoZoomFactors
    }
}
