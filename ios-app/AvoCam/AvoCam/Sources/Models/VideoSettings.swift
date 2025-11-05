//
//  VideoSettings.swift
//  AvoCam
//
//  Video settings and presets management
//

import Foundation

// MARK: - Video Preset

struct VideoPreset: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let resolution: String
    let fps: Int
    let codec: VideoCodec
    let bitrate: Int

    var displayName: String {
        name
    }

    var displayDescription: String {
        "\(resolution) @ \(fps)fps • \(codec.displayName) • \(formattedBitrate)"
    }

    private var formattedBitrate: String {
        let mbps = Double(bitrate) / 1_000_000
        return String(format: "%.0f-%.0f Mbps", mbps * 0.8, mbps * 1.2)
    }
}

// MARK: - Video Codec

enum VideoCodec: String, Codable {
    case h264 = "h264"
    case hevc = "hevc"

    var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "H.265/HEVC"
        }
    }
}

// MARK: - Video Settings

struct VideoSettings: Codable {
    var selectedPresetId: String?
    var customResolution: String?
    var customFps: Int?
    var customCodec: VideoCodec?
    var customBitrate: Int?

    // Computed property to get effective settings
    func effectiveSettings(presets: [VideoPreset]) -> StreamConfiguration? {
        // If custom settings are all specified, use them
        if let resolution = customResolution,
           let fps = customFps,
           let codec = customCodec,
           let bitrate = customBitrate {
            return StreamConfiguration(
                resolution: resolution,
                fps: fps,
                codec: codec,
                bitrate: bitrate
            )
        }

        // Otherwise use selected preset
        if let presetId = selectedPresetId,
           let preset = presets.first(where: { $0.id == presetId }) {
            return StreamConfiguration(
                resolution: preset.resolution,
                fps: preset.fps,
                codec: preset.codec,
                bitrate: preset.bitrate
            )
        }

        // Fallback to default
        return nil
    }
}

// MARK: - Stream Configuration

struct StreamConfiguration {
    let resolution: String
    let fps: Int
    let codec: VideoCodec
    let bitrate: Int

    func toStreamStartRequest() -> StreamStartRequest {
        return StreamStartRequest(
            resolution: resolution,
            framerate: fps,
            bitrate: bitrate,
            codec: codec.rawValue
        )
    }
}

// MARK: - Preset Definitions

extension VideoPreset {
    static let allPresets: [VideoPreset] = [
        // 1080p Presets
        VideoPreset(
            id: "low_power_1080p",
            name: "Low Power 1080p",
            resolution: "1920x1080",
            fps: 30,
            codec: .h264,
            bitrate: 5_000_000  // 4-6 Mbps average
        ),
        VideoPreset(
            id: "smooth_1080p60",
            name: "Smooth 1080p60",
            resolution: "1920x1080",
            fps: 60,
            codec: .h264,
            bitrate: 10_000_000  // 8-12 Mbps average
        ),
        VideoPreset(
            id: "high_quality_1080p",
            name: "High Quality 1080p",
            resolution: "1920x1080",
            fps: 30,
            codec: .hevc,
            bitrate: 3_500_000  // 3-4 Mbps average
        ),

        // 2K Presets
        VideoPreset(
            id: "2k_cinematic",
            name: "2K Cinematic",
            resolution: "2560x1440",
            fps: 30,
            codec: .hevc,
            bitrate: 7_000_000  // 6-8 Mbps average
        ),
        VideoPreset(
            id: "2k_performance",
            name: "2K Performance",
            resolution: "2560x1440",
            fps: 60,
            codec: .hevc,
            bitrate: 12_000_000  // 10-14 Mbps average
        ),

        // 4K Presets
        VideoPreset(
            id: "4k_standard",
            name: "4K Standard",
            resolution: "3840x2160",
            fps: 30,
            codec: .h264,
            bitrate: 26_000_000  // 20-32 Mbps average
        ),
        VideoPreset(
            id: "4k_efficient",
            name: "4K Efficient",
            resolution: "3840x2160",
            fps: 30,
            codec: .hevc,
            bitrate: 16_000_000  // 12-20 Mbps average
        ),
        VideoPreset(
            id: "4k_high_fps",
            name: "4K High FPS",
            resolution: "3840x2160",
            fps: 60,
            codec: .hevc,
            bitrate: 30_000_000  // 25-35 Mbps average
        )
    ]

    static let defaultPreset = allPresets[1]  // Smooth 1080p60
}

// MARK: - Settings Persistence

class VideoSettingsManager {
    private static let settingsKey = "video_settings"

    static func save(_ settings: VideoSettings) {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: settingsKey)
        }
    }

    static func load() -> VideoSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(VideoSettings.self, from: data) else {
            // Return default settings
            return VideoSettings(
                selectedPresetId: VideoPreset.defaultPreset.id,
                customResolution: nil,
                customFps: nil,
                customCodec: nil,
                customBitrate: nil
            )
        }
        return settings
    }

    static func getEffectiveConfiguration() -> StreamConfiguration {
        let settings = load()
        return settings.effectiveSettings(presets: VideoPreset.allPresets) ?? StreamConfiguration(
            resolution: VideoPreset.defaultPreset.resolution,
            fps: VideoPreset.defaultPreset.fps,
            codec: VideoPreset.defaultPreset.codec,
            bitrate: VideoPreset.defaultPreset.bitrate
        )
    }
}
