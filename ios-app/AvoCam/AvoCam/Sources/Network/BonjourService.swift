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
    private var netService: NetService?

    // MARK: - Initialization

    init(alias: String, port: Int) {
        self.alias = alias
        self.port = port
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

    private func createTXTRecord() -> Data? {
        let txtDict: [String: Data] = [
            "alias": alias.data(using: .utf8) ?? Data(),
            "version": "1.0".data(using: .utf8) ?? Data(),
            "protocol": "avocam-v1".data(using: .utf8) ?? Data()
        ]

        return NetService.data(fromTXTRecord: txtDict)
    }

    func updateTXTRecord(_ updates: [String: String]) {
        guard let service = netService else { return }

        var txtDict: [String: Data] = [:]
        for (key, value) in updates {
            txtDict[key] = value.data(using: .utf8) ?? Data()
        }

        service.setTXTRecord(NetService.data(fromTXTRecord: txtDict))
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
