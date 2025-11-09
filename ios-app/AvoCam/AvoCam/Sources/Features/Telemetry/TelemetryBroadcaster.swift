//
//  TelemetryBroadcaster.swift
//  AvoCam
//
//  Maps domain telemetry to WebSocket messages and broadcasts
//

import Foundation

// MARK: - Telemetry Broadcaster

class TelemetryBroadcaster {
    // MARK: - Properties

    private let hub: WebSocketHub
    private let codec: JSONCodec

    // MARK: - Initialization

    init(hub: WebSocketHub, codec: JSONCodec = .shared) {
        self.hub = hub
        self.codec = codec
    }

    // MARK: - Broadcasting

    /// Broadcast telemetry to all connected WebSocket clients
    func broadcast(telemetry: Telemetry, ndiState: NDIState) {
        // Map domain Telemetry to WebSocket message
        let message = WebSocketTelemetryMessage(
            fps: telemetry.fps,
            bitrate: telemetry.bitrate,
            queueMs: telemetry.queueMs ?? 0,
            battery: telemetry.battery,
            tempC: telemetry.tempC,
            wifiRssi: telemetry.wifiRssi,
            cpuUsage: telemetry.cpuUsage,
            ndiState: ndiState,
            droppedFrames: telemetry.droppedFrames ?? 0,
            chargingState: telemetry.chargingState ?? .unplugged
        )

        // Encode to JSON
        guard let jsonString = try? codec.encodeToString(message) else {
            print("⚠️ Failed to encode telemetry message")
            return
        }

        // Broadcast to all clients
        hub.broadcast(text: jsonString)
    }
}
