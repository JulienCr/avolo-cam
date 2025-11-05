//
//  ContentView.swift
//  AvoCam
//
//  Main UI view
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @State private var showingVideoSettings = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    headerSection

                    // Streaming Status
                    statusSection

                    // Stream Controls
                    streamControlsSection

                    // Camera Settings
                    cameraSettingsSection

                    // Telemetry
                    telemetrySection

                    // Error Display
                    if let error = coordinator.error {
                        errorSection(error)
                    }

                    Spacer()
                }
                .padding()
            }
            .navigationTitle("AvoCam")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showingVideoSettings = true
                    }) {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
            .sheet(isPresented: $showingVideoSettings) {
                VideoSettingsView()
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "video.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.blue)

            Text("NDI Camera Streaming")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    // MARK: - Status

    private var statusSection: some View {
        HStack {
            Circle()
                .fill(coordinator.isStreaming ? Color.green : Color.gray)
                .frame(width: 12, height: 12)

            Text(coordinator.isStreaming ? "STREAMING" : "IDLE")
                .font(.system(.body, design: .monospaced))
                .fontWeight(.bold)

            Spacer()
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }

    // MARK: - Stream Controls

    private var streamControlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stream Control")
                .font(.headline)

            HStack {
                Button(action: startStream) {
                    Label("Start Stream", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.isStreaming)

                Button(action: stopStream) {
                    Label("Stop Stream", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!coordinator.isStreaming)
            }

            if let settings = coordinator.currentSettings {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current: \(settings.resolution) @ \(settings.fps)fps")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Bitrate: \(formatBitrate(settings.bitrate))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }

    // MARK: - Camera Settings

    private var cameraSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Camera Settings")
                .font(.headline)

            Text("Use the web UI or Tauri controller for camera adjustments")
                .font(.caption)
                .foregroundColor(.secondary)

            if let settings = coordinator.currentSettings {
                VStack(alignment: .leading, spacing: 8) {
                    settingRow(label: "White Balance", value: "\(settings.wbMode.rawValue)")
                    if let kelvin = settings.wbKelvin {
                        settingRow(label: "Color Temp", value: "\(kelvin)K")
                    }
                    settingRow(label: "ISO", value: "\(settings.iso)")
                    settingRow(label: "Shutter", value: String(format: "%.4fs", settings.shutterS))
                    settingRow(label: "Zoom", value: String(format: "%.1fx", settings.zoomFactor))
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }

    // MARK: - Telemetry

    private var telemetrySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Telemetry")
                .font(.headline)

            if let telemetry = coordinator.telemetry {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    telemetryCard(title: "FPS", value: String(format: "%.1f", telemetry.fps), icon: "speedometer")
                    telemetryCard(title: "Bitrate", value: formatBitrate(telemetry.bitrate), icon: "network")
                    telemetryCard(title: "Battery", value: String(format: "%.0f%%", telemetry.battery * 100), icon: "battery.100")
                    telemetryCard(title: "Temp", value: String(format: "%.1f°C", telemetry.tempC), icon: "thermometer")
                    telemetryCard(title: "WiFi", value: "\(telemetry.wifiRssi) dBm", icon: "wifi")

                    if let chargingState = telemetry.chargingState {
                        telemetryCard(title: "Charging", value: chargingState.rawValue, icon: "bolt.fill")
                    }

                    if let droppedFrames = telemetry.droppedFrames {
                        telemetryCard(title: "Dropped", value: "\(droppedFrames)", icon: "exclamationmark.triangle")
                    }

                    if let queueMs = telemetry.queueMs {
                        telemetryCard(title: "Queue", value: "\(queueMs)ms", icon: "timer")
                    }
                }
            } else {
                Text("No telemetry available")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }

    // MARK: - Helpers

    private func settingRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }

    private func telemetryCard(title: String, value: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.blue)

            Text(value)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.semibold)

            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(8)
    }

    private func errorSection(_ error: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)

            Text(error)
                .font(.caption)
                .foregroundColor(.red)

            Spacer()
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(10)
    }

    private func formatBitrate(_ bitrate: Int) -> String {
        let mbps = Double(bitrate) / 1_000_000
        return String(format: "%.1f Mbps", mbps)
    }

    // MARK: - Actions

    private func startStream() {
        Task {
            // Load saved video settings
            let config = VideoSettingsManager.getEffectiveConfiguration()
            let request = config.toStreamStartRequest()

            do {
                try await coordinator.startStreaming(request: request)
            } catch {
                print("❌ Failed to start stream: \(error)")
            }
        }
    }

    private func stopStream() {
        Task {
            await coordinator.stopStreaming()
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(AppCoordinator())
}
