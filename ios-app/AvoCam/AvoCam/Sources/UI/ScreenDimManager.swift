//
//  ScreenDimManager.swift
//  AvoCam
//
//  Manages screen brightness during streaming to save battery
//

import UIKit
import SwiftUI
import Combine

@MainActor
class ScreenDimManager: ObservableObject {
    @Published var isScreenAwake: Bool = true

    private var originalBrightness: CGFloat = 1.0
    private var dimTimer: Timer?
    private let autoDimDelay: TimeInterval = 5.0 // Seconds before auto-dim

    // MARK: - Brightness Control

    func startStreaming() {
        // Save original brightness
        originalBrightness = UIScreen.main.brightness

        // Dim screen immediately when streaming starts
        dimScreen()
        print("💡 Screen dimmed for streaming (original: \(String(format: "%.2f", originalBrightness)))")
    }

    func stopStreaming() {
        // Restore original brightness
        restoreBrightness()

        // Cancel any pending dim timer
        dimTimer?.invalidate()
        dimTimer = nil

        isScreenAwake = true
        print("💡 Screen brightness restored to \(String(format: "%.2f", originalBrightness))")
    }

    func wakeScreen() {
        guard !isScreenAwake else { return }

        // Wake up screen to original brightness
        restoreBrightness()
        isScreenAwake = true
        print("💡 Screen woken (tap detected)")

        // Schedule auto-dim
        scheduleAutoDim()
    }

    // MARK: - Private Methods

    private func dimScreen() {
        UIScreen.main.brightness = 0.01 // Minimum brightness (not completely off to keep system responsive)
        isScreenAwake = false
    }

    private func restoreBrightness() {
        UIScreen.main.brightness = originalBrightness
    }

    private func scheduleAutoDim() {
        // Cancel existing timer
        dimTimer?.invalidate()

        // Schedule new auto-dim
        dimTimer = Timer.scheduledTimer(withTimeInterval: autoDimDelay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.dimScreen()
                print("💡 Screen auto-dimmed after \(self.autoDimDelay)s inactivity")
            }
        }
    }
}
