//
//  StreamControlOverlay.swift
//  AvoCam
//
//  Overlay for stream status and controls
//

import SwiftUI

struct StreamControlOverlay: View {
    @EnvironmentObject var coordinator: AppCoordinator
    let onOpenSettings: () -> Void
    let onOpenTelemetry: () -> Void

    var body: some View {
        VStack {
            // Top bar with status and menu buttons
            HStack {
                // Streaming status indicator
                HStack(spacing: 8) {
                    Circle()
                        .fill(coordinator.isStreaming ? Color.red : Color.gray)
                        .frame(width: 8, height: 8)

                    Text(coordinator.isStreaming ? "LIVE" : "IDLE")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.6))
                .cornerRadius(16)

                Spacer()

                // Telemetry button
                Button(action: onOpenTelemetry) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Circle())
                }

                // Settings button
                Button(action: onOpenSettings) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 18))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Circle())
                }
            }
            .padding()

            Spacer()

            // Bottom controls
            VStack(spacing: 16) {
                // Error display
                if let error = coordinator.error {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .padding()
                    .background(Color.red.opacity(0.8))
                    .cornerRadius(12)
                }

                // Stream controls
                HStack(spacing: 16) {
                    Button(action: startStream) {
                        HStack(spacing: 8) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 20))
                            Text("Start")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(coordinator.isStreaming ? Color.gray : Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(coordinator.isStreaming)

                    Button(action: stopStream) {
                        HStack(spacing: 8) {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 20))
                            Text("Stop")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(coordinator.isStreaming ? Color.red : Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(!coordinator.isStreaming)
                }

                // Current settings display (compact)
                if let settings = coordinator.currentSettings {
                    HStack(spacing: 12) {
                        Text("\(settings.resolution) @ \(settings.fps)fps")
                        Text("•")
                        Text(formatBitrate(settings.bitrate))
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(16)
                }
            }
            .padding()
        }
    }

    // MARK: - Actions

    private func startStream() {
        Task {
            let request = StreamStartRequest(
                resolution: "1920x1080",
                framerate: 30,
                bitrate: 10_000_000,
                codec: "h264"
            )

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

    private func formatBitrate(_ bitrate: Int) -> String {
        let mbps = Double(bitrate) / 1_000_000
        return String(format: "%.1f Mbps", mbps)
    }
}
