//
//  ThermalManager.swift
//  AvoCam
//
//  Monitors device thermal state and takes protective actions
//

import Foundation
import os

/// Callback for thermal events that require stream action
typealias ThermalActionCallback = (ThermalManager.ThermalAction) async -> Void

/// Manages thermal state monitoring and protective actions for streaming
final class ThermalManager: Sendable {
    // MARK: - Types

    enum ThermalAction: Equatable, Sendable {
        case none
        case warning(message: String)
        case stopStream(message: String)
        case recovered
    }

    enum ThermalLevel: String, CustomStringConvertible, Sendable {
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

    // MARK: - Thread-Safe State

    /// All mutable state grouped for lock-protected access
    private struct State: Sendable {
        var isStreaming = false
        var currentLevel: ThermalLevel = .nominal
        var warningIssued = false
        var criticalStopped = false
        var actionCallback: ThermalActionCallback?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    // MARK: - Initialization

    init() {}

    /// Set callback for thermal actions
    func setActionCallback(_ callback: @escaping ThermalActionCallback) {
        state.withLock { $0.actionCallback = callback }
    }

    // MARK: - Properties

    /// Whether streaming is currently active (must be set externally)
    var isStreaming: Bool {
        get { state.withLock { $0.isStreaming } }
        set { state.withLock { $0.isStreaming = newValue } }
    }

    /// Current thermal level
    var currentLevel: ThermalLevel {
        state.withLock { $0.currentLevel }
    }

    // MARK: - Monitoring

    /// Check thermal state and trigger appropriate actions
    /// Call this periodically (e.g., every second during telemetry collection)
    func checkThermalState(_ thermalState: ProcessInfo.ThermalState) {
        let newLevel = ThermalLevel(from: thermalState)

        let action: ThermalAction = state.withLock { s in
            s.currentLevel = newLevel

            // Only act if streaming
            guard s.isStreaming else {
                // Reset flags when not streaming
                s.warningIssued = false
                s.criticalStopped = false
                return .none
            }

            return Self.determineAction(
                newLevel: newLevel,
                state: &s
            )
        }

        if action != .none {
            let callback = state.withLock { $0.actionCallback }
            if let callback {
                Task { @MainActor in
                    await callback(action)
                }
            }
        }
    }

    /// Pure logic to determine what action to take based on thermal transition.
    /// Must be called inside `state.withLock`.
    private static func determineAction(
        newLevel: ThermalLevel,
        state: inout State
    ) -> ThermalAction {
        switch newLevel {
        case .serious:
            if !state.warningIssued {
                state.warningIssued = true
                Log.thermal.warning("Thermal throttle activated: device heating up")
                return .warning(message: "Device is heating up. Consider reducing quality or stopping stream.")
            }
            return .none

        case .critical:
            if !state.criticalStopped {
                state.criticalStopped = true
                Log.thermal.error("Thermal state CRITICAL: stopping stream to prevent damage")
                return .stopStream(message: "Stream stopped: device overheating. Please let it cool down.")
            }
            return .none

        case .nominal, .fair:
            if state.warningIssued || state.criticalStopped {
                state.warningIssued = false
                state.criticalStopped = false
                Log.thermal.info("Thermal state returned to normal")
                return .recovered
            }
            return .none
        }
    }

    // MARK: - Reset

    /// Reset thermal tracking state (e.g., when stream stops)
    func reset() {
        state.withLock { s in
            s.warningIssued = false
            s.criticalStopped = false
            s.isStreaming = false
        }
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
        let level = currentLevel
        return level == .serious || level == .critical
    }
}
