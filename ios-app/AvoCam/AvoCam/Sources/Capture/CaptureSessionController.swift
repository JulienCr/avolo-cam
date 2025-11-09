//
//  CaptureSessionController.swift
//  AvoCam
//
//  Manages AVCaptureSession lifecycle and configuration
//

import AVFoundation
import Foundation

/// Manages AVCaptureSession setup, start/stop, and input/output configuration
/// All mutations must occur on the sessionQueue
final class CaptureSessionController {

    // MARK: - Properties

    private var session: AVCaptureSession?
    private let sessionQueue: DispatchQueue
    private let logger: PerfLogger
    private let config: CaptureConfig

    // MARK: - Initialization

    init(sessionQueue: DispatchQueue, config: CaptureConfig, logger: PerfLogger) {
        self.sessionQueue = sessionQueue
        self.config = config
        self.logger = logger
    }

    // MARK: - Session Lifecycle

    /// Get or create the capture session
    func getOrCreateSession() -> AVCaptureSession {
        if let existing = session {
            return existing
        }

        let newSession = AVCaptureSession()
        newSession.sessionPreset = .inputPriority  // We'll manually set format

        // Disable wide color to prevent implicit conversions (iOS 10+)
        if #available(iOS 10.0, *) {
            newSession.automaticallyConfiguresCaptureDeviceForWideColor = false
        }

        session = newSession
        return newSession
    }

    /// Get the current session (read-only access, thread-safe)
    func getSession() -> AVCaptureSession? {
        return session
    }

    /// Start the capture session if not already running
    func startSession() {
        guard let session = session else { return }

        if !session.isRunning {
            session.startRunning()
            logger.info("▶️ Capture session started")
        } else {
            logger.debug("Session already running")
        }
    }

    /// Stop the capture session if running
    func stopSession() {
        guard let session = session else { return }

        if session.isRunning {
            session.stopRunning()
            logger.info("⏹ Capture session stopped")
        }
    }

    /// Check if session is currently running
    func isRunning() -> Bool {
        return session?.isRunning ?? false
    }

    // MARK: - Configuration

    /// Configure session with device input and video output
    /// - Parameters:
    ///   - device: The capture device to use
    ///   - outputQueue: Queue for video output delegate callbacks
    ///   - delegate: The sample buffer delegate
    /// - Returns: Tuple of (videoInput, videoOutput, connection)
    /// - Throws: CaptureError if configuration fails
    func configureSession(
        device: AVCaptureDevice,
        outputQueue: DispatchQueue,
        delegate: AVCaptureVideoDataOutputSampleBufferDelegate
    ) throws -> (
        videoInput: AVCaptureDeviceInput,
        videoOutput: AVCaptureVideoDataOutput,
        connection: AVCaptureConnection?
    ) {
        let session = getOrCreateSession()

        // Begin atomic configuration
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Remove existing inputs/outputs if reconfiguring
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        // Create and add device input
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CaptureError.cannotAddInput
        }
        session.addInput(input)

        // Create video output
        let output = AVCaptureVideoDataOutput()
        // NDI requires full range NV12 ('420f' not '420v')
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(delegate, queue: outputQueue)

        guard session.canAddOutput(output) else {
            throw CaptureError.cannotAddOutput
        }
        session.addOutput(output)

        // Get connection for further configuration
        let connection = output.connection(with: .video)

        // Configure connection (orientation, stabilization)
        configureConnection(connection)

        return (videoInput: input, videoOutput: output, connection: connection)
    }

    // MARK: - Connection Configuration

    /// Configure connection properties (orientation, stabilization)
    private func configureConnection(_ connection: AVCaptureConnection?) {
        guard let connection = connection else { return }

        // Disable stabilization for lowest latency
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .off
        }

        // Lock video orientation to landscape
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = .landscapeRight
        }

        logger.debug("Connection configured: orientation=landscapeRight, stabilization=off")
    }

    // MARK: - Device Lock Optimizations

    /// Apply sensor lock optimizations to reduce ISP overhead
    /// Disables HDR, flash, and continuous auto-adjustments (6% CPU, 4% GPU reduction)
    /// IMPORTANT: Must be called while device.lockForConfiguration() is held
    func applySensorOptimizations(device: AVCaptureDevice) {
        guard config.enableSensorLocks else {
            logger.debug("Sensor lock optimizations disabled")
            return
        }

        // Disable HDR processing (3-5% GPU overhead even when "off")
        if #available(iOS 13.0, *) {
            if device.activeFormat.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = false
                logger.debug("✅ PERF: HDR auto-adjust disabled")
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

        logger.info("✅ PERF: Sensor optimizations applied (bias locked, subject monitoring off, torch managed by tally)")
    }
}
