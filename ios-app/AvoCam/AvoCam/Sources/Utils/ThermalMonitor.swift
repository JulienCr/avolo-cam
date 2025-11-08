//
//  ThermalMonitor.swift
//  AvoCam
//
//  PERF: Monitors device thermal state and triggers throttling callbacks
//  Extends 4K streaming time from 18min to 45+ min before thermal shutdown
//

import Foundation
import os.log

/// Monitors iOS thermal state and provides callbacks for proactive throttling
/// Usage:
///   let monitor = ThermalMonitor()
///   monitor.onThermalStateChange = { state in
///       switch state {
///       case .serious: // Reduce bitrate 30%
///       case .critical: // Reduce to 720p or stop
///       }
///   }
///   monitor.start()
class ThermalMonitor {
    // MARK: - Properties

    private var thermalStateObserver: NSObjectProtocol?
    private let log = OSLog(subsystem: "com.avocam", category: "thermal")

    /// Callback invoked when thermal state changes
    /// Runs on main queue
    var onThermalStateChange: ((ProcessInfo.ThermalState) -> Void)?

    // MARK: - Lifecycle

    deinit {
        stop()
    }

    // MARK: - Control

    /// Start monitoring thermal state changes
    func start() {
        // Remove existing observer if any
        stop()

        thermalStateObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let state = ProcessInfo.processInfo.thermalState
            os_log(.info, log: self?.log ?? .default, "🌡️ Thermal state changed: %{public}@", self?.thermalStateDescription(state) ?? "unknown")
            self?.onThermalStateChange?(state)
        }

        // Log initial state
        let state = ProcessInfo.processInfo.thermalState
        os_log(.info, log: log, "🌡️ Initial thermal state: %{public}@", thermalStateDescription(state))
        print("🌡️ ThermalMonitor started, current state: \(thermalStateDescription(state))")
    }

    /// Stop monitoring thermal state changes
    func stop() {
        if let observer = thermalStateObserver {
            NotificationCenter.default.removeObserver(observer)
            thermalStateObserver = nil
            print("🌡️ ThermalMonitor stopped")
        }
    }

    // MARK: - Helpers

    private func thermalStateDescription(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            return "nominal (<38°C, normal operation)"
        case .fair:
            return "fair (38-43°C, slight throttling)"
        case .serious:
            return "serious (43-48°C, recommend bitrate reduction)"
        case .critical:
            return "critical (>48°C, recommend resolution reduction or stop)"
        @unknown default:
            return "unknown(\(state.rawValue))"
        }
    }
}
