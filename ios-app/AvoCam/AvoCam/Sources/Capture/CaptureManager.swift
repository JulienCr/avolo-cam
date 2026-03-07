//
//  CaptureManager.swift
//  AvoCam
//
//  Manages AVFoundation video capture
//

@preconcurrency import AVFoundation
import CoreMedia
import UIKit
import os
import os.signpost

actor CaptureManager: NSObject {
    // MARK: - Properties

    nonisolated(unsafe) private var captureSession: AVCaptureSession?
    var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var videoOutput: AVCaptureVideoDataOutput?

    // Serial queue for all session mutations (beginConfiguration/commitConfiguration, add/remove input/output, start/stop)
    private let sessionQueue = DispatchQueue(label: "com.avocam.capture.session", qos: .userInteractive)
    // Output queue with autorelease pool optimization for minimal per-frame allocations
    private let outputQueue = DispatchQueue(label: "com.avocam.capture.output", qos: .userInitiated, autoreleaseFrequency: .workItem)

    // PERF: Feature flags for optimization rollback
    let enableBufferPoolOptimization = true
    let enableSensorLockOptimizations = true
    private let enableSignposts = true

    // PERF: Zero-copy buffer pool
    // Thread-safe access via bufferPoolLock, accessed from sessionQueue closures
    nonisolated(unsafe) var pixelBufferPool: CVPixelBufferPool?
    let poolSize: Int = 6  // 2x framerate headroom
    let bufferPoolLock = OSAllocatedUnfairLock(uncheckedState: ())

    // PERF: os_signpost for latency tracking
    // Safe for nonisolated access - initialized once, read-only thereafter
    private static let sharedPerfLog = OSLog(subsystem: "com.avocam.capture", category: .pointsOfInterest)
    nonisolated let perfLog = CaptureManager.sharedPerfLog
    nonisolated let captureSignpostID = OSSignpostID(log: CaptureManager.sharedPerfLog)

    // Thread-safe frame callback storage (nonisolated to avoid actor hop on hot path)
    // Using @unchecked Sendable as thread safety is guaranteed by OSAllocatedUnfairLock
    private nonisolated(unsafe) var _frameCallback: ((CMSampleBuffer) -> Void)?
    private let frameCallbackLock = OSAllocatedUnfairLock(uncheckedState: ())
    var currentResolution: String?
    var currentFramerate: Int?

    // Format cache: (deviceID, lens, width, height, fps) -> AVCaptureDevice.Format
    var formatCache: [String: AVCaptureDevice.Format] = [:]

    // Camera position and lens tracking
    var currentCameraPosition: AVCaptureDevice.Position = .back
    var currentLens: String = "wide"  // "wide", "ultra_wide", "telephoto"
    var isUsingVirtualDevice: Bool = false  // Track if we're using a multi-camera virtual device

    // Exposure state tracking
    var currentISOMode: ExposureMode = .auto
    var currentISO: Float = 0
    var currentShutterMode: ExposureMode = .auto
    var currentShutterS: Double = 0

    // Focus state tracking
    var currentFocusMode: FocusMode = .auto
    var currentFocusDistance: Double? = nil

    // MARK: - Public Access

    nonisolated func getSession() -> AVCaptureSession? {
        // AVCaptureSession is thread-safe for reading to provide to preview layer
        return captureSession
    }

    func getCurrentFocusState() -> (mode: FocusMode, distance: Double?) {
        guard let device = videoDevice else {
            return (mode: currentFocusMode, distance: currentFocusDistance)
        }

        // Read actual device state
        let actualDistance = Double(device.lensPosition)
        return (mode: currentFocusMode, distance: actualDistance)
    }

    // MARK: - Configuration

    /// Result struct to shuttle mutations back from the sessionQueue closure to the actor
    private struct ConfigureResult: Sendable {
        let isUsingVirtualDevice: Bool
        nonisolated(unsafe) let videoDevice: AVCaptureDevice?
        nonisolated(unsafe) let videoInput: AVCaptureDeviceInput?
        nonisolated(unsafe) let videoOutput: AVCaptureVideoDataOutput?
        nonisolated(unsafe) let captureSession: AVCaptureSession
    }

    func configure(resolution: String, framerate: Int) async throws {
        print("📷 Configuring capture: \(resolution) @ \(framerate)fps, position: \(currentCameraPosition == .back ? "back" : "front"), lens: \(currentLens)")

        // Check if already configured with same settings
        // NOTE: We DO NOT check camera position or lens here because those are already
        // updated in updateSettings() before calling configure(). If we're here, it means
        // something changed and we need to reconfigure.
        // The old logic would skip reconfiguration when switching cameras with same resolution/fps.

        currentResolution = resolution
        currentFramerate = framerate

        // Capture actor-isolated state before entering the nonisolated sessionQueue closure
        let position = self.currentCameraPosition
        let lens = self.currentLens
        let existingSession = self.captureSession
        let formatCacheSnapshot = self.formatCache
        let sensorLockEnabled = self.enableSensorLockOptimizations
        let bufferPoolEnabled = self.enableBufferPoolOptimization
        let delegateSelf = self
        let outQueue = self.outputQueue

        // All session mutations must run on serial sessionQueue
        let result: ConfigureResult = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ConfigureResult, Error>) in
            sessionQueue.async {
                do {
                    // Stop existing session if running
                    let wasRunning = existingSession?.isRunning ?? false
                    if wasRunning {
                        existingSession?.stopRunning()
                    }

                    // Setup capture session (reuse existing or create new)
                    let session = existingSession ?? AVCaptureSession()
                    session.sessionPreset = .inputPriority  // We'll manually set format

                    // Begin atomic configuration
                    session.beginConfiguration()

                    // Disable wide color to prevent implicit conversions (iOS 10+)
                    if #available(iOS 10.0, *) {
                        session.automaticallyConfiguresCaptureDeviceForWideColor = false
                    }

                    // Remove existing inputs/outputs if reconfiguring
                    if existingSession != nil {
                        session.inputs.forEach { session.removeInput($0) }
                        session.outputs.forEach { session.removeOutput($0) }
                    }

                    // Discover device using prioritized list (requested lens first)
                    let deviceTypes = CaptureManager.prioritizedDeviceTypes(for: position, requestedLens: lens)
                    print("🔍 Looking for device: position=\(position == .back ? "back" : "front"), lens=\(lens)")
                    print("   Prioritized device types: \(deviceTypes.map { $0.rawValue })")

                    let discovery = AVCaptureDevice.DiscoverySession(
                        deviceTypes: deviceTypes,
                        mediaType: .video,
                        position: position
                    )

                    guard let device = discovery.devices.first else {
                        session.commitConfiguration()
                        print("❌ No camera device available!")
                        continuation.resume(throwing: CaptureError.deviceNotAvailable)
                        return
                    }

                    print("✅ Found camera device: \(device.localizedName)")

                    // Check if using virtual device (can switch lenses via zoom)
                    let usingVirtual = [
                        AVCaptureDevice.DeviceType.builtInTripleCamera,
                        .builtInDualWideCamera,
                        .builtInDualCamera
                    ].contains(device.deviceType)

                    if usingVirtual {
                        print("✅ Using virtual device - lens switching via zoom")
                        print("   Switch factors: \(device.virtualDeviceSwitchOverVideoZoomFactors)")
                    }

                    // Create device input
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else {
                        session.commitConfiguration()
                        throw CaptureError.cannotAddInput
                    }
                    session.addInput(input)

                    // Configure device format (must be sync on sessionQueue)
                    try CaptureManager.configureFormatSyncStatic(
                        device: device, resolution: resolution, framerate: framerate,
                        lens: lens, formatCache: formatCacheSnapshot,
                        enableSensorLockOptimizations: sensorLockEnabled,
                        enableBufferPoolOptimization: bufferPoolEnabled,
                        poolSize: delegateSelf.poolSize,
                        bufferPoolLock: delegateSelf.bufferPoolLock,
                        pixelBufferPoolSetter: { pool in
                            nonisolated(unsafe) let sendablePool = pool
                            delegateSelf.bufferPoolLock.withLock {
                                delegateSelf.pixelBufferPool = sendablePool
                            }
                        }
                    )

                    // Create video output
                    let output = AVCaptureVideoDataOutput()
                    // NDI requires full range NV12 ('420f' not '420v')
                    output.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String:
                            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    ]
                    output.alwaysDiscardsLateVideoFrames = true
                    output.setSampleBufferDelegate(delegateSelf, queue: outQueue)

                    guard session.canAddOutput(output) else {
                        session.commitConfiguration()
                        throw CaptureError.cannotAddOutput
                    }
                    session.addOutput(output)

                    // Configure connection (orientation, stabilization)
                    CaptureManager.configureConnectionStatic(output.connection(with: .video))

                    // Commit configuration
                    session.commitConfiguration()

                    // Apply lens zoom if using virtual device
                    if usingVirtual, let zoomFactor = CaptureManager.zoomFactorForLensStatic(lens, device: device) {
                        try device.lockForConfiguration()
                        device.videoZoomFactor = zoomFactor
                        device.unlockForConfiguration()
                        let uiZoom = zoomFactor / 2.0
                        print("✅ Applied zoom \(String(format: "%.1f", uiZoom))x UI (device: \(String(format: "%.1f", zoomFactor))x) for lens '\(lens)'")
                    }

                    // Restart session if it was running before reconfiguration
                    if wasRunning {
                        session.startRunning()
                        print("✅ Restarted capture session after reconfiguration")
                    }

                    let result = ConfigureResult(
                        isUsingVirtualDevice: usingVirtual,
                        videoDevice: device,
                        videoInput: input,
                        videoOutput: output,
                        captureSession: session
                    )
                    continuation.resume(returning: result)
                } catch {
                    print("❌ Configuration failed: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }

        // Apply mutations back on the actor
        self.isUsingVirtualDevice = result.isUsingVirtualDevice
        self.videoDevice = result.videoDevice
        self.videoInput = result.videoInput
        self.videoOutput = result.videoOutput
        self.captureSession = result.captureSession
    }

    /// PERF: Apply sensor lock optimizations to reduce ISP overhead
    /// Disables HDR, torch, and continuous auto-adjustments (6% CPU, 4% GPU reduction)
    /// IMPORTANT: Must be called while device.lockForConfiguration() is held
    nonisolated func applySensorLockOptimizationsLocked(device: AVCaptureDevice) {
        // Disable HDR processing (3-5% GPU overhead even when "off")
        if #available(iOS 13.0, *) {
            if device.activeFormat.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = false
                print("✅ PERF: HDR auto-adjust disabled")
            }
        }

        // NOTE: Torch is now managed by TorchController for NDI tally indication
        // Torch will be turned on/off based on program tally state
        // Only disable flash (not needed for tally)
        if device.hasFlash && device.flashMode != .off {
            device.flashMode = .off
        }

        // Lock auto-exposure bias to 0 (prevent continuous adjustment when manual)
        if device.isExposureModeSupported(.locked) || device.isExposureModeSupported(.custom) {
            device.setExposureTargetBias(0, completionHandler: nil)
        }

        // Disable subject area change monitoring (reduces KVO overhead)
        device.isSubjectAreaChangeMonitoringEnabled = false

        print("✅ PERF: Sensor optimizations applied (bias locked, subject monitoring off, torch managed by tally)")
    }

    /// Configure connection properties (orientation, stabilization)
    /// Nonisolated static: pure function operating only on the connection parameter
    nonisolated static func configureConnectionStatic(_ connection: AVCaptureConnection?) {
        guard let connection = connection else { return }

        // Disable stabilization for lowest latency
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .off
        }

        // Lock video orientation to landscape
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = .landscapeRight
        }
    }

    // MARK: - Capture Control

    func startCapture(frameCallback: @escaping (CMSampleBuffer) -> Void) async throws {
        guard let session = captureSession else {
            throw CaptureError.sessionNotConfigured
        }

        // Store callback with thread-safe lock (nonisolated access on hot path)
        frameCallbackLock.withLock {
            _frameCallback = frameCallback
        }

        // Start session on sessionQueue if not already running
        nonisolated(unsafe) let capturedSession = session
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                if !capturedSession.isRunning {
                    capturedSession.startRunning()
                    print("▶️ Capture session started")
                } else {
                    print("▶️ Frame callback attached (session already running for preview)")
                }
                continuation.resume()
            }
        }
    }

    func stopCapture() async {
        // Clear the frame callback via thread-safe lock
        frameCallbackLock.withLock {
            _frameCallback = nil
        }
        print("⏹ Frame callback cleared (session still running for preview)")
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    // PERF: Thread-safe counter for rate-limited dropped frame logging
    private static let droppedFrameCounter = OSAllocatedUnfairLock(uncheckedState: 0)

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        autoreleasepool {
            // PERF: Signpost begin (compiled out in Release builds)
            if enableSignposts {
                os_signpost(.begin, log: perfLog, name: "Frame Capture", signpostID: captureSignpostID)
            }

            // HOT PATH: Invoke callback directly without actor hop or metadata writes
            // Color space is set at device level (sRGB) and output level (video range NV12)
            // Thread-safe access to callback via lock
            let callback = frameCallbackLock.withLock { _frameCallback }
            callback?(sampleBuffer)

            // PERF: Signpost end
            if enableSignposts {
                os_signpost(.end, log: perfLog, name: "Frame Capture", signpostID: captureSignpostID)
            }
        }
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // PERF: Atomic increment with single lock acquisition
        let count = CaptureManager.droppedFrameCounter.withLock { state -> Int in
            state += 1
            return state
        }
        // Log every 30 drops to avoid spam
        if count == 1 || count % 30 == 0 {
            print("⚠️ AVFoundation dropped frames: \(count) total")
        }
    }
}

// MARK: - Errors

enum CaptureError: LocalizedError {
    case deviceNotAvailable
    case cannotAddInput
    case cannotAddOutput
    case sessionNotConfigured
    case formatNotSupported
    case invalidResolution
    case invalidWhiteBalanceGains
    case whiteBalanceNotSupported

    var errorDescription: String? {
        switch self {
        case .deviceNotAvailable:
            return "Camera device not available"
        case .cannotAddInput:
            return "Cannot add capture input"
        case .cannotAddOutput:
            return "Cannot add capture output"
        case .sessionNotConfigured:
            return "Capture session not configured"
        case .formatNotSupported:
            return "Requested format not supported"
        case .invalidResolution:
            return "Invalid resolution format"
        case .invalidWhiteBalanceGains:
            return "White balance gains out of valid range"
        case .whiteBalanceNotSupported:
            return "White balance mode not supported"
        }
    }
}

