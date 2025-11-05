//
//  ContentView.swift
//  AvoCam
//
//  Main UI view - Camera-first layout with overlays
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @State private var showingVideoSettings = false
    @Environment(\.scenePhase) private var scenePhase

    @State private var showSettings = false
    @State private var showTelemetry = false

    var body: some View {
        ZStack {
            // Camera preview (full screen background)
            if let session = coordinator.captureSession {
                CameraPreviewView(captureSession: session)
                    .edgesIgnoringSafeArea(.all)
            } else {
                // Placeholder while camera initializes
                Color.black
                    .edgesIgnoringSafeArea(.all)
                    .overlay(
                        VStack(spacing: 16) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.5)

                            Text("Initializing camera...")
                                .font(.subheadline)
                                .foregroundColor(.white)
                        }
                    )
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


            // Stream control overlay (always visible)
            StreamControlOverlay(
                onOpenSettings: { showSettings = true },
                onOpenTelemetry: { showTelemetry = true }
            )
            .environmentObject(coordinator)

            // Settings panel (slides in from right)
            if showSettings {
                HStack {
                    Spacer()

                    CameraSettingsPanel(isPresented: $showSettings)
                        .environmentObject(coordinator)
                        .transition(.move(edge: .trailing))
                        .shadow(radius: 20)
                }
                .background(
                    Color.black.opacity(0.3)
                        .edgesIgnoringSafeArea(.all)
                        .onTapGesture {
                            showSettings = false
                        }
                )
            }

            // Telemetry menu (pops up in center)
            if showTelemetry {
                ZStack {
                    Color.black.opacity(0.3)
                        .edgesIgnoringSafeArea(.all)
                        .onTapGesture {
                            showTelemetry = false
                        }

                    TelemetryMenuView(isPresented: $showTelemetry)
                        .environmentObject(coordinator)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showSettings)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showTelemetry)
        .statusBar(hidden: true) // Hide status bar for full-screen camera view
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(newPhase)
        }
    }

    // MARK: - Lifecycle

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            Task {
                await coordinator.resumePreview()
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
        case .background:
            Task {
                await coordinator.pausePreview()
            }
        default:
            break
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(AppCoordinator())
}
