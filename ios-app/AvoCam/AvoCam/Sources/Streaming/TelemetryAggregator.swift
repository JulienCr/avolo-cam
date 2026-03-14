//
//  TelemetryAggregator.swift
//  AvoCam
//
//  Aggregates telemetry from multiple sources
//

import Foundation
import Combine

/// Aggregates telemetry from system metrics, NDI stats, and streaming state
actor TelemetryAggregator: TelemetryProvider {
    // MARK: - Dependencies

    private let telemetryCollector: TelemetryCollector
    private weak var streamingCoordinator: StreamingCoordinator?
    private let thermalManager: ThermalManager?

    // MARK: - State

    private var currentTelemetry: Telemetry?
    private var updateTask: Task<Void, Never>?
    private var onTelemetryUpdate: ((Telemetry, NDIState) -> Void)?

    // MARK: - Initialization

    init(telemetryCollector: TelemetryCollector, thermalManager: ThermalManager? = nil) {
        self.telemetryCollector = telemetryCollector
        self.thermalManager = thermalManager
    }

    func setStreamingCoordinator(_ coordinator: StreamingCoordinator) {
        self.streamingCoordinator = coordinator
    }

    // MARK: - TelemetryProvider Protocol

    nonisolated func getCurrentTelemetry() async -> Telemetry {
        return await _getCurrentTelemetry()
    }

    private func _getCurrentTelemetry() async -> Telemetry {
        return currentTelemetry ?? Telemetry.makeDefault()
    }

    // MARK: - Lifecycle

    /// Start periodic telemetry collection
    func startCollection(interval: TimeInterval = 1.0, onUpdate: @escaping @MainActor (Telemetry, NDIState) -> Void) {
        self.onTelemetryUpdate = onUpdate

        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }

                await self.collectAndBroadcast()

                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// Stop telemetry collection
    func stopCollection() {
        updateTask?.cancel()
        updateTask = nil
        onTelemetryUpdate = nil
    }

    // MARK: - Collection

    private func collectAndBroadcast() async {
        let telemetry = await collectTelemetry()
        currentTelemetry = telemetry

        let isStreaming = await streamingCoordinator?.isCurrentlyStreaming ?? false
        let ndiState: NDIState = isStreaming ? .streaming : .idle

        // Update thermal manager streaming state
        thermalManager?.isStreaming = isStreaming

        // Invoke callback on main actor for UI updates
        if let callback = onTelemetryUpdate {
            await callback(telemetry, ndiState)
        }
    }

    private func collectTelemetry() async -> Telemetry {
        // Collect system telemetry
        let systemTelemetry = await telemetryCollector.collect()

        // Update thermal manager with current thermal state
        thermalManager?.checkThermalState(systemTelemetry.thermalState)

        // Get NDI stats if streaming
        let ndiStats: (fps: Double, sentFrames: Int64, droppedFrames: Int64)
        if let coordinator = streamingCoordinator {
            ndiStats = await coordinator.getTelemetryStats()
        } else {
            ndiStats = (fps: 0.0, sentFrames: 0, droppedFrames: 0)
        }

        return Telemetry(
            fps: ndiStats.fps,
            bitrate: systemTelemetry.networkBitrate,
            battery: systemTelemetry.battery,
            tempC: systemTelemetry.temperature,
            wifiRssi: systemTelemetry.wifiRssi,
            cpuUsage: systemTelemetry.cpuUsage,
            queueMs: nil,  // Not available from NDI SDK
            droppedFrames: Int(ndiStats.droppedFrames),
            chargingState: systemTelemetry.chargingState
        )
    }

}
