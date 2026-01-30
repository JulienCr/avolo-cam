//
//  SRTHelpers.swift
//  AvoCam
//
//  SRT streaming utility functions
//

import Foundation

// MARK: - SRT Port Calculation

/// Computes a stable SRT port number based on camera alias
/// This ensures each camera gets a consistent port across restarts
///
/// - Parameters:
///   - alias: Camera alias string (e.g., "AVOLO-CAM-01")
///   - basePort: Base port number (default: 9000)
/// - Returns: Computed port number in range [basePort, basePort+99]
func computeSRTPort(alias: String, basePort: Int = 9000) -> Int {
    let hash = alias.utf8.reduce(0) { ($0 &+ Int($1)) % 100 }
    return basePort + hash
}

// MARK: - SRT Connection URL Builder

/// Builds an SRT connection URL for client connections
///
/// - Parameters:
///   - host: Host IP address or hostname
///   - port: SRT port number
///   - mode: SRT mode (caller/listener/rendezvous)
///   - latency: Latency in milliseconds (optional)
///   - passphrase: Encryption passphrase (optional)
/// - Returns: Formatted SRT URL string
func buildSRTConnectionUrl(
    host: String,
    port: Int,
    mode: String = "caller",
    latency: Int? = nil,
    passphrase: String? = nil
) -> String {
    var components = URLComponents()
    components.scheme = "srt"
    components.host = host
    components.port = port

    var queryItems: [URLQueryItem] = [
        URLQueryItem(name: "mode", value: mode)
    ]

    if let latency = latency {
        queryItems.append(URLQueryItem(name: "latency", value: String(latency)))
    }

    if let passphrase = passphrase {
        queryItems.append(URLQueryItem(name: "passphrase", value: passphrase))
    }

    components.queryItems = queryItems.isEmpty ? nil : queryItems

    return components.url?.absoluteString ?? "srt://\(host):\(port)?mode=\(mode)"
}
