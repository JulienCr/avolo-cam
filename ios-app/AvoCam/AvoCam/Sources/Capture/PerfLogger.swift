//
//  PerfLogger.swift
//  AvoCam
//
//  Centralized logging and performance tracking for capture system
//

import Foundation
import os
import os.signpost

/// Centralized logger for capture system with structured logging and signposts
final class PerfLogger {

    // MARK: - Properties

    private let subsystem: String
    private let category: String
    private let logger: OSLog
    private let config: CaptureConfig

    // Signpost tracking
    private nonisolated(unsafe) lazy var signpostID = OSSignpostID(log: logger)

    // MARK: - Log Level

    enum Level {
        case info
        case warning
        case error
        case debug
    }

    // MARK: - Initialization

    init(subsystem: String = "com.avocam.capture", category: String = "CaptureManager", config: CaptureConfig = .default) {
        self.subsystem = subsystem
        self.category = category
        self.config = config
        self.logger = OSLog(subsystem: subsystem, category: category)
    }

    // MARK: - Logging

    func log(_ level: Level, _ message: String) {
        guard config.enableSignposts else { return }

        switch level {
        case .info:
            os_log(.info, log: logger, "%{public}@", message)
        case .warning:
            os_log(.default, log: logger, "⚠️ %{public}@", message)
        case .error:
            os_log(.error, log: logger, "❌ %{public}@", message)
        case .debug:
            os_log(.debug, log: logger, "🔍 %{public}@", message)
        }
    }

    func info(_ message: String) {
        log(.info, message)
    }

    func warning(_ message: String) {
        log(.warning, message)
    }

    func error(_ message: String) {
        log(.error, message)
    }

    func debug(_ message: String) {
        log(.debug, message)
    }

    // MARK: - Signposts

    func signpostBegin(_ name: StaticString) {
        guard config.enableSignposts else { return }
        os_signpost(.begin, log: logger, name: name, signpostID: signpostID)
    }

    func signpostEnd(_ name: StaticString) {
        guard config.enableSignposts else { return }
        os_signpost(.end, log: logger, name: name, signpostID: signpostID)
    }

    // MARK: - Convenience Methods

    func logConfiguration(resolution: String, framerate: Int, position: String, lens: String) {
        info("📷 Configuring capture: \(resolution) @ \(framerate)fps, position: \(position), lens: \(lens)")
    }

    func logDeviceFound(_ device: AVCaptureDevice) {
        info("✅ Found camera device: \(device.localizedName)")
    }

    func logFormatConfigured(_ format: AVCaptureDevice.Format) {
        info("✅ Configured format: \(format.formatDescription)")
    }

    func logLensSwitch(from: String, to: String, via: String) {
        info("📷 Switching lens: \(from) → \(to) via \(via)")
    }

    func logZoomApplied(uiZoom: Double, deviceZoom: Double, lens: String) {
        info("✅ Applied zoom \(String(format: "%.1f", uiZoom))x UI (device: \(String(format: "%.1f", deviceZoom))x) for lens '\(lens)'")
    }

    func logExposure(isoMode: String, iso: Int, shutterMode: String, shutter: String) {
        info("✅ Exposure: ISO=\(isoMode)(\(iso)), Shutter=\(shutterMode)(\(shutter))")
    }

    func logWhiteBalance(kelvin: Int, tint: Double) {
        info("✅ WB locked to \(kelvin)K, tint \(String(format: "%.1f", tint))")
    }
}
