//
//  VideoSettingsView.swift
//  AvoCam
//
//  Video settings configuration UI
//

import SwiftUI

struct VideoSettingsView: View {
    @StateObject private var viewModel = VideoSettingsViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("PRESETS")) {
                    ForEach(VideoPreset.allPresets) { preset in
                        Button(action: {
                            viewModel.selectPreset(preset)
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(preset.name)
                                        .foregroundColor(.primary)
                                        .font(.headline)
                                    Text(preset.displayDescription)
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                                Spacer()
                                if viewModel.settings.selectedPresetId == preset.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }

                Section(header: Text("CUSTOM SETTINGS")) {
                    Toggle("Use Custom Settings", isOn: $viewModel.useCustomSettings)

                    if viewModel.useCustomSettings {
                        Picker("Resolution", selection: $viewModel.customResolution) {
                            Text("1920×1080").tag("1920x1080")
                            Text("2560×1440").tag("2560x1440")
                            Text("3840×2160").tag("3840x2160")
                        }

                        Picker("Frame Rate", selection: $viewModel.customFps) {
                            Text("25 fps").tag(25)
                            Text("30 fps").tag(30)
                            Text("60 fps").tag(60)
                        }

                        Picker("Codec", selection: $viewModel.customCodec) {
                            Text("H.264").tag(VideoCodec.h264)
                            Text("H.265/HEVC").tag(VideoCodec.hevc)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Bitrate: \(viewModel.customBitrate / 1_000_000) Mbps")
                                .font(.subheadline)
                            Slider(
                                value: Binding(
                                    get: { Double(viewModel.customBitrate) },
                                    set: { viewModel.customBitrate = Int($0) }
                                ),
                                in: 1_000_000...50_000_000,
                                step: 1_000_000
                            )
                            HStack {
                                Text("1 Mbps")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("50 Mbps")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                Section(header: Text("CURRENT CONFIGURATION")) {
                    if let config = viewModel.effectiveConfiguration {
                        HStack {
                            Text("Resolution")
                            Spacer()
                            Text(config.resolution)
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Text("Frame Rate")
                            Spacer()
                            Text("\(config.fps) fps")
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Text("Codec")
                            Spacer()
                            Text(config.codec.displayName)
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Text("Bitrate")
                            Spacer()
                            Text("\(config.bitrate / 1_000_000) Mbps")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Video Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        viewModel.save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - View Model

@MainActor
class VideoSettingsViewModel: ObservableObject {
    @Published var settings: VideoSettings
    @Published var useCustomSettings: Bool

    @Published var customResolution: String
    @Published var customFps: Int
    @Published var customCodec: VideoCodec
    @Published var customBitrate: Int

    var effectiveConfiguration: StreamConfiguration? {
        if useCustomSettings {
            return StreamConfiguration(
                resolution: customResolution,
                fps: customFps,
                codec: customCodec,
                bitrate: customBitrate
            )
        } else {
            return settings.effectiveSettings(presets: VideoPreset.allPresets)
        }
    }

    init() {
        self.settings = VideoSettingsManager.load()

        // Initialize custom settings
        self.useCustomSettings = settings.customResolution != nil
        self.customResolution = settings.customResolution ?? "1920x1080"
        self.customFps = settings.customFps ?? 30
        self.customCodec = settings.customCodec ?? .h264
        self.customBitrate = settings.customBitrate ?? 10_000_000
    }

    func selectPreset(_ preset: VideoPreset) {
        settings.selectedPresetId = preset.id
        useCustomSettings = false
    }

    func save() {
        if useCustomSettings {
            settings.customResolution = customResolution
            settings.customFps = customFps
            settings.customCodec = customCodec
            settings.customBitrate = customBitrate
        } else {
            settings.customResolution = nil
            settings.customFps = nil
            settings.customCodec = nil
            settings.customBitrate = nil
        }

        VideoSettingsManager.save(settings)
        print("✅ Video settings saved")
    }
}

// MARK: - Preview

struct VideoSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        VideoSettingsView()
    }
}
