//
//  TelemetryCollector.swift
//  AvoCam
//
//  Collects system telemetry (battery, temperature, WiFi, etc.)
//

import Foundation
import UIKit
import SystemConfiguration.CaptiveNetwork
import Darwin

actor TelemetryCollector {
    struct SystemTelemetry {
        let battery: Double
        let temperature: Double
        let wifiRssi: Int
        let chargingState: ChargingState
        let thermalState: ProcessInfo.ThermalState
        let networkBitrate: Int  // bits per second
        let cpuUsage: Double  // 0.0 to 100.0+ percentage
    }

    // Network monitoring state
    private var lastNetworkCheck: Date?
    private var lastBytesSent: UInt64 = 0

    func collect() async -> SystemTelemetry {
        let battery = getBatteryLevel()
        let temperature = getDeviceTemperature()
        let wifiRssi = getWiFiRSSI()
        let chargingState = getChargingState()
        let thermalState = ProcessInfo.processInfo.thermalState
        let networkBitrate = await getNetworkBitrate()
        let cpuUsage = getCPUUsage()

        return SystemTelemetry(
            battery: battery,
            temperature: temperature,
            wifiRssi: wifiRssi,
            chargingState: chargingState,
            thermalState: thermalState,
            networkBitrate: networkBitrate,
            cpuUsage: cpuUsage
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

    // MARK: - Network Bitrate

    private func getNetworkBitrate() async -> Int {
        let now = Date()
        let currentBytesSent = getNetworkBytesSent()

        // Need at least 2 samples to calculate rate
        guard let lastCheck = lastNetworkCheck else {
            lastNetworkCheck = now
            lastBytesSent = currentBytesSent
            return 0
        }

        let timeInterval = now.timeIntervalSince(lastCheck)
        guard timeInterval > 0 else {
            return 0
        }

        // Calculate bytes sent since last check
        let bytesDelta = currentBytesSent > lastBytesSent
            ? currentBytesSent - lastBytesSent
            : 0

        // Calculate bits per second
        let bitrate = Int((Double(bytesDelta) * 8.0) / timeInterval)

        // Update state for next calculation
        lastNetworkCheck = now
        lastBytesSent = currentBytesSent

        return bitrate
    }

    private func getNetworkBytesSent() -> UInt64 {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        var totalBytesSent: UInt64 = 0

        guard getifaddrs(&ifaddr) == 0 else {
            return 0
        }

        defer {
            freeifaddrs(ifaddr)
        }

        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }

            guard let interface = ptr?.pointee else { continue }

            // Get interface name
            let name = String(cString: interface.ifa_name)

            // We're interested in WiFi (en0) and cellular (pdp_ip0) interfaces
            // Filter out loopback (lo0) and other virtual interfaces
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else {
                continue
            }

            // Check if this is the data link layer (AF_LINK)
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_LINK) else {
                continue
            }

            // Cast to if_data structure to get statistics
            if let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) {
                totalBytesSent += UInt64(data.pointee.ifi_obytes)
            }
        }

        return totalBytesSent
    }

    // MARK: - CPU Usage

    private func getCPUUsage() -> Double {
        var totalUsageOfCPU: Double = 0.0
        var threadsList: thread_act_array_t?
        var threadsCount = mach_msg_type_number_t(0)
        let threadsResult = withUnsafeMutablePointer(to: &threadsList) {
            return $0.withMemoryRebound(to: thread_act_array_t?.self, capacity: 1) {
                task_threads(mach_task_self_, $0, &threadsCount)
            }
        }

        guard threadsResult == KERN_SUCCESS, let threadsList = threadsList else {
            return 0.0
        }

        for index in 0..<threadsCount {
            var threadInfo = thread_basic_info()
            var threadInfoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
            let infoResult = withUnsafeMutablePointer(to: &threadInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                    thread_info(threadsList[Int(index)], thread_flavor_t(THREAD_BASIC_INFO), $0, &threadInfoCount)
                }
            }

            guard infoResult == KERN_SUCCESS else {
                continue
            }

            let threadBasicInfo = threadInfo as thread_basic_info
            if threadBasicInfo.flags & TH_FLAGS_IDLE == 0 {
                totalUsageOfCPU += (Double(threadBasicInfo.cpu_usage) / Double(TH_USAGE_SCALE)) * 100.0
            }
        }

        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadsList)), vm_size_t(Int(threadsCount) * MemoryLayout<thread_t>.stride))

        return totalUsageOfCPU
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
