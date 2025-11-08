//
//  TorchController.swift
//  AvoCam
//
//  Manages iPhone torch (flashlight) for NDI tally indication
//

import AVFoundation
import os.log

/// Actor-based torch controller for safe, concurrent torch management
/// Uses minimum torch level (0.01) to avoid glare and heat
actor TorchController {

    // MARK: - Properties

    private var currentState: Bool = false
    private let torchLevel: Float = 0.03  // Minimum level to avoid glare/heat
    private let logger = Logger(subsystem: "com.avocam.torch", category: "TorchController")

    // MARK: - Public API

    /// Set torch state based on NDI program tally
    /// - Parameter programOn: true if camera is on program, false otherwise
    func set(programOn: Bool) async {
        // Avoid redundant configuration changes
        guard programOn != currentState else { return }

        currentState = programOn

        // Get video device
        guard let device = AVCaptureDevice.default(for: .video) else {
            logger.warning("No video device available for torch control")
            return
        }

        guard device.hasTorch else {
            logger.warning("Device does not support torch")
            return
        }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if programOn {
                // Turn torch ON at minimum level
                if device.isTorchModeSupported(.on) {
                    try device.setTorchModeOn(level: torchLevel)
                    logger.info("🔦 Torch ON (program tally) at level \(self.torchLevel)")
                }
            } else {
                // Turn torch OFF
                device.torchMode = .off
                logger.info("🔦 Torch OFF (not on program)")
            }
        } catch {
            logger.error("Failed to set torch mode: \(error.localizedDescription)")
        }
    }

    /// Force torch off (for cleanup/shutdown)
    func forceOff() async {
        guard currentState else { return }

        currentState = false

        guard let device = AVCaptureDevice.default(for: .video),
            device.hasTorch
        else { return }

        do {
            try device.lockForConfiguration()
            device.torchMode = .off
            device.unlockForConfiguration()
            logger.info("🔦 Torch force OFF")
        } catch {
            logger.error("Failed to force torch off: \(error.localizedDescription)")
        }
    }
}
