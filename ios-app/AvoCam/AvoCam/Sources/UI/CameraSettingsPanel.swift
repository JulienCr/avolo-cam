//
//  CameraSettingsPanel.swift
//  AvoCam
//
//  Slide-out panel for camera settings
//

import SwiftUI

struct CameraSettingsPanel: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Binding var isPresented: Bool

    @State private var selectedWBMode: WhiteBalanceMode = .auto
    @State private var wbKelvin: Double = 5000
    @State private var wbTint: Double = 0.0
    @State private var selectedISOMode: ExposureMode = .auto
    @State private var iso: Double = 160
    @State private var selectedShutterMode: ExposureMode = .auto
    @State private var shutterSpeed: Double = 0.01
    @State private var zoomFactor: Double = 2.0  // Device zoom (wide lens = 2.0x)
    @State private var selectedLens: String = "wide"  // "ultra_wide", "wide", "telephoto"

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Camera Settings")
                    .font(.headline)
                    .foregroundColor(.primary)

                Spacer()

                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(.systemBackground))

            Divider()

            // Settings content
            ScrollView {
                VStack(spacing: 24) {
                    // White Balance
                    VStack(alignment: .leading, spacing: 12) {
                        Label("White Balance", systemImage: "sun.max")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        Picker("Mode", selection: $selectedWBMode) {
                            Text("Auto").tag(WhiteBalanceMode.auto)
                            Text("Manual").tag(WhiteBalanceMode.manual)
                        }
                        .pickerStyle(.segmented)

                        if selectedWBMode == .manual {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Temperature")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("\(Int(wbKelvin))K")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                }

                                Slider(value: $wbKelvin, in: 3000...7000, step: 100)
                            }
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)

                    // ISO
                    VStack(alignment: .leading, spacing: 12) {
                        Label("ISO", systemImage: "camera.aperture")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        Picker("Mode", selection: $selectedISOMode) {
                            Text("Auto").tag(ExposureMode.auto)
                            Text("Manual").tag(ExposureMode.manual)
                        }
                        .pickerStyle(.segmented)

                        if selectedISOMode == .manual {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Sensitivity")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("\(Int(iso))")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                }

                                Slider(value: $iso, in: 50...3200, step: 10)
                            }
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)

                    // Shutter Speed
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Shutter Speed", systemImage: "timer")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        Picker("Mode", selection: $selectedShutterMode) {
                            Text("Auto").tag(ExposureMode.auto)
                            Text("Manual").tag(ExposureMode.manual)
                        }
                        .pickerStyle(.segmented)

                        if selectedShutterMode == .manual {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Exposure Time")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(formatShutterSpeed(shutterSpeed))
                                        .font(.caption)
                                        .fontWeight(.medium)
                                }

                                Slider(value: $shutterSpeed, in: 0.001...0.1, step: 0.001)
                            }
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)

                    // Lens & Zoom
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Lens & Zoom", systemImage: "camera.metering.center.weighted")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        // Lens selector (segmented control style)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Lens")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack(spacing: 8) {
                                LensButton(title: ".5", lensType: "ultra_wide", isSelected: selectedLens == "ultra_wide") {
                                    selectedLens = "ultra_wide"
                                    zoomFactor = 1.0  // Device zoom for ultra-wide
                                }

                                LensButton(title: "1", lensType: "wide", isSelected: selectedLens == "wide") {
                                    selectedLens = "wide"
                                    zoomFactor = 2.0  // Device zoom for wide
                                }

                                LensButton(title: "5", lensType: "telephoto", isSelected: selectedLens == "telephoto") {
                                    selectedLens = "telephoto"
                                    zoomFactor = 10.0  // Device zoom for telephoto
                                }
                            }
                        }

                        // Zoom slider
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Fine Zoom")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(String(format: "%.1f×", zoomFactor / 2.0))  // Display UI zoom (device / 2)
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }

                            Slider(value: $zoomFactor, in: 1.0...20.0, step: 0.1)  // Device zoom range
                                .onChange(of: zoomFactor) { _, newValue in
                                    updateLensFromZoom(newValue)
                                }
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)

                    // Apply button
                    Button(action: applySettings) {
                        Text("Apply Settings")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                }
                .padding()
            }
        }
        .frame(width: 320)
        .background(Color(.systemBackground))
        .onAppear {
            loadCurrentSettings()
        }
    }

    // MARK: - Helpers

    private func loadCurrentSettings() {
        if let settings = coordinator.currentSettings {
            selectedWBMode = settings.wbMode
            wbKelvin = Double(settings.wbKelvin ?? 5000)
            wbTint = settings.wbTint ?? 0.0
            selectedISOMode = settings.isoMode
            iso = Double(settings.iso)
            selectedShutterMode = settings.shutterMode
            shutterSpeed = settings.shutterS
            zoomFactor = settings.zoomFactor
            updateLensFromZoom(zoomFactor)  // Update lens based on current zoom
        }
    }

    private func updateLensFromZoom(_ zoom: Double) {
        // Auto-detect lens based on device zoom value
        // Device zoom: ultra-wide=1.0, wide=2.0, telephoto=10.0
        // Thresholds: 1.5 (between 1.0 and 2.0), 6.0 (between 2.0 and 10.0)
        if zoom < 1.5 {
            selectedLens = "ultra_wide"  // < 1.5x device zoom
        } else if zoom >= 6.0 {
            selectedLens = "telephoto"   // >= 6.0x device zoom
        } else {
            selectedLens = "wide"        // 1.5x - 6.0x device zoom
        }
    }

    private func applySettings() {
        Task {
            let request = CameraSettingsRequest(
                wbMode: selectedWBMode,
                wbKelvin: selectedWBMode == .manual ? Int(wbKelvin) : nil,
                wbTint: selectedWBMode == .manual ? wbTint : nil,
                isoMode: selectedISOMode,
                iso: selectedISOMode == .manual ? Int(iso) : nil,
                shutterMode: selectedShutterMode,
                shutterS: selectedShutterMode == .manual ? shutterSpeed : nil,
                focusMode: nil,
                zoomFactor: zoomFactor,
                cameraPosition: nil,
                lens: nil,
                orientationLock: nil
            )

            do {
                try await coordinator.updateCameraSettings(request)
                print("✅ Settings applied")
            } catch {
                print("❌ Failed to apply settings: \(error)")
            }
        }
    }

    private func formatShutterSpeed(_ seconds: Double) -> String {
        if seconds >= 1 {
            return String(format: "%.1fs", seconds)
        } else {
            return String(format: "1/%.0f", 1.0 / seconds)
        }
    }
}

// MARK: - Lens Button Component

struct LensButton: View {
    let title: String
    let lensType: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isSelected ? Color.blue : Color(.systemGray5))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(8)
        }
    }
}
