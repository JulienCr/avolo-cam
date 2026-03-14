//
//  BonjourService.swift
//  AvoCam
//
//  Handles Bonjour/mDNS service advertisement
//

import Foundation

class BonjourService: NSObject {
    // MARK: - Properties

    private let alias: String
    private let port: Int
    private let bearerToken: String
    private var netService: NetService?
    private var flashUdpPort: UInt16 = 0  // Dynamic Flash UDP port

    // MARK: - Initialization

    init(alias: String, port: Int, bearerToken: String) {
        self.alias = alias
        self.port = port
        self.bearerToken = bearerToken
        super.init()
    }

    // MARK: - Service Control

    func start() {
        // Create NetService for _avolocam._tcp
        let service = NetService(
            domain: "local.",
            type: "_avolocam._tcp.",
            name: alias,
            port: Int32(port)
        )

        service.delegate = self

        // Set TXT record with metadata
        let txtData = createTXTRecord()
        service.setTXTRecord(txtData)

        // Publish service
        service.publish()

        netService = service

        print("📢 Bonjour service publishing: \(alias) on port \(port)")
    }

    func stop() {
        netService?.stop()
        netService = nil
        print("🔇 Bonjour service stopped")
    }

    // MARK: - TXT Record

    /// Builds the base TXT record dictionary shared by all TXT record operations.
    ///
    /// - Note: The bearer token is intentionally included in the mDNS TXT record.
    ///   This is by design for zero-configuration discovery: the Tauri controller
    ///   resolves `_avolocam._tcp` services on the local network and reads the token
    ///   from the TXT record to auto-authenticate against the camera's REST API and
    ///   WebSocket. mDNS is inherently local-network-only, so the token is only
    ///   visible to devices on the same LAN/WLAN segment -- the same trust boundary
    ///   that already has direct IP access to the camera.
    private func baseTXTDictionary() -> [String: Data] {
        // TODO: width, height, fps, codec, and profile are placeholders.
        // These should reflect the actual active stream configuration.
        // Currently updateStreamInfo() exists but is never called from
        // AppCoordinator when a stream starts. Wire it up so the TXT
        // record advertises real values once streaming begins.
        var dict: [String: Data] = [
            "alias": alias.data(using: .utf8) ?? Data(),
            "version": "1.0".data(using: .utf8) ?? Data(),
            "protocol": "avocam-v1".data(using: .utf8) ?? Data(),
            "token": bearerToken.data(using: .utf8) ?? Data(),
            "ws_port": "\(port)".data(using: .utf8) ?? Data(),
            "width": "1920".data(using: .utf8) ?? Data(),
            "height": "1080".data(using: .utf8) ?? Data(),
            "fps": "25".data(using: .utf8) ?? Data(),
            "codec": "h264".data(using: .utf8) ?? Data(),
            "profile": "high".data(using: .utf8) ?? Data()
        ]
        if flashUdpPort > 0 {
            dict["flash_udp_port"] = "\(flashUdpPort)".data(using: .utf8) ?? Data()
        }
        return dict
    }

    private func createTXTRecord() -> Data? {
        return NetService.data(fromTXTRecord: baseTXTDictionary())
    }

    func updateTXTRecord(_ updates: [String: String]) {
        guard let service = netService else { return }

        var txtDict = baseTXTDictionary()
        for (key, value) in updates {
            txtDict[key] = value.data(using: .utf8) ?? Data()
        }

        service.setTXTRecord(NetService.data(fromTXTRecord: txtDict))
    }

    /// Update stream info dynamically when stream configuration changes.
    func updateStreamInfo(width: Int, height: Int, fps: Int, spsHash: String? = nil) {
        var updates: [String: String] = [
            "width": "\(width)",
            "height": "\(height)",
            "fps": "\(fps)"
        ]
        if let hash = spsHash {
            updates["sps_hash"] = hash
        }
        updateTXTRecord(updates)
    }

    /// Update Flash UDP port in mDNS announcement.
    /// - Parameter port: UDP port used for Flash streaming (0 to clear)
    func updateFlashPort(_ port: UInt16) {
        flashUdpPort = port

        guard let service = netService else { return }

        service.setTXTRecord(NetService.data(fromTXTRecord: baseTXTDictionary()))

        print("Updated Flash UDP port in mDNS: \(port > 0 ? "\(port)" : "cleared")")
    }
}

// MARK: - NetServiceDelegate

extension BonjourService: NetServiceDelegate {
    func netServiceWillPublish(_ sender: NetService) {
        print("📢 Bonjour service will publish: \(sender.name)")
    }

    func netServiceDidPublish(_ sender: NetService) {
        print("✅ Bonjour service published: \(sender.name)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        print("❌ Bonjour service failed to publish: \(errorDict)")
    }

    func netServiceDidStop(_ sender: NetService) {
        print("⏹ Bonjour service stopped: \(sender.name)")
    }
}
