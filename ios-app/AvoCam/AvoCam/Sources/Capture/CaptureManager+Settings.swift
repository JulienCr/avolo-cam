//
//  CaptureManager+Settings.swift
//  AvoCam
//
//  CaptureManager extension for camera settings adjustments
//

import AVFoundation
import CoreMedia

// MARK: - Camera Settings

extension CaptureManager {

    func updateSettings(_ settings: CameraSettingsRequest) async throws {
        print("🔧 CaptureManager.updateSettings called")
        print("   Camera position request: \(settings.cameraPosition ?? "nil")")
        print("   Lens request: \(settings.lens ?? "nil")")
        print("   WB mode: \(settings.wbMode?.rawValue ?? "nil"), kelvin: \(settings.wbKelvin?.description ?? "nil")")
        print("   ISO mode: \(settings.isoMode?.rawValue ?? "nil"), value: \(settings.iso?.description ?? "nil")")
        print("   Shutter mode: \(settings.shutterMode?.rawValue ?? "nil"), value: \(settings.shutterS?.description ?? "nil")")
        print("   Zoom factor: \(settings.zoomFactor?.description ?? "nil")")
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

        // Reconfigure session if camera position changed or lens switch
        if needsReconfigure {
            let resolution = currentResolution ?? "1920x1080"  // Default to 1080p
            let framerate = currentFramerate ?? 25  // Default to 25fps

            print("🔄 Reconfiguring capture session with \(resolution) @ \(framerate)fps")
            try await configure(resolution: resolution, framerate: framerate)
            print("✅ Camera/lens reconfiguration complete")
            // Continue to apply remaining settings after reconfiguration
        }

        guard let device = videoDevice else {
            print("❌ No video device available")
            throw CaptureError.deviceNotAvailable
        }

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        // White balance
        if let wbMode = settings.wbMode {
            print("🔧 Applying white balance mode: \(wbMode)")
            switch wbMode {
            case .auto:
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                    print("✅ White balance set to auto")
                }
            case .manual:
                print("🔍 WB checks: locked=\(device.isWhiteBalanceModeSupported(.locked)), customGains=\(device.isLockingWhiteBalanceWithCustomDeviceGainsSupported), hasKelvin=\(settings.wbKelvin != nil)")

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
                } else {
                    if !device.isWhiteBalanceModeSupported(.locked) {
                        print("❌ Device does not support locked white balance mode")
                    }
                    if !device.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                        print("❌ Device does not support locking white balance with custom gains")
                    }
                    if settings.wbKelvin == nil {
                        print("❌ No white balance kelvin value provided")
                    }
                }
            }
        }

        // Handle exposure (ISO and Shutter) independently
        var needsExposureUpdate = false
        var targetISO: Float = currentISO
        var targetDuration: CMTime = device.exposureDuration

        // Check if ISO mode/value changed
        if let isoMode = settings.isoMode {
            print("🔧 ISO mode change requested: \(isoMode)")
            currentISOMode = isoMode  // Update tracked mode
            needsExposureUpdate = true
        }
        if let iso = settings.iso, currentISOMode == .manual {
            print("🔧 ISO value change requested: \(iso)")
            currentISO = Float(iso)
            targetISO = min(max(currentISO, device.activeFormat.minISO), device.activeFormat.maxISO)
            needsExposureUpdate = true
        }

        // Check if shutter mode/value changed
        if let shutterMode = settings.shutterMode {
            print("🔧 Shutter mode change requested: \(shutterMode)")
            currentShutterMode = shutterMode  // Update tracked mode
            needsExposureUpdate = true
        }
        if let shutterS = settings.shutterS, currentShutterMode == .manual {
            print("🔧 Shutter speed change requested: \(shutterS)s")
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
            print("🔧 Applying exposure update: ISO=\(currentISOMode.rawValue)(\(Int(targetISO))), Shutter=\(currentShutterMode.rawValue)")
            applyExposureSettings(
                device: device,
                isoMode: currentISOMode,
                targetISO: targetISO,
                shutterMode: currentShutterMode,
                targetDuration: targetDuration
            )
        } else {
            print("🔧 No exposure update needed")
        }

        // Focus
        if let focusMode = settings.focusMode {
            currentFocusMode = focusMode
            switch focusMode {
            case .auto:
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                    currentFocusDistance = nil
                    print("✅ Focus mode set to continuous autofocus")
                }
            case .manual:
                if device.isFocusModeSupported(.locked) {
                    // If focus distance is provided, set it; otherwise just lock at current position
                    if let focusDistance = settings.focusDistance {
                        let clampedDistance = min(max(Float(focusDistance), 0.0), 1.0)
                        if device.isLockingFocusWithCustomLensPositionSupported {
                            device.setFocusModeLocked(lensPosition: clampedDistance) { _ in
                                print("✅ Focus locked at distance: \(clampedDistance) (0.0=near, 1.0=far)")
                            }
                            currentFocusDistance = Double(clampedDistance)
                        } else {
                            device.focusMode = .locked
                            currentFocusDistance = Double(device.lensPosition)
                            print("⚠️ Device doesn't support custom lens position, locked at current position")
                        }
                    } else {
                        device.focusMode = .locked
                        currentFocusDistance = Double(device.lensPosition)
                        print("✅ Focus mode locked at current position")
                    }
                }
            }
        } else if let focusDistance = settings.focusDistance {
            // Focus distance provided without mode change - update distance if in manual mode
            if device.focusMode == .locked {
                let clampedDistance = min(max(Float(focusDistance), 0.0), 1.0)
                if device.isLockingFocusWithCustomLensPositionSupported {
                    device.setFocusModeLocked(lensPosition: clampedDistance) { _ in
                        print("✅ Focus distance updated: \(clampedDistance)")
                    }
                    currentFocusDistance = Double(clampedDistance)
                }
            }
        }

        // Zoom: handle both explicit zoom factor and lens-based zoom
        // IMPORTANT: For physical cameras, lens parameter takes precedence over zoom_factor
        // When switching physical lenses, we reset to base zoom (1.0x on that lens)
        if settings.lens != nil && !isUsingVirtualDevice {
            // Physical lens switch - reset to base zoom for that lens
            let baseZoom: CGFloat = 1.0
            let clampedZoom = min(max(baseZoom, device.minAvailableVideoZoomFactor), device.activeFormat.videoMaxZoomFactor)
            device.videoZoomFactor = clampedZoom
            print("✅ Physical lens '\(currentLens)' at base zoom \(String(format: "%.1f", clampedZoom))x (no digital zoom)")
        } else if let zoomFactor = settings.zoomFactor {
            // Explicit zoom factor requested (for virtual devices or fine-tuning physical cameras)
            let clampedZoom = min(max(zoomFactor, device.minAvailableVideoZoomFactor), device.activeFormat.videoMaxZoomFactor)
            device.videoZoomFactor = clampedZoom

            // Update currentLens to reflect which lens is now active (for virtual devices)
            let uiZoom = clampedZoom / 2.0
            if isUsingVirtualDevice {
                let detectedLens = lensForZoomFactor(clampedZoom, device: device)
                if detectedLens != currentLens {
                    currentLens = detectedLens
                    print("✅ Applied zoom \(String(format: "%.1f", uiZoom))x UI (device: \(String(format: "%.1f", clampedZoom))x), auto-detected lens: '\(currentLens)'")
                } else {
                    print("✅ Applied zoom \(String(format: "%.1f", uiZoom))x UI (device: \(String(format: "%.1f", clampedZoom))x) (lens: '\(currentLens)')")
                }
            } else {
                print("✅ Applied zoom \(String(format: "%.1f", uiZoom))x UI (device: \(String(format: "%.1f", clampedZoom))x)")
            }
        } else if settings.lens != nil, isUsingVirtualDevice, let lensZoom = zoomFactorForLens(currentLens, device: device) {
            // Lens changed, apply appropriate zoom for virtual device
            let clampedZoom = min(max(lensZoom, device.minAvailableVideoZoomFactor), device.activeFormat.videoMaxZoomFactor)
            device.videoZoomFactor = clampedZoom
            let uiZoom = clampedZoom / 2.0
            print("✅ Applied lens-based zoom: \(String(format: "%.1f", uiZoom))x UI (device: \(String(format: "%.1f", clampedZoom))x) for lens '\(currentLens)'")
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
        print("🔍 applyExposureSettings: mode=(\(isoMode), \(shutterMode)), custom supported=\(device.isExposureModeSupported(.custom))")

        switch (isoMode, shutterMode) {
        case (.auto, .auto):
            // Both auto - use continuous auto exposure
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
                print("✅ Exposure: Both auto (continuous)")
            } else {
                print("❌ Device does not support continuous auto exposure")
            }

        case (.manual, .auto):
            // Manual ISO, auto shutter - use custom with calculated shutter
            if device.isExposureModeSupported(.custom) {
                // Calculate shutter speed based on framerate (180° shutter angle)
                let framerate = currentFramerate ?? 25
                let autoShutter = CMTime(value: 1, timescale: CMTimeScale(framerate * 2))
                device.setExposureModeCustom(
                    duration: autoShutter, iso: targetISO, completionHandler: nil)
                print("✅ Exposure: Manual ISO (\(Int(targetISO))), auto shutter (1/\(framerate * 2))")
            } else {
                print("❌ Device does not support custom exposure mode")
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
            } else {
                print("❌ Device does not support custom exposure mode")
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
            } else {
                print("❌ Device does not support custom exposure mode")
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
}
