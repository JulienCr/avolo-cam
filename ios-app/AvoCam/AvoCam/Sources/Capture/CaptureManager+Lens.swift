//
//  CaptureManager+Lens.swift
//  AvoCam
//
//  CaptureManager extension for lens selection and zoom factor mapping
//

import AVFoundation

// MARK: - Lens & Zoom

extension CaptureManager {

    /// Returns prioritized device types for discovery
    /// Always use physical cameras to support full manual control (WB/ISO/shutter)
    /// Virtual devices don't support custom exposure or custom WB gains
    func prioritizedDeviceTypes(for position: AVCaptureDevice.Position, requestedLens: String) -> [AVCaptureDevice.DeviceType] {
        if position == .back {
            // Always use physical cameras for full manual control support
            // Lens switching handled via reconfiguration

            // Map requested lens to device type
            let requestedType: AVCaptureDevice.DeviceType
            switch requestedLens {
            case "ultra_wide":
                requestedType = .builtInUltraWideCamera
            case "telephoto":
                requestedType = .builtInTelephotoCamera
            default:  // "wide"
                requestedType = .builtInWideAngleCamera
            }

            // Build prioritized list: requested lens first, then fallbacks
            var types: [AVCaptureDevice.DeviceType] = [requestedType]

            // Add fallbacks (other physical cameras)
            let fallbacks: [AVCaptureDevice.DeviceType] = [
                .builtInWideAngleCamera,
                .builtInUltraWideCamera,
                .builtInTelephotoCamera
            ]
            for type in fallbacks {
                if type != requestedType {
                    types.append(type)
                }
            }

            print("📷 Requesting \(requestedLens) lens first, fallbacks: \(types.map { $0.rawValue })")
            return types
        } else {
            // Front camera: typically only wide available
            return [.builtInWideAngleCamera]
        }
    }

    /// Get zoom factors for lens switching on virtual devices
    /// Device zoom values: ultra-wide=1.0, wide=2.0, telephoto=10.0
    func zoomFactorForLens(_ lens: String, device: AVCaptureDevice) -> CGFloat? {
        guard isUsingVirtualDevice else { return nil }

        // Device zoom factors (what AVFoundation actually uses)
        // Ultra-wide is at 1.0x, wide is at 2.0x (2x zoom from ultra-wide)
        let targetZoom: CGFloat
        switch lens {
        case "ultra_wide":
            targetZoom = 1.0   // Ultra-wide baseline
        case "telephoto":
            targetZoom = 10.0  // Telephoto (5x UI = 10x device)
        case "wide":
            fallthrough
        default:
            targetZoom = 2.0   // Wide (1x UI = 2x device)
        }

        // Clamp to device's available zoom range
        let clampedZoom = min(max(targetZoom, device.minAvailableVideoZoomFactor), device.activeFormat.videoMaxZoomFactor)
        return clampedZoom
    }

    /// Detects which lens is active based on the device zoom factor
    /// Device thresholds: 1.5 (between ultra-wide and wide), 6.0 (between wide and tele)
    func lensForZoomFactor(_ zoomFactor: CGFloat, device: AVCaptureDevice) -> String {
        guard isUsingVirtualDevice else { return "wide" }

        // Detection based on device zoom values
        // ultra-wide=1.0, wide=2.0, telephoto=10.0
        // Thresholds: 1.5 (midpoint between 1.0 and 2.0), 6.0 (midpoint between 2.0 and 10.0)

        if zoomFactor < 1.5 {
            return "ultra_wide"  // < 1.5x device zoom
        } else if zoomFactor >= 6.0 {
            return "telephoto"   // >= 6.0x device zoom
        } else {
            return "wide"        // 1.5x - 6.0x device zoom
        }
    }
}
