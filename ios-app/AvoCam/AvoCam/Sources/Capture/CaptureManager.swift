//
//  CaptureManager.swift
//  AvoCam
//
//  Manages AVFoundation video capture
//

import AVFoundation
import CoreMedia
import UIKit

actor CaptureManager: NSObject {
    // MARK: - Properties

    nonisolated(unsafe) private var captureSession: AVCaptureSession?
    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var videoOutput: AVCaptureVideoDataOutput?
    private let outputQueue = DispatchQueue(label: "com.avocam.capture.output")

    private var frameCallback: ((CMSampleBuffer) -> Void)?
    private var currentResolution: String?
    private var currentFramerate: Int?

    // MARK: - Public Access

    nonisolated func getSession() -> AVCaptureSession? {
        // AVCaptureSession is thread-safe for reading to provide to preview layer
        return captureSession
    }

    // MARK: - Configuration

    func configure(resolution: String, framerate: Int) async throws {
        print("📷 Configuring capture: \(resolution) @ \(framerate)fps")

        // Check if already configured with same settings
        if let existingSession = captureSession,
            currentResolution == resolution,
            currentFramerate == framerate
        {
            print("✅ Already configured with requested settings, reusing session")
            return
        }

        currentResolution = resolution
        currentFramerate = framerate

        // Stop existing session if running
        let wasRunning = captureSession?.isRunning ?? false
        if wasRunning {
            captureSession?.stopRunning()
        }

        // Setup capture session (reuse existing or create new)
        let session = captureSession ?? AVCaptureSession()
        session.sessionPreset = .inputPriority  // We'll manually set format

        // Begin atomic configuration
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Remove existing inputs/outputs if reconfiguring
        if captureSession != nil {
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
        }

        // Get video device using discovery session (more robust than default lookup)
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )
        guard let device = discovery.devices.first else {
            throw CaptureError.deviceNotAvailable
        }

        videoDevice = device

        // Create device input
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CaptureError.cannotAddInput
        }
        session.addInput(input)
        videoInput = input

        // Configure device format
        try await configureFormat(device: device, resolution: resolution, framerate: framerate)

        // Create video output
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: outputQueue)

        guard session.canAddOutput(output) else {
            throw CaptureError.cannotAddOutput
        }
        session.addOutput(output)
        videoOutput = output

        // Configure color space (Rec.709 Full) and orientation
        if let connection = output.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off  // For lowest latency
            }

            // Lock video orientation to landscape
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .landscapeRight
            }
        }

        captureSession = session
        // commitConfiguration() called via defer

        // Restart session if it was running before reconfiguration
        if wasRunning {
            session.startRunning()
            print("✅ Restarted capture session after reconfiguration")
        }
    }

    private func configureFormat(device: AVCaptureDevice, resolution: String, framerate: Int)
        async throws
    {
        let dimensions = try parseResolution(resolution)

        // Find matching format
        guard
            let format = findFormat(
                for: device, width: Int(dimensions.width), height: Int(dimensions.height),
                framerate: framerate)
        else {
            throw CaptureError.formatNotSupported
        }

        try device.lockForConfiguration()
        device.activeFormat = format

        // Set frame rate
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(framerate))
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration

        // Attach color space metadata (Rec.709 Full)
        // Note: This is handled at the sample buffer level in the output delegate

        device.unlockForConfiguration()

        print("✅ Configured format: \(format.formatDescription)")
    }

    private func findFormat(for device: AVCaptureDevice, width: Int, height: Int, framerate: Int)
        -> AVCaptureDevice.Format?
    {
        return device.formats.first { format in
            let description = format.formatDescription
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)

            guard dimensions.width == width && dimensions.height == height else {
                return false
            }

            // Check if framerate is supported
            let ranges = format.videoSupportedFrameRateRanges
            return ranges.contains { range in
                Double(framerate) >= range.minFrameRate && Double(framerate) <= range.maxFrameRate
            }
        }
    }

    // MARK: - Capture Control

    func startCapture(frameCallback: @escaping (CMSampleBuffer) -> Void) async throws {
        guard let session = captureSession else {
            throw CaptureError.sessionNotConfigured
        }

        self.frameCallback = frameCallback

        // Start session if not already running (for preview)
        if !session.isRunning {
            session.startRunning()
            print("▶️ Capture session started")
        } else {
            print("▶️ Frame callback attached (session already running for preview)")
        }
    }

    func stopCapture() async {
        // Only clear the frame callback, keep session running for preview
        frameCallback = nil
        print("⏹ Frame callback cleared (session still running for preview)")
    }

    // MARK: - Camera Settings

    func updateSettings(_ settings: CameraSettingsRequest) async throws {
        guard let device = videoDevice else {
            throw CaptureError.deviceNotAvailable
        }

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        // White balance
        if let wbMode = settings.wbMode {
            switch wbMode {
            case .auto:
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                    print("✅ White balance set to auto")
                }
            case .manual:
                if device.isWhiteBalanceModeSupported(.locked),
                    let kelvin = settings.wbKelvin
                {
                    let clampedKelvin = min(max(kelvin, uiMinKelvin), uiMaxKelvin)
                    let tint = settings.wbTint ?? 0.0
                    let appleKelvin = mapUIToAppleKelvin(clampedKelvin)

                    // Use official Apple API to convert temperature/tint to gains
                    let tempTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                        temperature: appleKelvin,
                        tint: Float(tint)
                    )
                    var gains = device.deviceWhiteBalanceGains(for: tempTint)

                    // Clamp to device range
                    gains = clampedGains(gains, for: device)

                    device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)

                    // Debug round-trip to verify applied values
                    let rt = device.temperatureAndTintValues(for: gains)
                    let uiK = mapAppleToUIKelvin(rt.temperature)
                    print("✅ WB locked UI \(uiK)K (apple \(Int(rt.temperature))K) tint \(String(format: "%.1f", rt.tint)) | gains R=\(String(format: "%.3f", gains.redGain)) G=\(String(format: "%.3f", gains.greenGain)) B=\(String(format: "%.3f", gains.blueGain))")
                }
            }
        }

        // ISO
        if let iso = settings.iso {
            if device.isExposureModeSupported(.custom) {
                let clampedISO = min(
                    max(Float(iso), device.activeFormat.minISO), device.activeFormat.maxISO)
                let currentDuration = device.exposureDuration
                device.setExposureModeCustom(
                    duration: currentDuration, iso: clampedISO, completionHandler: nil)
            }
        }

        // Shutter speed
        if let shutterS = settings.shutterS {
            if device.isExposureModeSupported(.custom) {
                let minD = device.activeFormat.minExposureDuration
                let maxD = device.activeFormat.maxExposureDuration
                var duration = CMTime(seconds: shutterS, preferredTimescale: 1_000_000)

                // Clamp duration to device-supported range
                if duration < minD { duration = minD }
                if duration > maxD { duration = maxD }

                let currentISO = device.iso
                device.setExposureModeCustom(
                    duration: duration, iso: currentISO, completionHandler: nil)
            }
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

        // Zoom
        if let zoomFactor = settings.zoomFactor {
            let clampedZoom = min(max(zoomFactor, 1.0), device.activeFormat.videoMaxZoomFactor)
            device.videoZoomFactor = clampedZoom
        }

        print("✅ Camera settings updated")
    }

    /// Measures white balance by enabling auto mode, waiting for convergence, then returning the measured values
    /// This is like "one-shot AWB" on professional cameras
    func measureWhiteBalance() async throws -> (kelvin: Int, tint: Double) {
        guard let device = videoDevice else {
            throw CaptureError.deviceNotAvailable
        }

        print("📸 Measuring white balance (auto mode for 2 seconds)...")

        // Enable auto white balance
        try device.lockForConfiguration()
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        } else {
            device.unlockForConfiguration()
            throw CaptureError.whiteBalanceNotSupported
        }
        device.unlockForConfiguration()

        // Wait for white balance to converge (typically 1-2 seconds)
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Read the converged gains
        let gains = device.deviceWhiteBalanceGains

        // Convert gains back to temperature and tint using Apple's API
        let tempTint = device.temperatureAndTintValues(for: gains)

        // Map from Apple's scene illumination temperature to UI convention
        let uiKelvin = mapAppleToUIKelvin(tempTint.temperature)

        print("📊 Measured WB gains: R=\(String(format: "%.3f", gains.redGain)) G=\(String(format: "%.3f", gains.greenGain)) B=\(String(format: "%.3f", gains.blueGain))")
        print("✅ Measured white balance: UI \(uiKelvin)K (apple \(Int(tempTint.temperature))K), tint: \(String(format: "%.1f", tempTint.tint))")

        return (kelvin: uiKelvin, tint: Double(tempTint.tint))
    }

    // MARK: - Capabilities

    func getCapabilities() -> [Capability] {
        guard let device = videoDevice else {
            return []
        }

        var capabilities: [Capability] = []
        let commonResolutions = [
            (1280, 720, "1280x720"),
            (1920, 1080, "1920x1080"),
            (3840, 2160, "3840x2160"),
        ]

        for (width, height, resString) in commonResolutions {
            let supportedFPS = getAvailableFramerates(for: device, width: width, height: height)

            if !supportedFPS.isEmpty {
                capabilities.append(
                    Capability(
                        resolution: resString,
                        fps: supportedFPS,
                        codec: ["h264", "hevc"],
                        lens: "wide",
                        maxZoom: Double(device.activeFormat.videoMaxZoomFactor)
                    ))
            }
        }

        return capabilities
    }

    private func getAvailableFramerates(for device: AVCaptureDevice, width: Int, height: Int)
        -> [Int]
    {
        var framerates: Set<Int> = []

        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width == width && dimensions.height == height else {
                continue
            }

            for range in format.videoSupportedFrameRateRanges {
                // Common framerates: 24, 25, 30, 60
                let commonRates = [24, 25, 30, 60]
                for rate in commonRates {
                    if Double(rate) >= range.minFrameRate && Double(rate) <= range.maxFrameRate {
                        framerates.insert(rate)
                    }
                }
            }
        }

        return Array(framerates).sorted()
    }

    // MARK: - Helpers

    private func parseResolution(_ resolution: String) throws -> (width: Int32, height: Int32) {
        let components = resolution.split(separator: "x").compactMap { Int32($0) }
        guard components.count == 2 else {
            throw CaptureError.invalidResolution
        }
        return (width: components[0], height: components[1])
    }

    // MARK: - White Balance Helpers

    private let uiMinKelvin = 2000
    private let uiMaxKelvin = 10000

    /// Maps UI Kelvin (higher = cooler) to Apple's scene illumination Kelvin
    private func mapUIToAppleKelvin(_ uiKelvin: Int) -> Float {
        // UI expectation: higher K = cooler/blue
        // Apple API: represents scene illumination temperature (opposite)
        // Formula: AppleKelvin = (min + max) - UIKelvin
        let inverted = uiMinKelvin + uiMaxKelvin - uiKelvin
        return Float(min(max(inverted, uiMinKelvin), uiMaxKelvin))
    }

    /// Maps Apple's scene illumination Kelvin to UI Kelvin (higher = cooler)
    private func mapAppleToUIKelvin(_ appleKelvin: Float) -> Int {
        let inverted = uiMinKelvin + uiMaxKelvin - Int(appleKelvin)
        return min(max(inverted, uiMinKelvin), uiMaxKelvin)
    }

    // Clamp helper to keep gains in device-safe range
    private func clampedGains(_ gains: AVCaptureDevice.WhiteBalanceGains, for device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        var g = gains
        let maxG = device.maxWhiteBalanceGain
        g.redGain   = max(1.0, min(g.redGain,   maxG))   // clamp R
        g.greenGain = max(1.0, min(g.greenGain, maxG))   // clamp G
        g.blueGain  = max(1.0, min(g.blueGain,  maxG))   // clamp B
        return g
    }

    // MARK: - Color Space Attachment

    nonisolated private func attachColorSpaceMetadata(to sampleBuffer: CMSampleBuffer) {
        // Attach Rec.709 Full Range color space metadata
        // Note: CVBufferSetAttachment is thread-safe and doesn't require actor isolation
        guard let colorSpace = CGColorSpace(name: CGColorSpace.itur_709) else {
            return
        }

        let attachments: [String: Any] = [
            kCVImageBufferColorPrimariesKey as String: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey as String: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey as String: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferCGColorSpaceKey as String: colorSpace
        ]

        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            for (key, value) in attachments {
                CVBufferSetAttachment(
                    pixelBuffer, key as CFString, value as CFTypeRef, .shouldPropagate)
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Attach color space metadata to ensure Rec.709 Full (synchronous, thread-safe)
        attachColorSpaceMetadata(to: sampleBuffer)

        // Forward to callback (access via Task to respect actor isolation)
        Task {
            if let callback = await frameCallback {
                callback(sampleBuffer)
            }
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
