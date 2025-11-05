//
//  TelemetryMenuView.swift
//  AvoCam
//
//  Popup menu for telemetry data
//

import SwiftUI

struct TelemetryMenuView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Telemetry")
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

            // Telemetry content
            if let telemetry = coordinator.telemetry {
                ScrollView {
                    VStack(spacing: 16) {
                        // API Endpoint - Full width
                        if let ip = coordinator.localIPAddress {
                            VStack(spacing: 8) {
                                HStack {
                                    Image(systemName: "network")
                                        .foregroundColor(.blue)
                                    Text("API Endpoint")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                    Spacer()
                                }

                                Text("http://\(ip):8888")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.blue)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background(Color(.systemGray6))
                                    .cornerRadius(6)
                            }
                            .padding()
                            .background(Color(.systemGray5))
                            .cornerRadius(12)
                        }

                        // Telemetry Grid
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            telemetryCard(
                            title: "FPS",
                            value: String(format: "%.1f", telemetry.fps),
                            icon: "speedometer",
                            color: .blue
                        )

                        telemetryCard(
                            title: "Bitrate",
                            value: formatBitrate(telemetry.bitrate),
                            icon: "network",
                            color: .green
                        )

                        telemetryCard(
                            title: "Battery",
                            value: String(format: "%.0f%%", telemetry.battery * 100),
                            icon: batteryIcon(telemetry.battery),
                            color: batteryColor(telemetry.battery)
                        )

                        telemetryCard(
                            title: "Temperature",
                            value: String(format: "%.1f°C", telemetry.tempC),
                            icon: "thermometer",
                            color: tempColor(telemetry.tempC)
                        )

                        telemetryCard(
                            title: "WiFi Signal",
                            value: "\(telemetry.wifiRssi) dBm",
                            icon: wifiIcon(telemetry.wifiRssi),
                            color: wifiColor(telemetry.wifiRssi)
                        )

                        if let chargingState = telemetry.chargingState {
                            telemetryCard(
                                title: "Charging",
                                value: chargingState.rawValue.capitalized,
                                icon: "bolt.fill",
                                color: .yellow
                            )
                        }

                        if let droppedFrames = telemetry.droppedFrames {
                            telemetryCard(
                                title: "Dropped Frames",
                                value: "\(droppedFrames)",
                                icon: "exclamationmark.triangle",
                                color: droppedFrames > 0 ? .red : .gray
                            )
                        }

                        if let queueMs = telemetry.queueMs {
                            telemetryCard(
                                title: "Queue Depth",
                                value: "\(queueMs)ms",
                                icon: "timer",
                                color: queueMs > 100 ? .orange : .gray
                            )
                        }
                    }
                }
                .padding()
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)

                    Text("No telemetry available")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
        .frame(width: 340, height: 500)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(radius: 20)
    }

    // MARK: - Telemetry Card

    private func telemetryCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)

            Text(value)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.semibold)

            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    // MARK: - Helpers

    private func formatBitrate(_ bitrate: Int) -> String {
        let mbps = Double(bitrate) / 1_000_000
        if mbps >= 1 {
            return String(format: "%.1f Mbps", mbps)
        } else {
            return String(format: "%.0f Kbps", mbps * 1000)
        }
    }

    private func batteryIcon(_ level: Double) -> String {
        if level > 0.75 {
            return "battery.100"
        } else if level > 0.5 {
            return "battery.75"
        } else if level > 0.25 {
            return "battery.50"
        } else {
            return "battery.25"
        }
    }

    private func batteryColor(_ level: Double) -> Color {
        if level > 0.5 {
            return .green
        } else if level > 0.2 {
            return .orange
        } else {
            return .red
        }
    }

    private func tempColor(_ temp: Double) -> Color {
        if temp > 43 {
            return .red
        } else if temp > 38 {
            return .orange
        } else {
            return .blue
        }
    }

    private func wifiIcon(_ rssi: Int) -> String {
        if rssi > -50 {
            return "wifi"
        } else if rssi > -65 {
            return "wifi"
        } else {
            return "wifi.slash"
        }
    }

    private func wifiColor(_ rssi: Int) -> Color {
        if rssi > -50 {
            return .green
        } else if rssi > -65 {
            return .orange
        } else {
            return .red
        }
    }
}
