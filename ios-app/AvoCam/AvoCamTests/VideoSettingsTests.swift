//
//  VideoSettingsTests.swift
//  AvoCamTests
//
//  Tests for video presets and settings
//

import XCTest
@testable import AvoCam

final class VideoSettingsTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - VideoPreset

    func testAllPresetsExist() {
        XCTAssertGreaterThanOrEqual(VideoPreset.allPresets.count, 9)
    }

    func testDefaultPresetIsSmooth1080p60() {
        let preset = VideoPreset.defaultPreset
        XCTAssertEqual(preset.id, "smooth_1080p60")
        XCTAssertEqual(preset.resolution, "1920x1080")
        XCTAssertEqual(preset.fps, 60)
        XCTAssertEqual(preset.codec, .h264)
        XCTAssertEqual(preset.bitrate, 10_000_000)
    }

    func testPresetIdsAreUnique() {
        let ids = VideoPreset.allPresets.map { $0.id }
        XCTAssertEqual(Set(ids).count, ids.count, "All preset IDs should be unique")
    }

    func testPresetDisplayDescription() {
        let preset = VideoPreset(
            id: "test",
            name: "Test Preset",
            resolution: "1920x1080",
            fps: 30,
            codec: .h264,
            bitrate: 10_000_000
        )
        let desc = preset.displayDescription
        XCTAssertTrue(desc.contains("1920x1080"))
        XCTAssertTrue(desc.contains("30fps"))
        XCTAssertTrue(desc.contains("H.264"))
    }

    // MARK: - VideoCodec

    func testVideoCodecDisplayNames() {
        XCTAssertEqual(VideoCodec.h264.displayName, "H.264")
        XCTAssertEqual(VideoCodec.hevc.displayName, "H.265/HEVC")
    }

    func testVideoCodecRawValues() {
        XCTAssertEqual(VideoCodec.h264.rawValue, "h264")
        XCTAssertEqual(VideoCodec.hevc.rawValue, "hevc")
    }

    // MARK: - VideoSettings Encode/Decode

    func testVideoSettingsRoundTrip() throws {
        let original = VideoSettings(
            selectedPresetId: "smooth_1080p60",
            customResolution: nil,
            customFps: nil,
            customCodec: nil,
            customBitrate: nil
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(VideoSettings.self, from: data)

        XCTAssertEqual(decoded.selectedPresetId, "smooth_1080p60")
        XCTAssertEqual(decoded.streamingMode, .ndi)
        XCTAssertEqual(decoded.srtPort, 9000)
        XCTAssertEqual(decoded.srtLatency, 120)
    }

    func testVideoSettingsWithCustomValues() throws {
        let original = VideoSettings(
            selectedPresetId: nil,
            customResolution: "2560x1440",
            customFps: 60,
            customCodec: .hevc,
            customBitrate: 12_000_000
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(VideoSettings.self, from: data)

        XCTAssertNil(decoded.selectedPresetId)
        XCTAssertEqual(decoded.customResolution, "2560x1440")
        XCTAssertEqual(decoded.customFps, 60)
        XCTAssertEqual(decoded.customCodec, .hevc)
        XCTAssertEqual(decoded.customBitrate, 12_000_000)
    }

    // MARK: - effectiveSettings

    func testEffectiveSettingsFromPreset() {
        let settings = VideoSettings(
            selectedPresetId: "low_power_1080p",
            customResolution: nil,
            customFps: nil,
            customCodec: nil,
            customBitrate: nil
        )

        let config = settings.effectiveSettings(presets: VideoPreset.allPresets)
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.resolution, "1920x1080")
        XCTAssertEqual(config?.fps, 25)
        XCTAssertEqual(config?.codec, .h264)
        XCTAssertEqual(config?.bitrate, 5_000_000)
    }

    func testEffectiveSettingsFromCustom() {
        let settings = VideoSettings(
            selectedPresetId: nil,
            customResolution: "3840x2160",
            customFps: 25,
            customCodec: .hevc,
            customBitrate: 16_000_000
        )

        let config = settings.effectiveSettings(presets: VideoPreset.allPresets)
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.resolution, "3840x2160")
        XCTAssertEqual(config?.fps, 25)
        XCTAssertEqual(config?.codec, .hevc)
        XCTAssertEqual(config?.bitrate, 16_000_000)
    }

    func testEffectiveSettingsCustomOverridesPreset() {
        let settings = VideoSettings(
            selectedPresetId: "low_power_1080p",
            customResolution: "2560x1440",
            customFps: 60,
            customCodec: .hevc,
            customBitrate: 12_000_000
        )

        let config = settings.effectiveSettings(presets: VideoPreset.allPresets)
        // Custom should take priority when all custom fields are set
        XCTAssertEqual(config?.resolution, "2560x1440")
    }

    func testEffectiveSettingsReturnsNilWhenNoMatch() {
        let settings = VideoSettings(
            selectedPresetId: "nonexistent_preset",
            customResolution: nil,
            customFps: nil,
            customCodec: nil,
            customBitrate: nil
        )

        let config = settings.effectiveSettings(presets: VideoPreset.allPresets)
        XCTAssertNil(config)
    }

    // MARK: - StreamConfiguration

    func testStreamConfigurationToStreamStartRequest() {
        let config = StreamConfiguration(
            resolution: "1920x1080",
            fps: 30,
            codec: .h264,
            bitrate: 10_000_000
        )

        let videoSettings = VideoSettings(
            selectedPresetId: nil,
            customResolution: nil,
            customFps: nil,
            customCodec: nil,
            customBitrate: nil
        )

        let request = config.toStreamStartRequest(videoSettings: videoSettings)
        XCTAssertEqual(request.resolution, "1920x1080")
        XCTAssertEqual(request.framerate, 30)
        XCTAssertEqual(request.bitrate, 10_000_000)
        XCTAssertEqual(request.codec, "h264")
        XCTAssertEqual(request.srtPort, 9000)
        XCTAssertEqual(request.srtLatency, 120)
    }
}
