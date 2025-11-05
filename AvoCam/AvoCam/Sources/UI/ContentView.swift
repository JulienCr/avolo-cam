//
//  ContentView.swift
//  AvoCam
//
//  Main UI view - Camera-first layout with overlays
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var coordinator: AppCoordinator
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
