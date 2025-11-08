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

    @StateObject private var screenDimManager = ScreenDimManager()

    var body: some View {
        ZStack {
            // Camera preview (full screen background)
            // Preview is disabled during streaming to save GPU/CPU resources
            if let session = coordinator.captureSession {
                CameraPreviewView(captureSession: session, isHidden: coordinator.isStreaming)
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

            // Tap-to-wake overlay when streaming with dimmed screen
            if coordinator.isStreaming && !screenDimManager.isScreenAwake {
                Color.black
                    .edgesIgnoringSafeArea(.all)
                    .overlay(
                        VStack(spacing: 12) {
                            Image(systemName: "hand.tap.fill")
                                .font(.system(size: 48))
                                .foregroundColor(.white.opacity(0.3))

                            Text("Tap to wake")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.3))
                        }
                        .opacity(screenDimManager.isScreenAwake ? 0 : 1)
                        .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: screenDimManager.isScreenAwake)
                    )
                    .onTapGesture {
                        screenDimManager.wakeScreen()
                    }
            }

            // Stream control overlay (always visible)
            StreamControlOverlay(
                onOpenSettings: {
                    screenDimManager.wakeScreen()
                    showSettings = true
                },
                onOpenTelemetry: {
                    screenDimManager.wakeScreen()
                    showTelemetry = true
                }
            )
            .environmentObject(coordinator)
            .opacity(screenDimManager.isScreenAwake || !coordinator.isStreaming ? 1 : 0)

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
        .statusBar(hidden: true)
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
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(newPhase)
        }
        .onChange(of: coordinator.isStreaming) { oldValue, newValue in
            if newValue {
                // Started streaming - dim screen
                screenDimManager.startStreaming()
            } else {
                // Stopped streaming - restore brightness
                screenDimManager.stopStreaming()
            }
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
