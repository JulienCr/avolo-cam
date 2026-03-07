//
//  AppCoordinator+NetworkRequestHandler.swift
//  AvoCam
//
//  NetworkRequestHandler protocol conformance for AppCoordinator
//

import Foundation

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
