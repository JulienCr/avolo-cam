//
//  TelemetryCollector.swift
//  AvoCam
//
//  Collects system telemetry (battery, temperature, WiFi, etc.)
//

import Foundation
import UIKit
import SystemConfiguration.CaptiveNetwork

actor TelemetryCollector {
    struct SystemTelemetry {
        let battery: Double
        let temperature: Double
        let wifiRssi: Int
        let chargingState: ChargingState
        let thermalState: ProcessInfo.ThermalState
    }

    func collect() async -> SystemTelemetry {
        let battery = getBatteryLevel()
        let temperature = getDeviceTemperature()
        let wifiRssi = getWiFiRSSI()
        let chargingState = getChargingState()
        let thermalState = ProcessInfo.processInfo.thermalState

        return SystemTelemetry(
            battery: battery,
            temperature: temperature,
            wifiRssi: wifiRssi,
            chargingState: chargingState,
            thermalState: thermalState
        )
    }

    // MARK: - Battery

    private func getBatteryLevel() -> Double {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel

        // batteryLevel returns -1 if unknown, so clamp to 0-1 range
        return max(0.0, min(1.0, Double(level)))
    }

    private func getChargingState() -> ChargingState {
        UIDevice.current.isBatteryMonitoringEnabled = true

        switch UIDevice.current.batteryState {
        case .charging:
            return .charging
        case .full:
            return .full
        case .unplugged, .unknown:
            return .unplugged
        @unknown default:
            return .unplugged
        }
    }

    // MARK: - Temperature

    private func getDeviceTemperature() -> Double {
        // iOS doesn't provide direct API for device temperature
        // Use thermal state as proxy
        let state = ProcessInfo.processInfo.thermalState

        switch state {
        case .nominal:
            return 30.0 // Estimate: cool
        case .fair:
            return 38.0 // Estimate: warm
        case .serious:
            return 43.0 // Estimate: hot
        case .critical:
            return 48.0 // Estimate: very hot
        @unknown default:
            return 35.0
        }
    }

    // MARK: - WiFi RSSI

    private func getWiFiRSSI() -> Int {
        // Note: Getting actual WiFi RSSI requires private APIs or is unavailable
        // Return estimated value based on network status
        // In production, consider using Network.framework for more accurate info

        // Placeholder: return -50 dBm (good signal)
        return -50

        // Alternative approach using CNCopyCurrentNetworkInfo (requires entitlements):
        /*
        guard let interfaces = CNCopySupportedInterfaces() as? [String] else {
            return -50
        }

        for interface in interfaces {
            guard let info = CNCopyCurrentNetworkInfo(interface as CFString) as? [String: Any] else {
                continue
            }

            // Note: RSSI not available in iOS 13+
            // Would need to use NEHotspotNetwork or private APIs
        }

        return -50
        */
    }

    // MARK: - Network Status (Optional Enhancement)

    private func isWiFiConnected() -> Bool {
        var zeroAddress = sockaddr_in()
        zeroAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        zeroAddress.sin_family = sa_family_t(AF_INET)

        guard let defaultRouteReachability = withUnsafePointer(to: &zeroAddress, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                SCNetworkReachabilityCreateWithAddress(nil, $0)
            }
        }) else {
            return false
        }

        var flags: SCNetworkReachabilityFlags = []
        if !SCNetworkReachabilityGetFlags(defaultRouteReachability, &flags) {
            return false
        }

        let isReachable = flags.contains(.reachable)
        let needsConnection = flags.contains(.connectionRequired)

        return isReachable && !needsConnection
    }
}
