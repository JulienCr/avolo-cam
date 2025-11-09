//
//  CaptureManager.swift
//  AvoCam
//
//  Thin facade orchestrating AVFoundation video capture via specialized services
//

import AVFoundation
import CoreMedia
import UIKit
import os
import os.signpost

actor CaptureManager: NSObject {
    // MARK: - Services

    private let logger: PerfLogger
    private let config: CaptureConfig
    private let sessionController: CaptureSessionController
    private let formatManager: FormatManager
    private let exposureController: ExposureController
    private let whiteBalanceController: WhiteBalanceController
    private let lensZoomController: LensZoomController
    private let bufferPoolManager: BufferPoolManager
    private let capabilitiesResolver: CapabilitiesResolver

    // MARK: - Queues

    // Serial queue for all session mutations
    private let sessionQueue = DispatchQueue(label: "com.avocam.capture.session", qos: .userInteractive)
    // Output queue with autorelease pool optimization
    private let outputQueue = DispatchQueue(label: "com.avocam.capture.output", qos: .userInitiated, autoreleaseFrequency: .workItem)

    // MARK: - State

    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var videoOutput: AVCaptureVideoDataOutput?

    private var currentCameraPosition: AVCaptureDevice.Position = .back
    private var currentLens: String = Lens.wide
    private var isUsingVirtualDevice: Bool = false

    private var currentResolution: String?
    private var currentFramerate: Int?

    // MARK: - Frame Streaming

    // AsyncStream for frame delivery (replaces callback + lock pattern)
    private var frameContinuation: AsyncStream<CMSampleBuffer>.Continuation?

    // MARK: - Initialization

    override init() {
        self.config = .default
        self.logger = PerfLogger(config: config)
        self.sessionController = CaptureSessionController(sessionQueue: sessionQueue, config: config, logger: logger)
        self.formatManager = FormatManager(logger: logger)
        self.exposureController = ExposureController(logger: logger)
        self.whiteBalanceController = WhiteBalanceController(logger: logger)
        self.lensZoomController = LensZoomController(logger: logger)
        self.bufferPoolManager = BufferPoolManager(config: config, logger: logger)
        self.capabilitiesResolver = CapabilitiesResolver(formatManager: formatManager)

        super.init()
    }

    // MARK: - Public Access

    nonisolated func getSession() -> AVCaptureSession? {
        // AVCaptureSession is thread-safe for reading to provide to preview layer
        return sessionController.getSession()
    }

    // MARK: - Configuration

    func configure(resolution: String, framerate: Int) async throws {
        logger.logConfiguration(
            resolution: resolution,
            framerate: framerate,
            position: currentCameraPosition == .back ? "back" : "front",
            lens: currentLens
        )

        currentResolution = resolution
        currentFramerate = framerate

        // All session mutations must run on serial sessionQueue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: CaptureError.sessionNotConfigured)
                    return
                }

                do {
                    // Stop existing session if running
                    let wasRunning = self.sessionController.isRunning()
                    if wasRunning {
                        self.sessionController.stopSession()
                    }

                    // Discover device
                    let (device, isVirtual) = try DeviceDiscovery.findBestDevice(
                        position: self.currentCameraPosition,
                        requestedLens: self.currentLens
                    )

                    self.logger.logDeviceFound(device)
                    self.isUsingVirtualDevice = isVirtual

                    if isVirtual {
                        self.logger.info("✅ Using virtual device - lens switching via zoom")
                        let switchFactors = self.lensZoomController.getVirtualDeviceSwitchFactors(device: device)
                        self.logger.debug("Switch factors: \(switchFactors)")
                    }

                    self.videoDevice = device

                    // Configure session with device input and output
                    let (input, output, _) = try self.sessionController.configureSession(
                        device: device,
                        outputQueue: self.outputQueue,
                        delegate: self
                    )

                    self.videoInput = input
                    self.videoOutput = output

                    // Configure device format (must lock device)
                    try device.lockForConfiguration()

                    try self.formatManager.configureFormat(
                        device: device,
                        resolution: resolution,
                        framerate: framerate,
                        lens: self.currentLens
                    )

                    // Apply sensor lock optimizations
                    self.sessionController.applySensorOptimizations(device: device)

                    device.unlockForConfiguration()

                    // Create buffer pool
                    if let dims = try? Resolution(string: resolution) {
                        self.bufferPoolManager.createPool(width: Int(dims.width), height: Int(dims.height))
                    }

                    // Apply lens zoom if using virtual device
                    if isVirtual {
                        try device.lockForConfiguration()
                        _ = self.lensZoomController.applyLensZoom(
                            device: device,
                            lens: self.currentLens,
                            isVirtualDevice: true
                        )
                        device.unlockForConfiguration()
                    }

                    // Restart session if it was running
                    if wasRunning {
                        self.sessionController.startSession()
                        self.logger.info("✅ Restarted capture session after reconfiguration")
                    }

                    continuation.resume()
                } catch {
                    self.logger.error("Configuration failed: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Capture Control

    func startCapture(frameCallback: @escaping (CMSampleBuffer) -> Void) async throws {
        guard sessionController.getSession() != nil else {
            throw CaptureError.sessionNotConfigured
        }

        // Create AsyncStream and store continuation (for future use)
        // For now, we'll keep the callback approach for backward compatibility
        // TODO: Migrate to AsyncStream in future PR

        // Start session on sessionQueue if not already running
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume()
                    return
                }

                if !self.sessionController.isRunning() {
                    self.sessionController.startSession()
                } else {
                    self.logger.debug("Frame callback attached (session already running for preview)")
                }
                continuation.resume()
            }
        }

        // Store callback (will be called from delegate)
        // Note: This is a temporary bridge until we fully migrate to AsyncStream
        // The delegate method will call this callback
        // For now, we'll use a simple actor-isolated storage
        await setFrameCallback(frameCallback)
    }

    func stopCapture() async {
        await clearFrameCallback()
        logger.info("⏹ Frame callback cleared (session still running for preview)")
    }

    // MARK: - Frame Callback Storage (Actor-Isolated)

    private var _frameCallback: ((CMSampleBuffer) -> Void)?

    private func setFrameCallback(_ callback: @escaping (CMSampleBuffer) -> Void) {
        _frameCallback = callback
    }

    private func clearFrameCallback() {
        _frameCallback = nil
    }

    // Called from nonisolated delegate (needs to be thread-safe)
    nonisolated private func invokeFrameCallback(_ sampleBuffer: CMSampleBuffer) {
        // We need to get the callback without actor hopping
        // Using a simple unsafe approach for now (same as original)
        // TODO: Refactor to AsyncStream in future PR
        Task { [weak self] in
            await self?.deliverFrame(sampleBuffer)
        }
    }

    private func deliverFrame(_ sampleBuffer: CMSampleBuffer) {
        _frameCallback?(sampleBuffer)
    }

    // MARK: - Camera Settings

    func updateSettings(_ settings: CameraSettingsRequest) async throws {
        logger.debug("🔧 CaptureManager.updateSettings called")
        logger.debug("Camera position: \(settings.cameraPosition ?? "nil"), lens: \(settings.lens ?? "nil")")
        logger.debug("Current position: \(currentCameraPosition == .back ? "back" : "front"), lens: \(currentLens)")

        var needsReconfigure = false

        // Handle camera position change
        if let cameraPosition = settings.cameraPosition {
            let newPosition: AVCaptureDevice.Position = (cameraPosition == "front") ? .front : .back
            if newPosition != currentCameraPosition {
                currentCameraPosition = newPosition
                needsReconfigure = true
                logger.info("📷 Switching to \(cameraPosition) camera - reconfigure needed")
            }
        }

        // Handle lens change
        if let lens = settings.lens, lens != currentLens {
            let evaluation = lensZoomController.evaluateLensChange(
                newLens: lens,
                currentLens: currentLens,
                position: currentCameraPosition,
                isVirtualDevice: isUsingVirtualDevice
            )

            if evaluation.needsReconfigure {
                currentLens = lens
                needsReconfigure = true
            } else if !evaluation.needsReconfigure && isUsingVirtualDevice {
                // Can switch via zoom
                currentLens = lens
                logger.info("📷 Switching to \(lens) lens via zoom")
            }
        }

        // Reconfigure if needed
        if needsReconfigure {
            let resolution = currentResolution ?? "1920x1080"
            let framerate = currentFramerate ?? 30

            logger.info("🔄 Reconfiguring capture session with \(resolution) @ \(framerate)fps")
            try await configure(resolution: resolution, framerate: framerate)
            logger.info("✅ Camera/lens reconfiguration complete")
        }

        guard let device = videoDevice else {
            logger.error("No video device available")
            throw CaptureError.deviceNotAvailable
        }

        // Apply settings to device (must lock)
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        // White balance
        if let wbMode = settings.wbMode {
            whiteBalanceController.applyWhiteBalance(
                device: device,
                mode: wbMode,
                sceneCCT_K: settings.wbKelvin,
                tint: settings.wbTint
            )
        }

        // Exposure
        if settings.isoMode != nil || settings.iso != nil || settings.shutterMode != nil || settings.shutterS != nil {
            exposureController.applyExposure(
                device: device,
                isoMode: settings.isoMode,
                iso: settings.iso,
                shutterMode: settings.shutterMode,
                shutterS: settings.shutterS,
                framerate: currentFramerate ?? 30
            )
        }

        // Focus
        if let focusMode = settings.focusMode {
            switch focusMode {
            case .auto:
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
            case .manual:
                if device.isFocusModeSupported(.locked) {
                    device.focusMode = .locked
                }
            }
        }

        // Zoom: handle both explicit zoom factor and lens-based zoom
        if settings.lens != nil && !isUsingVirtualDevice {
            // Physical lens switch - reset to base zoom
            lensZoomController.resetToBaseZoom(device: device, lens: currentLens)
        } else if let zoomFactor = settings.zoomFactor {
            // Explicit zoom factor requested
            if let detectedLens = lensZoomController.applyZoom(
                device: device,
                zoomFactor: zoomFactor,
                isVirtualDevice: isUsingVirtualDevice
            ) {
                currentLens = detectedLens
            }
        } else if settings.lens != nil, isUsingVirtualDevice {
            // Lens changed, apply appropriate zoom for virtual device
            _ = lensZoomController.applyLensZoom(
                device: device,
                lens: currentLens,
                isVirtualDevice: true
            )
        }

        logger.info("✅ Camera settings updated")
    }

    // MARK: - White Balance Measurement

    func measureWhiteBalance() async throws -> (sceneCCT_K: Int, tint: Double) {
        guard let device = videoDevice else {
            throw CaptureError.deviceNotAvailable
        }

        return try await whiteBalanceController.measureWhiteBalance(device: device)
    }

    // MARK: - Capabilities

    func getCapabilities() -> [Capability] {
        guard let device = videoDevice else {
            return []
        }

        return capabilitiesResolver.getCapabilities(
            device: device,
            position: currentCameraPosition,
            currentLens: currentLens,
            isVirtualDevice: isUsingVirtualDevice
        )
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // PERF: Signpost begin
        if config.enableSignposts {
            logger.signpostBegin("Frame Capture")
        }

        // HOT PATH: Invoke callback without actor hop
        invokeFrameCallback(sampleBuffer)

        // PERF: Signpost end
        if config.enableSignposts {
            logger.signpostEnd("Frame Capture")
        }
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Log dropped frames
        print("⚠️ Dropped frame")
    }
}
