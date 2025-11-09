//
//  CapabilitiesResolver.swift
//  AvoCam
//
//  Resolves device capabilities (resolutions, framerates, lenses, codecs)
//

import AVFoundation
import Foundation

/// Resolves device capabilities for API responses
final class CapabilitiesResolver {

    // MARK: - Properties

    private let formatManager: FormatManager

    // Common resolutions to check
    private static let commonResolutions: [(width: Int, height: Int, name: String)] = [
        (1280, 720, "1280x720"),
        (1920, 1080, "1920x1080"),
        (2560, 1440, "2560x1440"),
        (3840, 2160, "3840x2160"),
    ]

    // MARK: - Initialization

    init(formatManager: FormatManager) {
        self.formatManager = formatManager
    }

    // MARK: - Capabilities Resolution

    /// Get all capabilities for the current device configuration
    /// - Parameters:
    ///   - device: The capture device
    ///   - position: Camera position
    ///   - currentLens: Current active lens
    ///   - isVirtualDevice: Whether using a virtual device
    /// - Returns: Array of Capability objects
    func getCapabilities(
        device: AVCaptureDevice,
        position: AVCaptureDevice.Position,
        currentLens: String,
        isVirtualDevice: Bool
    ) -> [Capability] {
        var capabilities: [Capability] = []

        // Determine available lenses based on camera position
        let availableLenses = getAvailableLenses(
            position: position,
            isVirtualDevice: isVirtualDevice,
            currentLens: currentLens
        )

        // For each resolution, get supported framerates and create capabilities
        for (width, height, resString) in Self.commonResolutions {
            let supportedFPS = formatManager.getAvailableFramerates(
                for: device,
                width: width,
                height: height
            )

            if !supportedFPS.isEmpty {
                for lens in availableLenses {
                    capabilities.append(
                        Capability(
                            resolution: resString,
                            fps: supportedFPS,
                            codec: ["h264", "hevc"],
                            lens: lens,
                            maxZoom: Double(device.activeFormat.videoMaxZoomFactor)
                        )
                    )
                }
            }
        }

        return capabilities
    }

    // MARK: - Lens Availability

    /// Determine available lenses based on camera position and device type
    private func getAvailableLenses(
        position: AVCaptureDevice.Position,
        isVirtualDevice: Bool,
        currentLens: String
    ) -> [String] {
        if position == .front {
            // Front camera: only wide available
            return [Lens.wide]
        } else if isVirtualDevice {
            // Back camera with virtual device: all lenses via zoom
            return [Lens.wide, Lens.ultraWide, Lens.telephoto]
        } else {
            // Back camera without virtual device: only current lens
            return [currentLens]
        }
    }
}
