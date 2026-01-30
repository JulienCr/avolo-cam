//
//  ServiceContainer.swift
//  AvoCam
//
//  Dependency injection container for app services
//

import Foundation
import AVFoundation

/// Central container for all app services and their dependencies
@MainActor
final class ServiceContainer {
    // MARK: - Singleton

    static let shared = ServiceContainer()

    // MARK: - Configuration

    let configuration: AppConfiguration

    // MARK: - Core Services

    let captureManager: CaptureManager
    let ndiManager: NDIManager
    let telemetryCollector: TelemetryCollector

    // MARK: - Coordinators

    private(set) var streamingCoordinator: StreamingCoordinator!
    private(set) var telemetryAggregator: TelemetryAggregator!
    private(set) var thermalManager: ThermalManager!

    // MARK: - Network

    private(set) var networkServer: NetworkServer!
    private(set) var bonjourService: BonjourService!

    // MARK: - NDI Utilities

    private(set) var tallyPoller: NDITallyPoller!

    // MARK: - Initialization

    private init() {
        // Load configuration
        configuration = AppConfiguration.load()

        // Create core services
        captureManager = CaptureManager()
        ndiManager = NDIManager(alias: configuration.cameraAlias)
        telemetryCollector = TelemetryCollector()

        // Initialize other components
        setupComponents()
    }

    private func setupComponents() {
        // Create streaming coordinator
        streamingCoordinator = StreamingCoordinator(
            captureManager: captureManager,
            ndiManager: ndiManager
        )

        // Create tally poller (depends on ndiManager)
        tallyPoller = NDITallyPoller(ndiManager: ndiManager)

        // Wire tally poller into streaming coordinator
        Task {
            await streamingCoordinator.setTallyPoller(tallyPoller)
        }

        // Create telemetry aggregator
        telemetryAggregator = TelemetryAggregator(telemetryCollector: telemetryCollector)
        Task {
            await telemetryAggregator.setStreamingCoordinator(streamingCoordinator)
        }

        // Create thermal manager
        thermalManager = ThermalManager()

        // Create network services
        networkServer = NetworkServer(
            port: configuration.serverPort,
            bearerToken: configuration.bearerToken,
            requestHandler: nil  // Will be set when AppCoordinator initializes
        )
        networkServer.setAuthenticationEnabled(configuration.isAuthenticationEnabled)

        bonjourService = BonjourService(
            alias: configuration.cameraAlias,
            port: configuration.serverPort,
            bearerToken: configuration.bearerToken
        )
    }

    // MARK: - Service Accessors (Protocol-typed)

    var streaming: StreamingService {
        return streamingCoordinator
    }

    var telemetry: TelemetryProvider {
        return telemetryAggregator
    }

    // MARK: - Lifecycle

    func start() {
        bonjourService.start()

        do {
            try networkServer.start()
        } catch {
            print("❌ Failed to start network server: \(error)")
        }
    }

    func stop() {
        // Stop telemetry collection
        Task {
            await telemetryAggregator.stopCollection()
        }

        // Stop streaming if active
        Task {
            await streamingCoordinator.stopStreaming()
        }

        // Stop network services
        tallyPoller.stop()
        bonjourService.stop()
        networkServer.stop()
    }

    // MARK: - Configuration Updates

    /// Update camera alias (requires NDI restart)
    func updateAlias(_ newAlias: String) async throws {
        // Stop streaming if active
        let wasStreaming = await streamingCoordinator.isStreaming
        if wasStreaming {
            await streamingCoordinator.stopStreaming()
        }

        // Update configuration
        var newConfig = configuration.withAlias(newAlias)
        newConfig.save()

        // Recreate NDI manager with new alias
        let newNDIManager = NDIManager(alias: newAlias)
        // Note: This requires recreating streamingCoordinator too
        // For now, this is a simplified version - full implementation would
        // need to update all dependent services

        // Restart Bonjour with new alias
        bonjourService.stop()
        bonjourService = BonjourService(
            alias: newAlias,
            port: configuration.serverPort,
            bearerToken: configuration.bearerToken
        )
        bonjourService.start()

        print("✅ Camera alias updated to: \(newAlias)")
    }
}
