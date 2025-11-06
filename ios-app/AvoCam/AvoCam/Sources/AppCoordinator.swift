//
//  AppCoordinator.swift
//  AvoCam
//
//  Central coordinator managing all app components
//

import Foundation
import Combine
import UIKit
import AVFoundation

@MainActor
class AppCoordinator: ObservableObject {
    // MARK: - Published State

    @Published var isStreaming: Bool = false
    @Published var currentSettings: CurrentSettings?
    @Published var telemetry: Telemetry?
    @Published var error: String?
    @Published var captureSession: AVCaptureSession?
    @Published var isScreenDimmed: Bool = false
    @Published var localIPAddress: String?
    @Published var bearerTokenForDisplay: String = ""
    @Published var isAuthenticationEnabled: Bool = false

    // MARK: - Components

    private var captureManager: CaptureManager?
    private var encoderManager: EncoderManager?
    private var ndiManager: NDIManager?
    private var networkServer: NetworkServer?
    private var telemetryCollector: TelemetryCollector
    private var bonjourService: BonjourService?

    // MARK: - Configuration

    private let cameraAlias: String
    private let serverPort: Int = 8888
    private let bearerToken: String

    // MARK: - Cancellables

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init() {
        // Generate or load alias and token
        self.cameraAlias = UserDefaults.standard.string(forKey: "camera_alias") ?? "AVOLO-CAM-\(Self.generateShortID())"
        self.bearerToken = UserDefaults.standard.string(forKey: "bearer_token") ?? Self.generateToken()
        self.telemetryCollector = TelemetryCollector()

        // Save if newly generated
        UserDefaults.standard.set(cameraAlias, forKey: "camera_alias")
        UserDefaults.standard.set(bearerToken, forKey: "bearer_token")
        
        // Set display token
        self.bearerTokenForDisplay = bearerToken
        
        // Load authentication setting (default: disabled)
        self.isAuthenticationEnabled = UserDefaults.standard.bool(forKey: "authentication_enabled")
    }

    // MARK: - Lifecycle

    func start() {
        print("🚀 Starting AvoCam with alias: \(cameraAlias)")
        print("🔑 Bearer Token: \(bearerToken)")

        // Initialize components
        captureManager = CaptureManager()
        encoderManager = EncoderManager()
        ndiManager = NDIManager(alias: cameraAlias)

        // Detect local IP address
        detectLocalIPAddress()

        // Start network server
        startNetworkServer()

        // Start Bonjour advertisement
        startBonjourService()

        // Disable idle timer during app lifetime
        UIApplication.shared.isIdleTimerDisabled = true

        // Start telemetry collection
        startTelemetryCollection()

        // Initialize preview session early
        Task {
            await initializePreviewSession()
        }
    }

    // MARK: - Network Detection

    private func detectLocalIPAddress() {
        var address: String?

        // Get list of all interfaces on the local machine
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

            // Check for IPv4 or IPv6 interface
            if addrFamily == UInt8(AF_INET) || addrFamily == UInt8(AF_INET6) {
                // Get interface name
                let name = String(cString: interface.pointee.ifa_name)

                // We're interested in en0 (Wi-Fi) or en1 (Ethernet)
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
                        // Prefer IPv4 over IPv6
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
        // Configure capture with default settings to enable preview
        // This allows camera preview to show even when not streaming
        do {
            try await captureManager?.configure(
                resolution: "1920x1080",
                framerate: 30
            )

            // Get the session for preview
            if let session = captureManager?.getSession() {
                self.captureSession = session

                // Start the session for preview (but not streaming yet)
                if !session.isRunning {
                    session.startRunning()
                }

                print("✅ Preview session initialized and running")
            }
        } catch {
            print("⚠️ Failed to initialize preview session: \(error)")
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
        bonjourService?.stop()
        networkServer?.stop()

        // Re-enable idle timer
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func stopPreviewSession() async {
        // Stop the capture session completely when app is closing
        captureSession?.stopRunning()
        captureSession = nil
        print("⏹ Preview session stopped")
    }

    func pausePreview() async {
        // Pause preview when app goes to background (unless actively streaming)
        guard !isStreaming else {
            print("⏸ App backgrounded but continuing capture for active stream")
            return
        }

        captureSession?.stopRunning()
        print("⏸ Preview paused (app in background)")
    }

    func resumePreview() async {
        // Resume preview when app comes back to foreground
        if let session = captureSession, !session.isRunning {
            session.startRunning()
            print("▶️ Preview resumed (app in foreground)")
        }
    }

    // MARK: - Authentication Control
    
    func toggleAuthentication() {
        isAuthenticationEnabled.toggle()
        UserDefaults.standard.set(isAuthenticationEnabled, forKey: "authentication_enabled")
        networkServer?.setAuthenticationEnabled(isAuthenticationEnabled)
        print("🔐 Authentication \(isAuthenticationEnabled ? "enabled" : "disabled")")
    }
    
    // MARK: - Screen Brightness Control

    func toggleScreenBrightness() {
        setScreenBrightness(dimmed: !isScreenDimmed)
    }

    func setScreenBrightness(dimmed: Bool) {
        isScreenDimmed = dimmed

        if dimmed {
            // Dim screen to minimum to save battery
            UIScreen.main.brightness = 0.01
            print("🔅 Screen dimmed to save battery")
        } else {
            // Restore to normal brightness
            UIScreen.main.brightness = 0.5
            print("🔆 Screen brightness restored")
        }
    }

    // MARK: - Network Server

    private func startNetworkServer() {
        networkServer = NetworkServer(
            port: serverPort,
            bearerToken: bearerToken,
            requestHandler: self
        )
        
        // Set authentication state
        networkServer?.setAuthenticationEnabled(isAuthenticationEnabled)

        do {
            try networkServer?.start()
            print("✅ Network server started on port \(serverPort)")
            print("🔐 Authentication: \(isAuthenticationEnabled ? "enabled" : "disabled")")
        } catch {
            self.error = "Failed to start network server: \(error.localizedDescription)"
            print("❌ Failed to start network server: \(error)")
        }
    }

    // MARK: - Bonjour Service

    private func startBonjourService() {
        bonjourService = BonjourService(
            alias: cameraAlias,
            port: serverPort
        )
        bonjourService?.start()
        print("✅ Bonjour service started: _avolocam._tcp.local")
    }

    // MARK: - Telemetry Collection

    private func startTelemetryCollection() {
        // Collect telemetry every second
        Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                Task { await self.updateTelemetry() }
            }
            .store(in: &cancellables)
    }

    private func updateTelemetry() async {
        let systemTelemetry = await telemetryCollector.collect()
        let encoderTelemetry = encoderManager?.getCurrentTelemetry()

        self.telemetry = Telemetry(
            fps: encoderTelemetry?.fps ?? 0,
            bitrate: encoderTelemetry?.bitrate ?? 0,
            battery: systemTelemetry.battery,
            tempC: systemTelemetry.temperature,
            wifiRssi: systemTelemetry.wifiRssi,
            queueMs: encoderTelemetry?.queueMs,
            droppedFrames: encoderTelemetry?.droppedFrames,
            chargingState: systemTelemetry.chargingState
        )

        // Broadcast telemetry via WebSocket
        if let telemetry = self.telemetry {
            let currentNDIState: NDIState = self.isStreaming ? .streaming : .idle
            networkServer?.broadcastTelemetry(telemetry, ndiState: currentNDIState)
        }

        // Check thermal state and adjust if needed
        checkThermalState(systemTelemetry.thermalState)
    }

    // MARK: - Thermal Management

    private func checkThermalState(_ state: ProcessInfo.ThermalState) {
        guard isStreaming else { return }

        switch state {
        case .serious:
            print("⚠️ Thermal state: serious - consider reducing bitrate")
            // TODO: Implement gradual bitrate reduction
        case .critical:
            print("🔥 Thermal state: critical - reducing bitrate/fps")
            // TODO: Implement aggressive bitrate/fps reduction
        default:
            break
        }
    }

    // MARK: - Streaming Control

    func startStreaming(request: StreamStartRequest) async throws {
        guard !isStreaming else {
            throw AppError.alreadyStreaming
        }

        print("▶️ Starting stream: \(request.resolution) @ \(request.framerate)fps, \(request.bitrate)bps")

        // Configure capture
        try await captureManager?.configure(
            resolution: request.resolution,
            framerate: request.framerate
        )

        // Configure encoder
        try encoderManager?.configure(
            resolution: request.resolution,
            framerate: request.framerate,
            bitrate: request.bitrate,
            codec: request.codec
        )

        // Start NDI sender
        try ndiManager?.start()

        // Start capture session
        try await captureManager?.startCapture { [weak self] sampleBuffer in
            guard let self = self else { return }

            // Extract pixel buffer from sample buffer
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                return
            }

            // Send directly to NDI (NDI handles compression internally)
            self.ndiManager?.send(pixelBuffer: pixelBuffer)
        }

        isStreaming = true

        // Update current settings
        updateCurrentSettings(from: request)
    }

    func stopStreaming() async {
        guard isStreaming else { return }

        print("⏹ Stopping stream")

        // Stop capture
        await captureManager?.stopCapture()

        // Stop encoder
        encoderManager?.stop()

        // Stop NDI
        ndiManager?.stop()

        isStreaming = false
    }

    // MARK: - Camera Control

    func updateCameraSettings(_ settings: CameraSettingsRequest) async throws {
        try await captureManager?.updateSettings(settings)

        // Update current settings
        if var current = currentSettings {
            if let wbMode = settings.wbMode {
                current.wbMode = wbMode
            }
            if let wbKelvin = settings.wbKelvin {
                current.wbKelvin = wbKelvin
            }
            if let wbTint = settings.wbTint {
                current.wbTint = wbTint
            }
            if let iso = settings.iso {
                current.iso = iso
            }
            if let shutterS = settings.shutterS {
                current.shutterS = shutterS
            }
            if let focusMode = settings.focusMode {
                current.focusMode = focusMode
            }
            if let zoomFactor = settings.zoomFactor {
                current.zoomFactor = zoomFactor
            }

            currentSettings = current
        }
    }

    func forceKeyframe() {
        encoderManager?.forceKeyframe()
    }

    // MARK: - Capabilities

    func getCapabilities() async -> [Capability] {
        return await captureManager?.getCapabilities() ?? []
    }

    // MARK: - Status

    func getStatus() async -> StatusResponse {
        return StatusResponse(
            alias: cameraAlias,
            ndiState: isStreaming ? .streaming : .idle,
            current: currentSettings ?? createDefaultSettings(),
            telemetry: telemetry ?? createDefaultTelemetry(),
            capabilities: await getCapabilities()
        )
    }

    // MARK: - Helpers

    private func updateCurrentSettings(from request: StreamStartRequest) {
        currentSettings = CurrentSettings(
            resolution: request.resolution,
            fps: request.framerate,
            bitrate: request.bitrate,
            codec: request.codec,
            wbMode: .auto,
            wbKelvin: nil,
            wbTint: nil,
            iso: 0,
            shutterS: 0.0,
            focusMode: .auto,
            zoomFactor: 1.0
        )
    }

    private func createDefaultSettings() -> CurrentSettings {
        return CurrentSettings(
            resolution: "1920x1080",
            fps: 30,
            bitrate: 10000000,
            codec: "h264",
            wbMode: .auto,
            wbKelvin: nil,
            wbTint: nil,
            iso: 0,
            shutterS: 0.0,
            focusMode: .auto,
            zoomFactor: 1.0
        )
    }

    private func createDefaultTelemetry() -> Telemetry {
        return Telemetry(
            fps: 0,
            bitrate: 0,
            battery: 1.0,
            tempC: 25.0,
            wifiRssi: -50,
            queueMs: nil,
            droppedFrames: nil,
            chargingState: nil
        )
    }

    private static func generateShortID() -> String {
        return String(format: "%02X", Int.random(in: 0...255))
    }

    private static func generateToken() -> String {
        return UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
}

// MARK: - App Errors

enum AppError: LocalizedError {
    case alreadyStreaming
    case notStreaming
    case invalidConfiguration
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .alreadyStreaming:
            return "Stream is already active"
        case .notStreaming:
            return "Stream is not active"
        case .invalidConfiguration:
            return "Invalid configuration provided"
        case .networkError(let message):
            return "Network error: \(message)"
        }
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

    func handleForceKeyframe() {
        forceKeyframe()
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

        // Update settings from request
        settings.selectedPresetId = request.selectedPresetId
        settings.customResolution = request.customResolution
        settings.customFps = request.customFps
        if let codecStr = request.customCodec {
            settings.customCodec = VideoCodec(rawValue: codecStr)
        }
        settings.customBitrate = request.customBitrate

        // Save settings
        VideoSettingsManager.save(settings)

        print("✅ Video settings updated and saved")
    }
  
    func handleScreenBrightness(_ request: ScreenBrightnessRequest) {
        setScreenBrightness(dimmed: request.dimmed)
    }

    func handleMeasureWhiteBalance() async throws -> WhiteBalanceMeasureResponse {
        let result = try await captureManager?.measureWhiteBalance()
        guard let (kelvin, tint) = result else {
            throw AppError.invalidConfiguration
        }
        return WhiteBalanceMeasureResponse(kelvin: kelvin, tint: tint)
    }
}
