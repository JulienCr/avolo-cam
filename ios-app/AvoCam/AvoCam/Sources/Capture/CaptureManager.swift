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
           currentFramerate == framerate {
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
        session.sessionPreset = .inputPriority // We'll manually set format

        // Remove existing inputs/outputs if reconfiguring
        if captureSession != nil {
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
        }

        // Get video device (default wide camera)
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
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
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
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
                connection.preferredVideoStabilizationMode = .off // For lowest latency
            }

            // Lock video orientation to landscape
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .landscapeRight
            }
        }

        captureSession = session

        // Restart session if it was running before reconfiguration
        if wasRunning {
            session.startRunning()
            print("✅ Restarted capture session after reconfiguration")
        }
    }

    private func configureFormat(device: AVCaptureDevice, resolution: String, framerate: Int) async throws {
        let dimensions = try parseResolution(resolution)

        // Find matching format
        guard let format = findFormat(for: device, width: Int(dimensions.width), height: Int(dimensions.height), framerate: framerate) else {
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

    private func findFormat(for device: AVCaptureDevice, width: Int, height: Int, framerate: Int) -> AVCaptureDevice.Format? {
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
                   let kelvin = settings.wbKelvin {
                    // Validate Kelvin range (2000-10000K is reasonable for video)
                    let clampedKelvin = min(max(kelvin, 2000), 10000)

                    if clampedKelvin != kelvin {
                        print("⚠️ White balance Kelvin \(kelvin)K out of range, clamped to \(clampedKelvin)K")
                    }

                    // Get tint value (defaults to 0 if not provided)
                    let tint = settings.wbTint ?? 0.0

                    // Convert to gains and validate
                    let gains = whiteBalanceGains(
                        forTemperature: Float(clampedKelvin),
                        tint: Float(tint),
                        device: device
                    )

                    // Double-check gains are valid before applying
                    if validateGains(gains, device: device) {
                        device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                        print("✅ White balance set to \(clampedKelvin)K, tint: \(tint)")
                    } else {
                        print("❌ Invalid white balance gains after validation, skipping")
                        throw CaptureError.invalidWhiteBalanceGains
                    }
                }
            }
        }

        // ISO
        if let iso = settings.iso {
            if device.isExposureModeSupported(.custom) {
                let clampedISO = min(max(Float(iso), device.activeFormat.minISO), device.activeFormat.maxISO)
                let currentDuration = device.exposureDuration
                device.setExposureModeCustom(duration: currentDuration, iso: clampedISO, completionHandler: nil)
            }
        }

        // Shutter speed
        if let shutterS = settings.shutterS {
            if device.isExposureModeSupported(.custom) {
                let duration = CMTime(seconds: shutterS, preferredTimescale: 1000000)
                let currentISO = device.iso
                device.setExposureModeCustom(duration: duration, iso: currentISO, completionHandler: nil)
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

    // MARK: - Capabilities

    func getCapabilities() -> [Capability] {
        guard let device = videoDevice else {
            return []
        }

        var capabilities: [Capability] = []
        let commonResolutions = [
            (1280, 720, "1280x720"),
            (1920, 1080, "1920x1080"),
            (3840, 2160, "3840x2160")
        ]

        for (width, height, resString) in commonResolutions {
            let supportedFPS = getAvailableFramerates(for: device, width: width, height: height)

            if !supportedFPS.isEmpty {
                capabilities.append(Capability(
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

    private func getAvailableFramerates(for device: AVCaptureDevice, width: Int, height: Int) -> [Int] {
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

    private func whiteBalanceGains(forTemperature temperature: Float, tint: Float, device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        // Convert Kelvin temperature to RGB gains for camera white balance
        // Based on Tanner Helland's algorithm, adapted for camera correction

        let temp = temperature / 100.0
        var red: Float
        var green: Float
        var blue: Float

        // Calculate RGB color of the light source at this temperature
        // Calculate Red
        if temp <= 66 {
            red = 255
        } else {
            red = temp - 60
            red = 329.698727446 * pow(red, -0.1332047592)
            red = min(max(red, 0), 255)
        }

        // Calculate Green
        if temp <= 66 {
            green = temp
            green = 99.4708025861 * log(green) - 161.1195681661
        } else {
            green = temp - 60
            green = 288.1221695283 * pow(green, -0.0755148492)
        }
        green = min(max(green, 0), 255)

        // Calculate Blue
        if temp >= 66 {
            blue = 255
        } else if temp <= 19 {
            blue = 0
        } else {
            blue = temp - 10
            blue = 138.5177312231 * log(blue) - 305.0447927307
            blue = min(max(blue, 0), 255)
        }

        // Normalize to 0-1 range
        red = red / 255.0
        green = green / 255.0
        blue = blue / 255.0

        // For white balance correction, we need the RECIPROCAL
        // (to neutralize the color cast of the light source)
        // Find max value to use as reference
        let maxValue = max(red, max(green, blue))
        if maxValue > 0 {
            // Take reciprocal relative to max
            red = maxValue / red
            green = maxValue / green
            blue = maxValue / blue
        }

        // Now normalize so the minimum gain is 1.0
        let minGain = min(red, min(green, blue))
        if minGain > 0 {
            red = red / minGain
            green = green / minGain
            blue = blue / minGain
        }

        // Apply tint adjustment (green/magenta axis)
        // Positive tint = add magenta (reduce green)
        // Negative tint = add green (increase green)
        let tintAmount = abs(tint) * 0.01 // Scale to ~1% per unit
        if tint > 0 {
            // Add magenta by reducing green
            green = green * (1.0 + tintAmount)
        } else if tint < 0 {
            // Add green by increasing it
            green = green * (1.0 - tintAmount)
        }

        // Clamp gains to valid range [1.0, maxWhiteBalanceGain]
        let maxGain = device.maxWhiteBalanceGain
        red = min(max(red, 1.0), maxGain)
        green = min(max(green, 1.0), maxGain)
        blue = min(max(blue, 1.0), maxGain)

        print("📊 WB Gains for \(Int(temperature))K, tint \(tint): R=\(String(format: "%.3f", red)) G=\(String(format: "%.3f", green)) B=\(String(format: "%.3f", blue))")

        return AVCaptureDevice.WhiteBalanceGains(
            redGain: red,
            greenGain: green,
            blueGain: blue
        )
    }

    private func validateGains(_ gains: AVCaptureDevice.WhiteBalanceGains, device: AVCaptureDevice) -> Bool {
        let maxGain = device.maxWhiteBalanceGain

        // Check each gain is in valid range
        let isValid = gains.redGain >= 1.0 && gains.redGain <= maxGain &&
                      gains.greenGain >= 1.0 && gains.greenGain <= maxGain &&
                      gains.blueGain >= 1.0 && gains.blueGain <= maxGain

        if !isValid {
            print("❌ Invalid gains - R:\(gains.redGain) G:\(gains.greenGain) B:\(gains.blueGain) (max: \(maxGain))")
        }

        return isValid
    }

    // MARK: - Color Space Attachment

    private func attachColorSpaceMetadata(to sampleBuffer: CMSampleBuffer) {
        // Attach Rec.709 Full Range color space metadata
        let attachments: [String: Any] = [
            kCVImageBufferColorPrimariesKey as String: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey as String: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey as String: kCVImageBufferTransferFunction_ITU_R_709_2
        ]

        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            for (key, value) in attachments {
                CVBufferSetAttachment(pixelBuffer, key as CFString, value as CFTypeRef, .shouldPropagate)
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
        // Attach color space metadata to ensure Rec.709 Full
        Task {
            await attachColorSpaceMetadata(to: sampleBuffer)

            // Forward to callback
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
        }
    }
}
