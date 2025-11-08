//
//  TorchController.swift
//  AvoCam
//
//  Manages iPhone torch (flashlight) for NDI tally indication
//

import AVFoundation
import os.log

/// Actor-based torch controller for safe, concurrent torch management
/// Uses device-specific minimum torch level to avoid glare and heat
actor TorchController {

    // MARK: - Properties

    private var currentState: Bool = false
    private var torchLevel: Float
    private let logger = Logger(subsystem: "com.avocam.torch", category: "TorchController")

    // UserDefaults key for persisting custom torch level
    private static let torchLevelKey = "com.avocam.customTorchLevel"

    // MARK: - Device-Specific Defaults

    /// Get default torch level based on device model
    private static func getDefaultTorchLevel() -> Float {
        let deviceModel = getDeviceModel()

        // iPhone 16 series
        if deviceModel.contains("iPhone17") {
            return 0.01
        }
        // iPhone 15 series
        else if deviceModel.contains("iPhone16") {
            return 0.02
        }
        // iPhone 14 series
        else if deviceModel.contains("iPhone15") {
            return 0.02
        }
        // iPhone 13 series
        else if deviceModel.contains("iPhone14") {
            return 0.02
        }
        // iPhone 12 series
        else if deviceModel.contains("iPhone13") {
            return 0.02
        }
        // iPhone 11 series
        else if deviceModel.contains("iPhone12") {
            return 0.03
        }
        // iPhone XS/XR series (iPhone11,x)
        else if deviceModel.contains("iPhone11") {
            return 0.03
        }
        // iPhone X series (iPhone10,x)
        else if deviceModel.contains("iPhone10") {
            return 0.03
        }
        // Default for older/unknown models
        else {
            return 0.03
        }
    }

    /// Get device model identifier (e.g., "iPhone14,5")
    private static func getDeviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
    }

    // MARK: - Initialization

    init() {
        // Load custom level from UserDefaults, or use device-specific default
        if let savedLevel = UserDefaults.standard.object(forKey: Self.torchLevelKey) as? Float {
            self.torchLevel = savedLevel
        } else {
            self.torchLevel = Self.getDefaultTorchLevel()
        }

        let deviceModel = Self.getDeviceModel()
        let level = self.torchLevel  // Capture for logging
        logger.info("✅ TorchController initialized for \(deviceModel) with level: \(level)")
    }

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
                    let level = torchLevel  // Capture for logging
                    try device.setTorchModeOn(level: level)
                    logger.info("🔦 Torch ON (program tally) at level \(level)")
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

    // MARK: - Torch Level Configuration

    /// Get current torch level (0.01 - 1.0)
    func getTorchLevel() -> Float {
        return torchLevel
    }

    /// Set custom torch level and persist to UserDefaults
    /// - Parameter level: Torch level (0.01 - 1.0)
    /// - Returns: true if level was valid and set, false otherwise
    func setTorchLevel(_ level: Float) -> Bool {
        // Validate level (AVFoundation requires 0.01 - 1.0)
        guard level >= 0.01 && level <= 1.0 else {
            logger.error("Invalid torch level: \(level). Must be 0.01 - 1.0")
            return false
        }

        torchLevel = level
        UserDefaults.standard.set(level, forKey: Self.torchLevelKey)
        logger.info("✅ Torch level set to \(level)")

        return true
    }

    /// Get the device-specific default torch level
    func getDefaultTorchLevel() -> Float {
        return Self.getDefaultTorchLevel()
    }

    /// Reset torch level to device-specific default
    func resetToDefault() {
        let defaultLevel = Self.getDefaultTorchLevel()
        torchLevel = defaultLevel
        UserDefaults.standard.removeObject(forKey: Self.torchLevelKey)
        logger.info("✅ Torch level reset to default: \(defaultLevel)")
    }

    /// Get device model identifier for debugging/telemetry
    func getDeviceModel() -> String {
        return Self.getDeviceModel()
    }
}
