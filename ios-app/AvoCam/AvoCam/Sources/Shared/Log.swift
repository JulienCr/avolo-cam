//
//  Log.swift
//  AvoCam
//
//  Unified logger: os.Logger for unified log + print() in DEBUG for devicectl --console
//

import Foundation
import os.log

struct Log {
    // MARK: - Category Instances

    static let app = Log("App")
    static let capture = Log("Capture")
    static let tally = Log("Tally")
    static let torch = Log("Torch")
    static let ndi = Log("NDI")
    static let srt = Log("SRT")
    static let rtp = Log("RTP")
    static let flash = Log("Flash")
    static let network = Log("Network")
    static let bonjour = Log("Bonjour")
    static let streaming = Log("Streaming")
    static let thermal = Log("Thermal")
    static let ui = Log("UI")
    static let encoder = Log("Encoder")
    static let config = Log("Config")

    // MARK: - Private

    private let category: String
    private let osLog: Logger

    init(_ category: String) {
        self.category = category
        self.osLog = Logger(subsystem: "com.avolo.avolocam", category: category)
    }

    // MARK: - Log Methods

    func debug(_ message: String) {
        #if DEBUG
        print("[\(category)] \(message)")
        #endif
        osLog.debug("\(message, privacy: .public)")
    }

    func info(_ message: String) {
        #if DEBUG
        print("[\(category)] \(message)")
        #endif
        osLog.info("\(message, privacy: .public)")
    }

    func warning(_ message: String) {
        #if DEBUG
        print("⚠️ [\(category)] \(message)")
        #endif
        osLog.warning("\(message, privacy: .public)")
    }

    func error(_ message: String) {
        #if DEBUG
        print("❌ [\(category)] \(message)")
        #endif
        osLog.error("\(message, privacy: .public)")
    }
}
