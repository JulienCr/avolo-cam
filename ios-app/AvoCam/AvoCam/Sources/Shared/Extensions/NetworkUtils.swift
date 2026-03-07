//
//  NetworkUtils.swift
//  AvoCam
//
//  Network utility functions extracted from AppCoordinator
//

import Foundation

enum NetworkUtils {
    /// Detects the local IP address by iterating network interfaces.
    /// Returns the first IPv4 address found on an `en*` interface, or nil.
    static func detectLocalIPAddress() -> String? {
        var address: String?

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else {
            return nil
        }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }

            guard let interface = ptr else { continue }
            let addrFamily = interface.pointee.ifa_addr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) || addrFamily == UInt8(AF_INET6) {
                let name = String(cString: interface.pointee.ifa_name)

                if name == "en0" || name == "en1" || name.hasPrefix("en") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))

                    if getnameinfo(
                        interface.pointee.ifa_addr,
                        socklen_t(interface.pointee.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        socklen_t(0),
                        NI_NUMERICHOST
                    ) == 0 {
                        address = String(cString: hostname)
                        if addrFamily == UInt8(AF_INET) {
                            break
                        }
                    }
                }
            }
        }

        return address
    }
}
