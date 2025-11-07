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

    // Serial queue for all session mutations (beginConfiguration/commitConfiguration, add/remove input/output, start/stop)
    private let sessionQueue = DispatchQueue(label: "com.avocam.capture.session", qos: .userInteractive)
    private let outputQueue = DispatchQueue(label: "com.avocam.capture.output")

    private var frameCallback: ((CMSampleBuffer) -> Void)?
    private var currentResolution: String?
    private var currentFramerate: Int?

    // Camera position and lens tracking
    private var currentCameraPosition: AVCaptureDevice.Position = .back
    private var currentLens: String = "wide"  // "wide", "ultra_wide", "telephoto"
    private var isUsingVirtualDevice: Bool = false  // Track if we're using a multi-camera virtual device

    // Exposure state tracking
    private var currentISOMode: ExposureMode = .auto
    private var currentISO: Float = 0
    private var currentShutterMode: ExposureMode = .auto
    private var currentShutterS: Double = 0

    // MARK: - Public Access

    nonisolated func getSession() -> AVCaptureSession? {
        // AVCaptureSession is thread-safe for reading to provide to preview layer
        return captureSession
    }

    // MARK: - Configuration

    func configure(resolution: String, framerate: Int) async throws {
        print("📷 Configuring capture: \(resolution) @ \(framerate)fps, position: \(currentCameraPosition == .back ? "back" : "front"), lens: \(currentLens)")

        // Check if already configured with same settings
        // NOTE: We DO NOT check camera position or lens here because those are already
        // updated in updateSettings() before calling configure(). If we're here, it means
        // something changed and we need to reconfigure.
        // The old logic would skip reconfiguration when switching cameras with same resolution/fps.

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
                    let wasRunning = self.captureSession?.isRunning ?? false
                    if wasRunning {
                        self.captureSession?.stopRunning()
                    }

                    // Setup capture session (reuse existing or create new)
                    let session = self.captureSession ?? AVCaptureSession()
                    session.sessionPreset = .inputPriority  // We'll manually set format

                    // Begin atomic configuration
                    session.beginConfiguration()

                    // Remove existing inputs/outputs if reconfiguring
                    if self.captureSession != nil {
                        session.inputs.forEach { session.removeInput($0) }
                        session.outputs.forEach { session.removeOutput($0) }
                    }

                    // Discover device using prioritized list (prefer virtual devices for back camera)
                    let deviceTypes = self.prioritizedDeviceTypes(for: self.currentCameraPosition)
                    print("🔍 Looking for device: position=\(self.currentCameraPosition == .back ? "back" : "front"), lens=\(self.currentLens)")
                    print("   Prioritized device types: \(deviceTypes.map { $0.rawValue })")

                    let discovery = AVCaptureDevice.DiscoverySession(
                        deviceTypes: deviceTypes,
                        mediaType: .video,
                        position: self.currentCameraPosition
                    )

                    guard let device = discovery.devices.first else {
                        session.commitConfiguration()
                        print("❌ No camera device available!")
                        continuation.resume(throwing: CaptureError.deviceNotAvailable)
                        return
                    }

                    print("✅ Found camera device: \(device.localizedName)")

                    // Check if using virtual device (can switch lenses via zoom)
                    self.isUsingVirtualDevice = [
                        AVCaptureDevice.DeviceType.builtInTripleCamera,
                        .builtInDualWideCamera,
                        .builtInDualCamera
                    ].contains(device.deviceType)

                    if self.isUsingVirtualDevice {
                        print("✅ Using virtual device - lens switching via zoom")
                        print("   Switch factors: \(device.virtualDeviceSwitchOverVideoZoomFactors)")
                    }

                    self.videoDevice = device

                    // Create device input
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else {
                        session.commitConfiguration()
                        throw CaptureError.cannotAddInput
                    }
                    session.addInput(input)
                    self.videoInput = input

                    // Configure device format (must be sync on sessionQueue)
                    try self.configureFormatSync(device: device, resolution: resolution, framerate: framerate)

                    // Create video output
                    let output = AVCaptureVideoDataOutput()
                    output.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String:
                            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    ]
                    output.alwaysDiscardsLateVideoFrames = true
                    output.setSampleBufferDelegate(self, queue: self.outputQueue)

                    guard session.canAddOutput(output) else {
                        session.commitConfiguration()
                        throw CaptureError.cannotAddOutput
                    }
                    session.addOutput(output)
                    self.videoOutput = output

                    // Configure connection (orientation, stabilization)
                    self.configureConnection(output.connection(with: .video))

                    // Commit configuration
                    session.commitConfiguration()

                    self.captureSession = session

                    // Apply lens zoom if using virtual device
                    if self.isUsingVirtualDevice, let zoomFactor = self.zoomFactorForLens(self.currentLens, device: device) {
                        try device.lockForConfiguration()
                        device.videoZoomFactor = zoomFactor
                        device.unlockForConfiguration()
                        print("✅ Applied zoom factor \(zoomFactor) for lens '\(self.currentLens)'")
                    }

                    // Restart session if it was running before reconfiguration
                    if wasRunning {
                        session.startRunning()
                        print("✅ Restarted capture session after reconfiguration")
                    }

                    continuation.resume()
                } catch {
                    print("❌ Configuration failed: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Synchronous format configuration for use on sessionQueue
    private func configureFormatSync(device: AVCaptureDevice, resolution: String, framerate: Int) throws {
        let dimensions = try parseResolution(resolution)

        // Find matching format using best-fit logic
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

        device.unlockForConfiguration()

        print("✅ Configured format: \(format.formatDescription)")
    }

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
    }

    /// Best-fit format chooser: tolerant to per-lens constraints
    /// 1. Filter by resolution (exact > nearest larger > nearest smaller)
    /// 2. Within those, pick format supporting requested fps (or closest not exceeding maxFrameRate)
    private func findFormat(for device: AVCaptureDevice, width: Int, height: Int, framerate: Int)
        -> AVCaptureDevice.Format?
    {
        let targetPixels = width * height

        // Separate formats by resolution match type
        var exactMatch: [AVCaptureDevice.Format] = []
        var largerMatch: [AVCaptureDevice.Format] = []
        var smallerMatch: [AVCaptureDevice.Format] = []

        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let w = Int(dims.width)
            let h = Int(dims.height)

            if w == width && h == height {
                exactMatch.append(format)
            } else {
                let pixels = w * h
                if pixels > targetPixels {
                    largerMatch.append(format)
                } else {
                    smallerMatch.append(format)
                }
            }
        }

        // Sort larger/smaller by distance from target
        largerMatch.sort { abs($0.formatPixelCount - targetPixels) < abs($1.formatPixelCount - targetPixels) }
        smallerMatch.sort { abs($0.formatPixelCount - targetPixels) < abs($1.formatPixelCount - targetPixels) }

        // Try exact, then larger, then smaller
        let candidates = exactMatch + largerMatch + smallerMatch

        // Within candidates, pick the one that best matches framerate
        for format in candidates {
            let ranges = format.videoSupportedFrameRateRanges
            for range in ranges {
                if Double(framerate) >= range.minFrameRate && Double(framerate) <= range.maxFrameRate {
                    return format
                }
            }
        }

        // If no exact fps match, pick first candidate with closest fps not exceeding maxFrameRate
        return candidates.first { format in
            format.videoSupportedFrameRateRanges.contains { range in
                range.maxFrameRate >= Double(framerate) * 0.9  // 10% tolerance
            }
        } ?? candidates.first  // Last resort: any format
    }

    // MARK: - Capture Control

    func startCapture(frameCallback: @escaping (CMSampleBuffer) -> Void) async throws {
        guard let session = captureSession else {
            throw CaptureError.sessionNotConfigured
        }

        self.frameCallback = frameCallback

        // Start session on sessionQueue if not already running
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                if !session.isRunning {
                    session.startRunning()
                    print("▶️ Capture session started")
                } else {
                    print("▶️ Frame callback attached (session already running for preview)")
                }
                continuation.resume()
            }
        }
    }

    func stopCapture() async {
        // Only clear the frame callback, keep session running for preview
        frameCallback = nil
        print("⏹ Frame callback cleared (session still running for preview)")
    }

    // MARK: - Camera Settings

    func updateSettings(_ settings: CameraSettingsRequest) async throws {
        print("🔧 CaptureManager.updateSettings called")
        print("   Camera position request: \(settings.cameraPosition ?? "nil")")
        print("   Lens request: \(settings.lens ?? "nil")")
        print("   Current position: \(currentCameraPosition == .back ? "back" : "front")")
        print("   Current lens: \(currentLens)")
        print("   Current resolution: \(currentResolution ?? "nil")")
        print("   Current framerate: \(currentFramerate?.description ?? "nil")")

        // Handle camera position change (requires session reconfiguration)
        var needsReconfigure = false

        if let cameraPosition = settings.cameraPosition {
            let newPosition: AVCaptureDevice.Position = (cameraPosition == "front") ? .front : .back
            if newPosition != currentCameraPosition {
                currentCameraPosition = newPosition
                needsReconfigure = true
                print("📷 Switching to \(cameraPosition) camera - reconfigure needed")
            } else {
                print("📷 Camera position unchanged (\(cameraPosition))")
            }
        }

        // Handle lens change
        if let lens = settings.lens {
            // Guard: front camera only supports wide
            if currentCameraPosition == .front && lens != "wide" {
                print("⚠️ Front camera only supports 'wide' lens, ignoring request for '\(lens)'")
            } else if lens != currentLens {
                // Check if we can switch via zoom (virtual device) or need reconfiguration
                if isUsingVirtualDevice {
                    // Switch lens via zoom factor without reconfiguration
                    currentLens = lens
                    print("📷 Switching to \(lens) lens via zoom")
                } else {
                    // Non-virtual device, need reconfiguration
                    currentLens = lens
                    needsReconfigure = true
                    print("📷 Switching to \(lens) lens - reconfigure needed")
                }
            } else {
                print("📷 Lens unchanged (\(lens))")
            }
        }

        // Reconfigure session if camera position changed or non-virtual lens switch
        if needsReconfigure {
            let resolution = currentResolution ?? "1920x1080"  // Default to 1080p
            let framerate = currentFramerate ?? 30  // Default to 30fps

            print("🔄 Reconfiguring capture session with \(resolution) @ \(framerate)fps")
            try await configure(resolution: resolution, framerate: framerate)
            print("✅ Camera/lens reconfiguration complete")
            return
        }

        guard let device = videoDevice else {
            print("❌ No video device available")
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
                    device.isLockingWhiteBalanceWithCustomDeviceGainsSupported,
                    let sceneCCT_K = settings.wbKelvin  // API sends physical scene CCT
                {
                    // Clamp to reasonable range for video
                    let clampedCCT = min(max(sceneCCT_K, 2000), 10000)
                    let tint = settings.wbTint ?? 0.0

                    // Use official Apple API to convert temperature/tint to gains
                    // Apple expects physical scene illumination temperature (no inversion needed!)
                    let tempTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                        temperature: Float(clampedCCT),
                        tint: Float(tint)
                    )
                    var gains = device.deviceWhiteBalanceGains(for: tempTint)

                    // Clamp to device range
                    gains = clampedGains(gains, for: device)

                    device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)

                    // Debug round-trip to verify applied values
                    let rt = device.temperatureAndTintValues(for: gains)
                    print("✅ WB locked to \(clampedCCT)K (Scene CCT), tint \(String(format: "%.1f", tint))")
                    print("   Applied: SceneCCT \(Int(rt.temperature))K, tint \(String(format: "%.1f", rt.tint))")
                    print("   Gains: R=\(String(format: "%.3f", gains.redGain)) G=\(String(format: "%.3f", gains.greenGain)) B=\(String(format: "%.3f", gains.blueGain))")
                } else if !device.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                    print("⚠️ Device does not support locking white balance with custom gains")
                }
            }
        }

        // Handle exposure (ISO and Shutter) independently
        var needsExposureUpdate = false
        var targetISO: Float = currentISO
        var targetDuration: CMTime = device.exposureDuration

        // Update ISO mode/value if specified
        if let isoMode = settings.isoMode {
            currentISOMode = isoMode
            needsExposureUpdate = true
        }
        if let iso = settings.iso, currentISOMode == .manual {
            currentISO = Float(iso)
            targetISO = min(max(currentISO, device.activeFormat.minISO), device.activeFormat.maxISO)
            needsExposureUpdate = true
        }

        // Update shutter mode/value if specified
        if let shutterMode = settings.shutterMode {
            currentShutterMode = shutterMode
            needsExposureUpdate = true
        }
        if let shutterS = settings.shutterS, currentShutterMode == .manual {
            currentShutterS = shutterS
            let minD = device.activeFormat.minExposureDuration
            let maxD = device.activeFormat.maxExposureDuration
            var duration = CMTime(seconds: shutterS, preferredTimescale: 1_000_000)

            // Clamp duration to device-supported range
            if duration < minD { duration = minD }
            if duration > maxD { duration = maxD }

            targetDuration = duration
            needsExposureUpdate = true
        }

        // Apply exposure settings based on mode combination
        if needsExposureUpdate {
            applyExposureSettings(
                device: device,
                isoMode: currentISOMode,
                targetISO: targetISO,
                shutterMode: currentShutterMode,
                targetDuration: targetDuration
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

        // Zoom: handle both explicit zoom factor and lens-based zoom (virtual devices)
        if let zoomFactor = settings.zoomFactor {
            // Explicit zoom factor requested
            let clampedZoom = min(max(zoomFactor, device.minAvailableVideoZoomFactor), device.activeFormat.videoMaxZoomFactor)
            device.videoZoomFactor = clampedZoom

            // Update currentLens to reflect which lens is now active (for virtual devices)
            if isUsingVirtualDevice {
                let detectedLens = lensForZoomFactor(clampedZoom, device: device)
                if detectedLens != currentLens {
                    currentLens = detectedLens
                    print("✅ Applied zoom factor \(clampedZoom), auto-detected lens: '\(currentLens)'")
                } else {
                    print("✅ Applied zoom factor \(clampedZoom) (lens: '\(currentLens)')")
                }
            } else {
                print("✅ Applied zoom factor \(clampedZoom)")
            }
        } else if settings.lens != nil, isUsingVirtualDevice, let lensZoom = zoomFactorForLens(currentLens, device: device) {
            // Lens changed, apply appropriate zoom for virtual device
            let clampedZoom = min(max(lensZoom, device.minAvailableVideoZoomFactor), device.activeFormat.videoMaxZoomFactor)
            device.videoZoomFactor = clampedZoom
            print("✅ Applied lens-based zoom factor: \(clampedZoom) for lens '\(currentLens)'")
        }

        print("✅ Camera settings updated")
    }

    // MARK: - Exposure Control

    private func applyExposureSettings(
        device: AVCaptureDevice,
        isoMode: ExposureMode,
        targetISO: Float,
        shutterMode: ExposureMode,
        targetDuration: CMTime
    ) {
        switch (isoMode, shutterMode) {
        case (.auto, .auto):
            // Both auto - use continuous auto exposure
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
                print("✅ Exposure: Both auto (continuous)")
            }

        case (.manual, .auto):
            // Manual ISO, auto shutter - use custom with calculated shutter
            if device.isExposureModeSupported(.custom) {
                // Calculate shutter speed based on framerate (180° shutter angle)
                let framerate = currentFramerate ?? 30
                let autoShutter = CMTime(value: 1, timescale: CMTimeScale(framerate * 2))
                device.setExposureModeCustom(
                    duration: autoShutter, iso: targetISO, completionHandler: nil)
                print("✅ Exposure: Manual ISO (\(Int(targetISO))), auto shutter (1/\(framerate * 2))")
            }

        case (.auto, .manual):
            // Auto ISO, manual shutter - use custom with device's current ISO
            if device.isExposureModeSupported(.custom) {
                let currentDeviceISO = device.iso
                device.setExposureModeCustom(
                    duration: targetDuration, iso: currentDeviceISO, completionHandler: nil)
                let shutterDisplay = targetDuration.seconds >= 1
                    ? String(format: "%.3fs", targetDuration.seconds)
                    : "1/\(Int(1.0 / targetDuration.seconds))"
                print("✅ Exposure: Auto ISO (\(Int(currentDeviceISO))), manual shutter (\(shutterDisplay))")
            }

        case (.manual, .manual):
            // Both manual - use custom with both specified values
            if device.isExposureModeSupported(.custom) {
                device.setExposureModeCustom(
                    duration: targetDuration, iso: targetISO, completionHandler: nil)
                let shutterDisplay = targetDuration.seconds >= 1
                    ? String(format: "%.3fs", targetDuration.seconds)
                    : "1/\(Int(1.0 / targetDuration.seconds))"
                print("✅ Exposure: Manual ISO (\(Int(targetISO))), manual shutter (\(shutterDisplay))")
            }
        }
    }

    /// Measures white balance by enabling auto mode, waiting for convergence, then returning the measured values
    /// Returns physical scene CCT (SceneCCT_K) - NOT UI Kelvin
    /// This is like "one-shot AWB" on professional cameras
    func measureWhiteBalance() async throws -> (sceneCCT_K: Int, tint: Double) {
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
        // This returns the PHYSICAL scene illumination temperature (SceneCCT_K)
        let tempTint = device.temperatureAndTintValues(for: gains)

        let sceneCCT_K = Int(tempTint.temperature)
        let tint = Double(tempTint.tint)

        print("📊 Measured WB gains: R=\(String(format: "%.3f", gains.redGain)) G=\(String(format: "%.3f", gains.greenGain)) B=\(String(format: "%.3f", gains.blueGain))")
        print("✅ Measured WB: SceneCCT_K = \(sceneCCT_K)K (physical scene illumination), Tint = \(String(format: "%.1f", tint))")

        // Return physical scene CCT
        return (sceneCCT_K: sceneCCT_K, tint: tint)
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

        // Determine available lenses based on camera position
        let availableLenses: [String]
        if currentCameraPosition == .front {
            // Front camera: only wide available
            availableLenses = ["wide"]
        } else if isUsingVirtualDevice {
            // Back camera with virtual device: all lenses via zoom
            availableLenses = ["wide", "ultra_wide", "telephoto"]
        } else {
            // Back camera without virtual device: only current lens
            availableLenses = [currentLens]
        }

        for (width, height, resString) in commonResolutions {
            let supportedFPS = getAvailableFramerates(for: device, width: width, height: height)

            if !supportedFPS.isEmpty {
                for lens in availableLenses {
                    capabilities.append(
                        Capability(
                            resolution: resString,
                            fps: supportedFPS,
                            codec: ["h264", "hevc"],
                            lens: lens,
                            maxZoom: Double(device.activeFormat.videoMaxZoomFactor)
                        ))
                }
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

    // MARK: - Helper Functions

    /// Returns prioritized device types for discovery, preferring virtual devices for back camera
    private func prioritizedDeviceTypes(for position: AVCaptureDevice.Position) -> [AVCaptureDevice.DeviceType] {
        if position == .back {
            // Prefer virtual devices that can switch optics via zoom
            return [
                .builtInTripleCamera,
                .builtInDualWideCamera,
                .builtInDualCamera,
                .builtInWideAngleCamera,
                .builtInUltraWideCamera,
                .builtInTelephotoCamera
            ]
        } else {
            // Front camera: typically only wide available
            return [.builtInWideAngleCamera]
        }
    }

    /// Get zoom factors for lens switching on virtual devices
    /// Device zoom values: ultra-wide=1.0, wide=2.0, telephoto=10.0
    private func zoomFactorForLens(_ lens: String, device: AVCaptureDevice) -> CGFloat? {
        guard isUsingVirtualDevice else { return nil }

        // Device zoom factors (what AVFoundation actually uses)
        // Ultra-wide is at 1.0x, wide is at 2.0x (2x zoom from ultra-wide)
        let targetZoom: CGFloat
        switch lens {
        case "ultra_wide":
            targetZoom = 1.0   // Ultra-wide baseline
        case "telephoto":
            targetZoom = 10.0  // Telephoto (5x UI = 10x device)
        case "wide":
            fallthrough
        default:
            targetZoom = 2.0   // Wide (1x UI = 2x device)
        }

        // Clamp to device's available zoom range
        let clampedZoom = min(max(targetZoom, device.minAvailableVideoZoomFactor), device.activeFormat.videoMaxZoomFactor)
        return clampedZoom
    }

    /// Detects which lens is active based on the device zoom factor
    /// Device thresholds: 1.5 (between ultra-wide and wide), 6.0 (between wide and tele)
    private func lensForZoomFactor(_ zoomFactor: CGFloat, device: AVCaptureDevice) -> String {
        guard isUsingVirtualDevice else { return "wide" }

        // Detection based on device zoom values
        // ultra-wide=1.0, wide=2.0, telephoto=10.0
        // Thresholds: 1.5 (midpoint between 1.0 and 2.0), 6.0 (midpoint between 2.0 and 10.0)

        if zoomFactor < 1.5 {
            return "ultra_wide"  // < 1.5x device zoom
        } else if zoomFactor >= 6.0 {
            return "telephoto"   // >= 6.0x device zoom
        } else {
            return "wide"        // 1.5x - 6.0x device zoom
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

// MARK: - AVCaptureDevice.Format Extension

private extension AVCaptureDevice.Format {
    var formatPixelCount: Int {
        let dims = CMVideoFormatDescriptionGetDimensions(self.formatDescription)
        return Int(dims.width) * Int(dims.height)
    }
}
