//
//  AppCoordinator.swift
//  AvoCam
//
//  UI coordinator - manages published state and orchestrates services
//

import Foundation
import Combine
import UIKit
import AVFoundation

@MainActor
class AppCoordinator: ObservableObject {
    // MARK: - Published State (for SwiftUI binding)

    @Published var isStreaming: Bool = false
    @Published var currentSettings: CurrentSettings?
    @Published var telemetry: Telemetry?
    @Published var error: String?
    @Published var captureSession: AVCaptureSession?
    @Published var isScreenDimmed: Bool = false
    @Published var localIPAddress: String?
    @Published var bearerTokenForDisplay: String = ""
    @Published var isAuthenticationEnabled: Bool = false

    // Cached Flash UDP port for telemetry broadcast (updated when streaming starts/stops)
    private var cachedFlashUdpPort: Int? = nil

    // MARK: - Configuration & Services

    private var configuration: AppConfiguration

    // Core components
    private let captureManager: CaptureManager
    private let ndiManager: NDIManager
    private let srtManager: SRTManager
    private let flashManager: FlashManager
    private var networkServer: NetworkServer  // var to allow re-initialization with self
    private let bonjourService: BonjourService
    private let tallyPoller: NDITallyPoller

    // Modular services
    private let streamingCoordinator: StreamingCoordinator
    private let telemetryAggregator: TelemetryAggregator
    private let thermalManager: ThermalManager

    // MARK: - Initialization

    init() {
        // Load configuration
        self.configuration = AppConfiguration.load()

        // Initialize core components (order matters for initialization)
        self.captureManager = CaptureManager()
        self.ndiManager = NDIManager(alias: configuration.cameraAlias)
        self.srtManager = SRTManager()
        self.flashManager = FlashManager()
        self.tallyPoller = NDITallyPoller(ndiManager: ndiManager)
        self.bonjourService = BonjourService(
            alias: configuration.cameraAlias,
            port: configuration.serverPort,
            bearerToken: configuration.bearerToken
        )

        // Initialize modular services
        self.thermalManager = ThermalManager()
        self.streamingCoordinator = StreamingCoordinator(
            captureManager: captureManager,
            ndiManager: ndiManager,
            srtManager: srtManager,
            flashManager: flashManager
        )
        self.telemetryAggregator = TelemetryAggregator(
            telemetryCollector: TelemetryCollector(),
            thermalManager: thermalManager
        )

        // Initialize network server last (after all other properties) so we can pass self
        self.networkServer = NetworkServer(
            port: configuration.serverPort,
            bearerToken: configuration.bearerToken,
            requestHandler: nil  // Temporarily nil
        )

        // Set display properties
        self.bearerTokenForDisplay = configuration.bearerToken
        self.isAuthenticationEnabled = configuration.isAuthenticationEnabled

        // Load persisted settings
        self.currentSettings = loadPersistedSettings()

        // Now recreate NetworkServer with self as handler (after all properties initialized)
        self.networkServer = NetworkServer(
            port: configuration.serverPort,
            bearerToken: configuration.bearerToken,
            requestHandler: self
        )

        // Wire up service dependencies
        Task {
            await streamingCoordinator.setTallyPoller(tallyPoller)
            await telemetryAggregator.setStreamingCoordinator(streamingCoordinator)
        }
    }

    // MARK: - Lifecycle

    func start() {
        print("🚀 Starting AvoCam with alias: \(configuration.cameraAlias)")
        print("🔑 Bearer Token: \(configuration.bearerToken)")

        // Log torch level at startup
        Task {
            let torchLevel = await tallyPoller.getTorchLevel()
            let defaultLevel = await tallyPoller.getDefaultTorchLevel()
            let deviceModel = await tallyPoller.getDeviceModel()
            print("🔦 Torch level: \(torchLevel) (default: \(defaultLevel) for \(deviceModel))")
        }

        // Detect local IP address
        detectLocalIPAddress()

        // Start network services
        networkServer.setAuthenticationEnabled(configuration.isAuthenticationEnabled)

        // Connect tally callback for OBS WebSocket control
        networkServer.onTallyUpdate = { [weak self] program, _ in
            await self?.tallyPoller.setExternalTally(program: program)
        }

        do {
            try networkServer.start()
            print("✅ Network server started on port \(configuration.serverPort)")
            print("🔐 Authentication: \(configuration.isAuthenticationEnabled ? "enabled" : "disabled")")
        } catch {
            self.error = "Failed to start network server: \(error.localizedDescription)"
            print("❌ Failed to start network server: \(error)")
        }

        bonjourService.start()
        print("✅ Bonjour service started: _avolocam._tcp.local")

        // Disable idle timer during app lifetime
        UIApplication.shared.isIdleTimerDisabled = true

        // Setup telemetry and thermal monitoring
        setupTelemetryBroadcasting()
        setupThermalMonitoring()

        // Initialize preview session early
        Task {
            await initializePreviewSession()
        }
    }

    func stop() {
        print("🛑 Stopping AvoCam")

        // Stop streaming if active
        if isStreaming {
            Task {
                await stopStreaming()
            }
        }

        // Stop preview session
        Task {
            await stopPreviewSession()
        }

        // Stop all services
        Task {
            await telemetryAggregator.stopCollection()
        }
        tallyPoller.stop()
        bonjourService.stop()
        networkServer.stop()

        // Re-enable idle timer
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Telemetry Setup

    private func setupTelemetryBroadcasting() {
        Task {
            await telemetryAggregator.startCollection { [weak self] telemetry, ndiState in
                guard let self = self else { return }
                self.telemetry = telemetry

                // Use cached Flash UDP port (updated when streaming starts/stops)
                let flashPort = self.cachedFlashUdpPort

                self.networkServer.broadcastTelemetry(telemetry, ndiState: ndiState, flashUdpPort: flashPort)
            }
        }
    }

    private func setupThermalMonitoring() {
        thermalManager.setActionCallback { [weak self] action in
            guard let self = self else { return }
            switch action {
            case .stopStream(let message):
                await self.stopStreaming()
                self.error = message
            case .warning(let message):
                print("⚠️ Thermal warning: \(message)")
            case .recovered:
                print("✅ Thermal state recovered")
            case .none:
                break
            }
        }
    }

    // MARK: - Network Detection

    private func detectLocalIPAddress() {
        var address: String?

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else {
            print("⚠️ Failed to get network interfaces")
            return
        }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }

            guard let interface = ptr else { continue }
            let addrFamily = interface.pointee.ifa_addr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) || addrFamily == UInt8(AF_INET6) {
                let name = String(cString: interface.pointee.ifa_name)

                if name == "en0" || name == "en1" || name.hasPrefix("en") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))

                    if getnameinfo(
                        interface.pointee.ifa_addr,
                        socklen_t(interface.pointee.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        socklen_t(0),
                        NI_NUMERICHOST
                    ) == 0 {
                        address = String(cString: hostname)
                        if addrFamily == UInt8(AF_INET) {
                            break
                        }
                    }
                }
            }
        }

        self.localIPAddress = address
        if let ip = address {
            print("📡 Local IP Address: \(ip)")
        } else {
            print("⚠️ Could not determine local IP address")
        }
    }

    // MARK: - Preview Session

    private func initializePreviewSession() async {
        do {
            try await captureManager.configure(
                resolution: "1920x1080",
                framerate: 25
            )

            if let session = captureManager.getSession() {
                self.captureSession = session

                if !session.isRunning {
                    await Task.detached {
                        session.startRunning()
                    }.value
                }

                print("✅ Preview session initialized and running")
            }
        } catch {
            print("⚠️ Failed to initialize preview session: \(error)")
        }
    }

    private func stopPreviewSession() async {
        captureSession?.stopRunning()
        captureSession = nil
        print("⏹ Preview session stopped")
    }

    func pausePreview() async {
        guard !isStreaming else {
            print("⏸ App backgrounded but continuing capture for active stream")
            return
        }

        captureSession?.stopRunning()
        print("⏸ Preview paused (app in background)")
    }

    func resumePreview() async {
        if let session = captureSession, !session.isRunning {
            session.startRunning()
            print("▶️ Preview resumed (app in foreground)")
        }
    }

    // MARK: - Authentication Control

    func toggleAuthentication() {
        configuration = configuration.withAuthenticationToggled()
        isAuthenticationEnabled = configuration.isAuthenticationEnabled
        networkServer.setAuthenticationEnabled(configuration.isAuthenticationEnabled)
        print("🔐 Authentication \(configuration.isAuthenticationEnabled ? "enabled" : "disabled")")
    }

    // MARK: - Screen Brightness Control

    func toggleScreenBrightness() {
        setScreenBrightness(dimmed: !isScreenDimmed)
    }

    func setScreenBrightness(dimmed: Bool) {
        isScreenDimmed = dimmed

        if dimmed {
            UIScreen.main.brightness = 0.01
            print("🔅 Screen dimmed to save battery")
        } else {
            UIScreen.main.brightness = 0.5
            print("🔆 Screen brightness restored")
        }
    }

    // MARK: - Streaming Control (delegate to coordinator)

    func startStreaming(request: StreamStartRequest) async throws {
        guard !isStreaming else {
            throw AVOCamError.alreadyStreaming
        }

        try await streamingCoordinator.startStreaming(request: request)
        isStreaming = true
        updateCurrentSettings(from: request)

        // If Flash mode, update Bonjour with UDP port and setup frame info callback
        if request.streamingMode == .flash {
            let flashPort = await flashManager.activeUdpPort
            bonjourService.updateFlashPort(flashPort)

            // Cache the Flash UDP port for telemetry broadcast
            cachedFlashUdpPort = flashPort > 0 ? Int(flashPort) : nil

            // Setup WebSocket callback for frame timing correlation
            await flashManager.setFrameInfoCallback { [weak networkServer] frameInfo in
                networkServer?.broadcastFrameInfo(frameInfo)
            }
        } else {
            // Not Flash mode, clear cached port
            cachedFlashUdpPort = nil
        }
    }

    func stopStreaming() async {
        guard isStreaming else { return }

        // If Flash mode was active, clear Bonjour Flash port and cached port
        if currentSettings?.streamingMode == .flash {
            bonjourService.updateFlashPort(0)
            cachedFlashUdpPort = nil
        }

        await streamingCoordinator.stopStreaming()
        isStreaming = false
        thermalManager.reset()
    }

    // MARK: - Camera Control

    func updateCameraSettings(_ settings: CameraSettingsRequest) async throws {
        try await captureManager.updateSettings(settings)

        var current = currentSettings ?? createDefaultSettings()

        if let wbMode = settings.wbMode { current.wbMode = wbMode }
        if let wbKelvin = settings.wbKelvin { current.wbKelvin = wbKelvin }
        if let wbTint = settings.wbTint { current.wbTint = wbTint }
        if let isoMode = settings.isoMode { current.isoMode = isoMode }
        if let iso = settings.iso { current.iso = iso }
        if let shutterMode = settings.shutterMode { current.shutterMode = shutterMode }
        if let shutterS = settings.shutterS { current.shutterS = shutterS }
        if let focusMode = settings.focusMode { current.focusMode = focusMode }
        if let focusDistance = settings.focusDistance { current.focusDistance = focusDistance }
        if let zoomFactor = settings.zoomFactor { current.zoomFactor = zoomFactor }
        if let cameraPosition = settings.cameraPosition { current.cameraPosition = cameraPosition }
        if let lens = settings.lens { current.lens = lens }

        currentSettings = current
        persistSettings(current)

        if let torchLevel = settings.torchLevel {
            _ = await tallyPoller.setTorchLevel(torchLevel)
        }
    }

    // MARK: - Capabilities & Status

    func getCapabilities() async -> [Capability] {
        return await captureManager.getCapabilities()
    }

    func getStatus() async -> StatusResponse {
        let tallyState = isStreaming ? tallyPoller.getCurrentState() : nil

        var settings = currentSettings ?? createDefaultSettings()
        let focusState = await captureManager.getCurrentFocusState()
        settings.focusMode = focusState.mode
        settings.focusDistance = focusState.distance

        // Build SRT connection URL if in SRT mode
        let srtConnectionUrl: String? = {
            if settings.streamingMode == .srt, let ip = localIPAddress, let port = settings.srtPort {
                return "srt://\(ip):\(port)?mode=caller"
            }
            return nil
        }()

        // Get Flash UDP port if in Flash mode
        let flashUdpPort: Int?
        if settings.streamingMode == .flash, isStreaming {
            flashUdpPort = Int(await flashManager.activeUdpPort)
        } else {
            flashUdpPort = nil
        }

        return StatusResponse(
            alias: configuration.cameraAlias,
            ndiState: isStreaming ? .streaming : .idle,
            current: settings,
            telemetry: telemetry ?? createDefaultTelemetry(),
            capabilities: await getCapabilities(),
            tallyProgram: tallyState?.program,
            tallyPreview: tallyState?.preview,
            streamingMode: settings.streamingMode,
            srtConnectionUrl: srtConnectionUrl,
            srtPort: settings.srtPort,
            flashUdpPort: flashUdpPort
        )
    }

    // MARK: - Alias Management

    func updateAlias(_ newAlias: String) async throws -> (alias: String, requiresRestart: Bool) {
        let wasStreaming = isStreaming

        if wasStreaming {
            await stopStreaming()
        }

        bonjourService.stop()

        // Update configuration
        configuration = configuration.withAlias(newAlias)
        print("✅ Camera alias updated to: \(newAlias)")

        // Note: This requires restarting network services with new NDIManager
        // For now, return requiresRestart = true to signal app restart needed
        return (alias: newAlias, requiresRestart: true)
    }

    // MARK: - Settings Persistence

    private func loadPersistedSettings() -> CurrentSettings? {
        guard let data = UserDefaults.standard.data(forKey: "camera_settings"),
              let settings = try? JSONDecoder().decode(CurrentSettings.self, from: data) else {
            return createDefaultSettings()
        }
        print("📥 Loaded persisted camera settings: WB=\(settings.wbMode), Kelvin=\(settings.wbKelvin ?? 0)K, ISO=\(settings.iso), Zoom=\(settings.zoomFactor)x")
        return settings
    }

    private func persistSettings(_ settings: CurrentSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "camera_settings")
            let uiZoom = settings.zoomFactor / 2.0
            print("💾 Persisted camera settings: WB=\(settings.wbMode), Kelvin=\(settings.wbKelvin ?? 0)K, ISO=\(settings.iso), Zoom=\(String(format: "%.1f", uiZoom))x UI (device: \(String(format: "%.1f", settings.zoomFactor))x)")
        }
    }

    // MARK: - Helpers

    private func updateCurrentSettings(from request: StreamStartRequest) {
        let videoSettings = VideoSettingsManager.load()
        if var current = currentSettings {
            current.resolution = request.resolution
            current.fps = request.framerate
            current.bitrate = request.bitrate
            current.codec = request.codec
            current.streamingMode = request.streamingMode ?? videoSettings.streamingMode
            current.srtPort = request.srtPort ?? videoSettings.srtPort
            current.srtLatency = request.srtLatency ?? videoSettings.srtLatency
            currentSettings = current
            persistSettings(current)
        } else {
            let newSettings = CurrentSettings(
                resolution: request.resolution,
                fps: request.framerate,
                bitrate: request.bitrate,
                codec: request.codec,
                wbMode: .auto,
                wbKelvin: nil,
                wbTint: nil,
                isoMode: .auto,
                iso: 0,
                shutterMode: .auto,
                shutterS: 0.0,
                focusMode: .auto,
                focusDistance: nil,
                zoomFactor: 1.0,
                cameraPosition: "back",
                lens: "wide",
                streamingMode: request.streamingMode ?? videoSettings.streamingMode,
                srtPort: request.srtPort ?? videoSettings.srtPort,
                srtLatency: request.srtLatency ?? videoSettings.srtLatency
            )
            currentSettings = newSettings
            persistSettings(newSettings)
        }
    }

    private func createDefaultSettings() -> CurrentSettings {
        let videoSettings = VideoSettingsManager.load()
        return CurrentSettings(
            resolution: "1920x1080",
            fps: 25,
            bitrate: 10000000,
            codec: "h264",
            wbMode: .auto,
            wbKelvin: nil,
            wbTint: nil,
            isoMode: .auto,
            iso: 0,
            shutterMode: .auto,
            shutterS: 0.0,
            focusMode: .auto,
            focusDistance: nil,
            zoomFactor: 1.0,
            cameraPosition: "back",
            lens: "wide",
            streamingMode: videoSettings.streamingMode,
            srtPort: videoSettings.srtPort,
            srtLatency: videoSettings.srtLatency
        )
    }

    private func createDefaultTelemetry() -> Telemetry {
        return Telemetry(
            fps: 0,
            bitrate: 0,
            battery: 1.0,
            tempC: 25.0,
            wifiRssi: -50,
            cpuUsage: 0,
            queueMs: nil,
            droppedFrames: nil,
            chargingState: nil
        )
    }
}

// MARK: - NetworkRequestHandler Extension

extension AppCoordinator: NetworkRequestHandler {
    func handleStreamStart(_ request: StreamStartRequest) async throws {
        try await startStreaming(request: request)
    }

    func handleStreamStop() async throws {
        await stopStreaming()
    }

    func handleCameraSettings(_ settings: CameraSettingsRequest) async throws {
        try await updateCameraSettings(settings)
    }

    func handleGetStatus() async -> StatusResponse {
        return await getStatus()
    }

    func handleGetCapabilities() async -> [Capability] {
        return await getCapabilities()
    }

    func handleGetVideoSettings() async -> VideoSettingsResponse {
        let settings = VideoSettingsManager.load()
        let presets = VideoPreset.allPresets.map { preset in
            VideoPresetResponse(
                id: preset.id,
                name: preset.name,
                resolution: preset.resolution,
                fps: preset.fps,
                codec: preset.codec.rawValue,
                bitrate: preset.bitrate
            )
        }

        return VideoSettingsResponse(
            selectedPresetId: settings.selectedPresetId,
            customResolution: settings.customResolution,
            customFps: settings.customFps,
            customCodec: settings.customCodec?.rawValue,
            customBitrate: settings.customBitrate,
            availablePresets: presets
        )
    }

    func handleUpdateVideoSettings(_ request: VideoSettingsUpdateRequest) async throws {
        var settings = VideoSettingsManager.load()

        settings.selectedPresetId = request.selectedPresetId
        settings.customResolution = request.customResolution
        settings.customFps = request.customFps
        if let codecStr = request.customCodec {
            settings.customCodec = VideoCodec(rawValue: codecStr)
        }
        settings.customBitrate = request.customBitrate

        VideoSettingsManager.save(settings)

        print("✅ Video settings updated and saved")
    }

    func handleScreenBrightness(_ request: ScreenBrightnessRequest) {
        setScreenBrightness(dimmed: request.dimmed)
    }

    func handleMeasureWhiteBalance() async throws -> WhiteBalanceMeasureResponse {
        let result = try await captureManager.measureWhiteBalance()
        return WhiteBalanceMeasureResponse(sceneCCT_K: result.sceneCCT_K, tint: result.tint)
    }

    func handleUpdateAlias(_ request: AliasUpdateRequest) async throws -> AliasUpdateResponse {
        let result = try await updateAlias(request.alias)
        return AliasUpdateResponse(alias: result.alias, requiresRestart: result.requiresRestart)
    }

    func handleGetTorchLevel() async -> TorchLevelResponse {
        let currentLevel = await tallyPoller.getTorchLevel()
        let defaultLevel = await tallyPoller.getDefaultTorchLevel()
        let deviceModel = await tallyPoller.getDeviceModel()

        return TorchLevelResponse(
            currentLevel: currentLevel,
            defaultLevel: defaultLevel,
            deviceModel: deviceModel
        )
    }

    func handleUpdateTorchLevel(_ request: TorchLevelUpdateRequest) async throws -> TorchLevelResponse {
        if let level = request.level {
            let success = await tallyPoller.setTorchLevel(level)
            if !success {
                throw NSError(domain: "com.avocam", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid torch level (must be 0.01-1.0)"])
            }
        } else {
            await tallyPoller.resetTorchToDefault()
        }

        return await handleGetTorchLevel()
    }
}
