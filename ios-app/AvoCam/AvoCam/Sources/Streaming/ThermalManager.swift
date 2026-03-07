//
//  ThermalManager.swift
//  AvoCam
//
//  Monitors device thermal state and takes protective actions
//

import Foundation

/// Callback for thermal events that require stream action
typealias ThermalActionCallback = (ThermalManager.ThermalAction) async -> Void

/// Manages thermal state monitoring and protective actions for streaming
actor ThermalManager {
    // MARK: - Types

    enum ThermalAction: Equatable {
        case none
        case warning(message: String)
        case stopStream(message: String)
        case recovered
    }

    enum ThermalLevel: String, CustomStringConvertible {
        case nominal
        case fair
        case serious
        case critical

        var description: String { rawValue }

        init(from state: ProcessInfo.ThermalState) {
            switch state {
            case .nominal: self = .nominal
            case .fair: self = .fair
            case .serious: self = .serious
            case .critical: self = .critical
            @unknown default: self = .nominal
            }
        }
    }

    // MARK: - Properties

    private(set) var currentLevel: ThermalLevel = .nominal
    private var warningIssued = false
    private var criticalStopped = false
    private var actionCallback: ThermalActionCallback?

    /// Whether streaming is currently active (must be set externally)
    private var isStreaming: Bool = false

    /// Set streaming state from external callers
    func setIsStreaming(_ value: Bool) {
        isStreaming = value
    }

    // MARK: - Initialization

    init() {}

    /// Set callback for thermal actions
    func setActionCallback(_ callback: @escaping ThermalActionCallback) {
        self.actionCallback = callback
    }

    // MARK: - Monitoring

    /// Check thermal state and trigger appropriate actions
    /// Call this periodically (e.g., every second during telemetry collection)
    func checkThermalState(_ state: ProcessInfo.ThermalState) {
        let newLevel = ThermalLevel(from: state)
        let previousLevel = currentLevel
        currentLevel = newLevel

        // Only act if streaming
        guard isStreaming else {
            // Reset flags when not streaming
            if !isStreaming {
                warningIssued = false
                criticalStopped = false
            }
            return
        }

        let action = determineAction(newLevel: newLevel, previousLevel: previousLevel)

        if action != .none {
            Task { @MainActor in
                await self.actionCallback?(action)
            }
        }
    }

    private func determineAction(newLevel: ThermalLevel, previousLevel: ThermalLevel) -> ThermalAction {
        switch newLevel {
        case .serious:
            if !warningIssued {
                warningIssued = true
                print("⚠️ Thermal throttle activated: device heating up")
                return .warning(message: "Device is heating up. Consider reducing quality or stopping stream.")
            }
            return .none

        case .critical:
            if !criticalStopped {
                criticalStopped = true
                print("🔥 Thermal state CRITICAL: stopping stream to prevent damage")
                return .stopStream(message: "Stream stopped: device overheating. Please let it cool down.")
            }
            return .none

        case .nominal, .fair:
            if warningIssued || criticalStopped {
                warningIssued = false
                criticalStopped = false
                print("✅ Thermal state returned to normal")
                return .recovered
            }
            return .none
        }
    }

    // MARK: - Reset

    /// Reset thermal tracking state (e.g., when stream stops)
    func reset() {
        warningIssued = false
        criticalStopped = false
        isStreaming = false
    }

    // MARK: - Status

    /// Get human-readable thermal status
    var statusDescription: String {
        switch currentLevel {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot - Consider reducing quality"
        case .critical: return "Critical - Stream stopped"
        }
    }

    /// Whether device is in a concerning thermal state
    var isOverheating: Bool {
        return currentLevel == .serious || currentLevel == .critical
    }
}
