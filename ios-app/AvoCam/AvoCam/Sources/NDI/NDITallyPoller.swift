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
/// - Program tally → Torch ON at minimum level
/// - Preview tally → UI badge only (no torch)
class NDITallyPoller {

    // MARK: - Properties

    private let ndiManager: NDIManager
    private let torchController = TorchController()
    private let pollingInterval: UInt64 = 50_000_000  // 50ms = 20Hz
    private let logger = Logger(subsystem: "com.avocam.tally", category: "NDITallyPoller")

    // Tally state tracking
    private var lastProgram: Bool = false
    private var lastPreview: Bool = false

    // Task control
    private var pollingTask: Task<Void, Never>?

    // Published state for UI (optional)
    @Published private(set) var currentTallyState: (program: Bool, preview: Bool) = (false, false)

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
        // Get current tally state from NDI
        let tally = ndiManager.getTallyState()

        // Update published state for UI observation
        currentTallyState = tally

        // Handle program state change → control torch
        if tally.program != lastProgram {
            lastProgram = tally.program
            await torchController.set(programOn: tally.program)

            if tally.program {
                logger.info("🔴 Program tally ON → Torch ON")
            } else {
                logger.info("⚫️ Program tally OFF → Torch OFF")
            }
        }

        // Handle preview state change → UI badge only
        if tally.preview != lastPreview {
            lastPreview = tally.preview

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
        return currentTallyState
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
