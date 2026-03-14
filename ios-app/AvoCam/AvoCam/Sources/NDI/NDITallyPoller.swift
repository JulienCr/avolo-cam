//
//  NDITallyPoller.swift
//  AvoCam
//
//  Polls NDI tally state and controls torch based on program/preview status
//

import Foundation
import Combine
import os.log

/// Polls NDI tally state at 10-20Hz and controls torch accordingly
/// - Program tally -> Torch ON at minimum level
/// - Preview tally -> UI badge only (no torch)
class NDITallyPoller {

    // MARK: - Properties

    private let ndiManager: NDIManager
    private let torchController = TorchController()
    private let pollingInterval: UInt64 = 50_000_000  // 50ms = 20Hz
    private let logger = Logger(subsystem: "com.avocam.tally", category: "NDITallyPoller")

    // External tally priority tracking timeout
    private let externalTallyTimeout: UInt64 = 5_000_000_000  // 5 seconds in nanoseconds

    // Task control
    private var pollingTask: Task<Void, Never>?

    /// Thread-safe lock protecting all mutable tally state.
    /// Protected fields: lastProgram, lastPreview, lastExternalTallyTime, currentTallyState
    private let tallyLock = OSAllocatedUnfairLock(uncheckedState: TallyState())

    // Published state for UI (optional)
    @Published private(set) var currentTallyState: (program: Bool, preview: Bool) = (false, false)

    // MARK: - State Container

    /// All mutable tally state bundled for lock protection.
    private struct TallyState {
        var lastProgram: Bool = false
        var lastPreview: Bool = false
        var lastExternalTallyTime: UInt64 = 0
        var currentTally: (program: Bool, preview: Bool) = (false, false)
    }

    // MARK: - Initialization

    init(ndiManager: NDIManager) {
        self.ndiManager = ndiManager
        logger.info("✅ NDI Tally Poller initialized")
    }

    // MARK: - Lifecycle

    /// Start polling NDI tally state
    func start() {
        guard pollingTask == nil else {
            logger.warning("Tally poller already running")
            return
        }

        logger.info("▶️ Starting tally poller (20Hz)")

        pollingTask = Task { [weak self] in
            guard let self = self else { return }

            while !Task.isCancelled {
                await self.pollTallyState()

                // Sleep for polling interval (50ms = 20Hz)
                try? await Task.sleep(nanoseconds: self.pollingInterval)
            }

            // Cleanup: ensure torch is off when polling stops
            await self.torchController.forceOff()
            self.logger.info("⏹ Tally poller stopped, torch forced off")
        }
    }

    /// Stop polling and turn off torch
    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        logger.info("⏹ Tally poller stop requested")
    }

    // MARK: - Private Methods

    /// Poll tally state and update torch/UI accordingly
    private func pollTallyState() async {
        // Skip NDI polling if external tally was received recently
        // This prevents NDI polling from overriding WebSocket tally in Flash mode
        let now = DispatchTime.now().uptimeNanoseconds
        let suppressed = tallyLock.withLock { state -> Bool in
            now - state.lastExternalTallyTime < externalTallyTimeout
        }
        if suppressed {
            return
        }

        // Get current tally state from NDI
        let tally = ndiManager.getTallyState()

        // Determine what changed under lock
        let changes = tallyLock.withLock { state -> (programChanged: Bool, previewChanged: Bool) in
            state.currentTally = tally
            let pc = tally.program != state.lastProgram
            let pvc = tally.preview != state.lastPreview
            if pc { state.lastProgram = tally.program }
            if pvc { state.lastPreview = tally.preview }
            return (pc, pvc)
        }

        // Update published state for UI observation (must happen outside lock)
        currentTallyState = tally

        // Handle program state change -> control torch
        if changes.programChanged {
            await torchController.set(programOn: tally.program)

            if tally.program {
                logger.info("🔴 Program tally ON → Torch ON")
            } else {
                logger.info("⚫️ Program tally OFF → Torch OFF")
            }
        }

        // Handle preview state change -> UI badge only
        if changes.previewChanged {
            if tally.preview {
                logger.debug("🟢 Preview tally ON")
            } else {
                logger.debug("⚫️ Preview tally OFF")
            }

            // TODO: Notify UI for preview badge update
            // Could use NotificationCenter or Combine publisher
        }
    }

    // MARK: - Public Accessors

    /// Get current tally state (for telemetry/status endpoints)
    func getCurrentState() -> (program: Bool, preview: Bool) {
        return tallyLock.withLock { $0.currentTally }
    }

    // MARK: - External Tally Control

    /// Set tally state from external source (e.g., OBS WebSocket)
    /// This allows OBS to control the torch directly without NDI polling
    /// - Parameters:
    ///   - program: Whether the camera is in Program (live) mode
    ///   - preview: Whether the camera is in Preview mode
    func setExternalTally(program: Bool, preview: Bool) async {
        // Determine what changed and update state under lock
        let changes = tallyLock.withLock { state -> (programChanged: Bool, previewChanged: Bool) in
            state.lastExternalTallyTime = DispatchTime.now().uptimeNanoseconds
            state.currentTally = (program: program, preview: preview)
            let pc = program != state.lastProgram
            let pvc = preview != state.lastPreview
            if pc { state.lastProgram = program }
            if pvc { state.lastPreview = preview }
            return (pc, pvc)
        }

        // Update published state for UI observation (must happen outside lock)
        currentTallyState = (program: program, preview: preview)

        // Only update torch if state changed
        if changes.programChanged {
            await torchController.set(programOn: program)

            if program {
                logger.info("🔴 External tally ON → Torch ON (NDI polling suppressed for 5s)")
            } else {
                logger.info("⚫️ External tally OFF → Torch OFF (NDI polling suppressed for 5s)")
            }
        }

        if changes.previewChanged {
            if preview {
                logger.debug("🟢 External preview tally ON")
            } else {
                logger.debug("⚫️ External preview tally OFF")
            }
        }
    }

    // MARK: - Torch Configuration

    /// Get current torch level
    func getTorchLevel() async -> Float {
        return await torchController.getTorchLevel()
    }

    /// Set torch level (0.01 - 1.0)
    func setTorchLevel(_ level: Float) async -> Bool {
        return await torchController.setTorchLevel(level)
    }

    /// Get device-specific default torch level
    func getDefaultTorchLevel() async -> Float {
        return await torchController.getDefaultTorchLevel()
    }

    /// Reset torch level to device default
    func resetTorchToDefault() async {
        await torchController.resetToDefault()
    }

    /// Get device model identifier
    func getDeviceModel() async -> String {
        return await torchController.getDeviceModel()
    }
}
