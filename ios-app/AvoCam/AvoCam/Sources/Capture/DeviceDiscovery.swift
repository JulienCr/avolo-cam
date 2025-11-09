//
//  DeviceDiscovery.swift
//  AvoCam
//
//  Device discovery and selection logic for AVCaptureDevice
//

import AVFoundation
import Foundation

/// Pure functions for discovering and selecting the best capture device
enum DeviceDiscovery {

    // MARK: - Device Discovery

    /// Find the best capture device for the requested position and lens
    /// - Parameters:
    ///   - position: Camera position (.front or .back)
    ///   - requestedLens: Requested lens type (wide, ultra_wide, telephoto)
    /// - Returns: Tuple of (device, isVirtual) or throws if no device found
    /// - Throws: CaptureError.deviceNotAvailable if no suitable device found
    static func findBestDevice(
        position: AVCaptureDevice.Position,
        requestedLens: String
    ) throws -> (device: AVCaptureDevice, isVirtual: Bool) {

        // Get prioritized device types for discovery
        let deviceTypes = prioritizedDeviceTypes(for: position, requestedLens: requestedLens)

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: position
        )

        guard let device = discovery.devices.first else {
            throw CaptureError.deviceNotAvailable
        }

        // Check if using virtual device (can switch lenses via zoom)
        let isVirtual = isVirtualDevice(device)

        return (device: device, isVirtual: isVirtual)
    }

    // MARK: - Device Type Selection

    /// Returns prioritized device types for discovery
    /// Always use physical cameras to support full manual control (WB/ISO/shutter)
    /// Virtual devices don't support custom exposure or custom WB gains
    static func prioritizedDeviceTypes(
        for position: AVCaptureDevice.Position,
        requestedLens: String
    ) -> [AVCaptureDevice.DeviceType] {

        if position == .back {
            // Map requested lens to device type
            let requestedType: AVCaptureDevice.DeviceType
            switch requestedLens {
            case Lens.ultraWide:
                requestedType = .builtInUltraWideCamera
            case Lens.telephoto:
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

            return types
        } else {
            // Front camera: typically only wide available
            return [.builtInWideAngleCamera]
        }
    }

    // MARK: - Device Classification

    /// Check if a device is a virtual multi-camera device (can switch lenses via zoom)
    static func isVirtualDevice(_ device: AVCaptureDevice) -> Bool {
        return [
            AVCaptureDevice.DeviceType.builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera
        ].contains(device.deviceType)
    }

    // MARK: - Device Information

    /// Get a description of the device type for logging
    static func deviceTypeDescription(_ device: AVCaptureDevice) -> String {
        switch device.deviceType {
        case .builtInWideAngleCamera:
            return "Wide Angle"
        case .builtInUltraWideCamera:
            return "Ultra Wide"
        case .builtInTelephotoCamera:
            return "Telephoto"
        case .builtInTripleCamera:
            return "Triple Camera (Virtual)"
        case .builtInDualWideCamera:
            return "Dual Wide (Virtual)"
        case .builtInDualCamera:
            return "Dual Camera (Virtual)"
        default:
            return device.deviceType.rawValue
        }
    }
}
