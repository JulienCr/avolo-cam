//
//  APIModelsTests.swift
//  AvoCamTests
//
//  Tests for API model encode/decode round-trips
//

import XCTest
@testable import AvoCam

final class APIModelsTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - StatusResponse

    func testStatusResponseRoundTrip() throws {
        let original = StatusResponse(
            alias: "AVOLO-CAM-A3",
            ndiState: .streaming,
            current: makeCurrentSettings(),
            telemetry: makeTelemetry(),
            capabilities: [
                Capability(resolution: "1920x1080", fps: [25, 30, 60], codec: ["h264", "hevc"], lens: "wide", maxZoom: 10.0)
            ],
            tallyProgram: true,
            tallyPreview: false,
            streamingMode: .ndi,
            srtConnectionUrl: nil,
            srtPort: nil,
            flashUdpPort: nil
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(StatusResponse.self, from: data)

        XCTAssertEqual(decoded.alias, "AVOLO-CAM-A3")
        XCTAssertEqual(decoded.ndiState, .streaming)
        XCTAssertEqual(decoded.current.resolution, "1920x1080")
        XCTAssertEqual(decoded.telemetry.fps, 29.97)
        XCTAssertEqual(decoded.capabilities.count, 1)
        XCTAssertEqual(decoded.tallyProgram, true)
        XCTAssertEqual(decoded.tallyPreview, false)
        XCTAssertEqual(decoded.streamingMode, .ndi)
    }

    func testStatusResponseWithSRT() throws {
        let original = StatusResponse(
            alias: "AVOLO-CAM-01",
            ndiState: .idle,
            current: makeCurrentSettings(),
            telemetry: makeTelemetry(),
            capabilities: [],
            tallyProgram: nil,
            tallyPreview: nil,
            streamingMode: .srt,
            srtConnectionUrl: "srt://192.168.1.100:9000",
            srtPort: 9000,
            flashUdpPort: nil
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(StatusResponse.self, from: data)

        XCTAssertEqual(decoded.streamingMode, .srt)
        XCTAssertEqual(decoded.srtConnectionUrl, "srt://192.168.1.100:9000")
        XCTAssertEqual(decoded.srtPort, 9000)
        XCTAssertNil(decoded.tallyProgram)
    }

    // MARK: - StreamStartRequest

    func testStreamStartRequestRoundTrip() throws {
        let original = StreamStartRequest(
            resolution: "1920x1080",
            framerate: 30,
            bitrate: 10_000_000,
            codec: "h264",
            streamingMode: .ndi,
            srtPort: nil,
            srtLatency: nil,
            srtRcvLatency: nil,
            srtPeerLatency: nil,
            srtTlPktDrop: nil,
            srtPassphrase: nil,
            srtGopSize: nil,
            flashDestinationHost: nil,
            flashDestinationPort: nil,
            flashJitterMode: nil
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(StreamStartRequest.self, from: data)

        XCTAssertEqual(decoded.resolution, "1920x1080")
        XCTAssertEqual(decoded.framerate, 30)
        XCTAssertEqual(decoded.bitrate, 10_000_000)
        XCTAssertEqual(decoded.codec, "h264")
        XCTAssertEqual(decoded.streamingMode, .ndi)
    }

    func testStreamStartRequestWithSRTFields() throws {
        let original = StreamStartRequest(
            resolution: "3840x2160",
            framerate: 25,
            bitrate: 26_000_000,
            codec: "h264",
            streamingMode: .srt,
            srtPort: 9000,
            srtLatency: 120,
            srtRcvLatency: 200,
            srtPeerLatency: 150,
            srtTlPktDrop: true,
            srtPassphrase: "secret123",
            srtGopSize: 25,
            flashDestinationHost: nil,
            flashDestinationPort: nil,
            flashJitterMode: nil
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(StreamStartRequest.self, from: data)

        XCTAssertEqual(decoded.srtPort, 9000)
        XCTAssertEqual(decoded.srtLatency, 120)
        XCTAssertEqual(decoded.srtRcvLatency, 200)
        XCTAssertEqual(decoded.srtPeerLatency, 150)
        XCTAssertEqual(decoded.srtTlPktDrop, true)
        XCTAssertEqual(decoded.srtPassphrase, "secret123")
        XCTAssertEqual(decoded.srtGopSize, 25)
    }

    // MARK: - Telemetry

    func testTelemetryRoundTrip() throws {
        let original = makeTelemetry()

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(Telemetry.self, from: data)

        XCTAssertEqual(decoded.fps, 29.97, accuracy: 0.001)
        XCTAssertEqual(decoded.bitrate, 9_800_000)
        XCTAssertEqual(decoded.battery, 0.82, accuracy: 0.001)
        XCTAssertEqual(decoded.tempC, 38.4, accuracy: 0.001)
        XCTAssertEqual(decoded.wifiRssi, -55)
        XCTAssertEqual(decoded.cpuUsage, 45.2, accuracy: 0.001)
        XCTAssertEqual(decoded.queueMs, 12)
        XCTAssertEqual(decoded.droppedFrames, 3)
        XCTAssertEqual(decoded.chargingState, .charging)
    }

    func testTelemetryMakeDefault() {
        let telemetry = Telemetry.makeDefault()
        XCTAssertEqual(telemetry.fps, 0.0)
        XCTAssertEqual(telemetry.bitrate, 0)
        XCTAssertEqual(telemetry.battery, 1.0)
        XCTAssertEqual(telemetry.tempC, 25.0)
        XCTAssertNil(telemetry.wifiRssi)
        XCTAssertEqual(telemetry.cpuUsage, 0.0)
        XCTAssertNil(telemetry.queueMs)
        XCTAssertNil(telemetry.droppedFrames)
        XCTAssertNil(telemetry.chargingState)
    }

    // MARK: - ErrorResponse

    func testErrorResponseRoundTrip() throws {
        let original = ErrorResponse(code: "RATE_LIMITED", message: "Too many camera updates, wait 50ms")

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ErrorResponse.self, from: data)

        XCTAssertEqual(decoded.code, "RATE_LIMITED")
        XCTAssertEqual(decoded.message, "Too many camera updates, wait 50ms")
    }

    // MARK: - CameraSettingsRequest

    func testCameraSettingsRequestRoundTrip() throws {
        let original = CameraSettingsRequest(
            wbMode: .manual,
            wbKelvin: 5000,
            wbTint: 0.5,
            isoMode: .manual,
            iso: 160,
            shutterMode: .manual,
            shutterS: 0.01,
            focusMode: .auto,
            focusDistance: nil,
            zoomFactor: 2.5,
            cameraPosition: "back",
            lens: "wide",
            orientationLock: "landscape",
            torchLevel: 0.8
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(CameraSettingsRequest.self, from: data)

        XCTAssertEqual(decoded.wbMode, .manual)
        XCTAssertEqual(decoded.wbKelvin, 5000)
        XCTAssertEqual(decoded.iso, 160)
        XCTAssertEqual(decoded.zoomFactor, 2.5)
        XCTAssertEqual(decoded.torchLevel, 0.8)
    }

    // MARK: - WebSocketTelemetryMessage

    func testWebSocketTelemetryMessageRoundTrip() throws {
        let original = WebSocketTelemetryMessage(
            fps: 29.97,
            bitrate: 9_800_000,
            queueMs: 12,
            battery: 0.82,
            tempC: 38.4,
            wifiRssi: -55,
            cpuUsage: 45.2,
            ndiState: .streaming,
            droppedFrames: 3,
            chargingState: .charging,
            flashUdpPort: nil
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(WebSocketTelemetryMessage.self, from: data)

        XCTAssertEqual(decoded.fps, 29.97, accuracy: 0.001)
        XCTAssertEqual(decoded.ndiState, .streaming)
        XCTAssertEqual(decoded.chargingState, .charging)
    }

    // MARK: - JSON Key Mapping

    func testSnakeCaseKeyMapping() throws {
        let json = """
        {
            "code": "NOT_FOUND",
            "message": "Endpoint not found"
        }
        """.data(using: .utf8)!

        let decoded = try decoder.decode(ErrorResponse.self, from: json)
        XCTAssertEqual(decoded.code, "NOT_FOUND")
    }

    func testTelemetryCodingKeys() throws {
        let json = """
        {
            "fps": 30.0,
            "bitrate": 10000000,
            "battery": 0.95,
            "temp_c": 35.0,
            "wifi_rssi": -40,
            "cpu_usage": 20.0,
            "queue_ms": 5,
            "dropped_frames": 0,
            "charging_state": "full"
        }
        """.data(using: .utf8)!

        let decoded = try decoder.decode(Telemetry.self, from: json)
        XCTAssertEqual(decoded.tempC, 35.0)
        XCTAssertEqual(decoded.wifiRssi, -40)
        XCTAssertEqual(decoded.cpuUsage, 20.0)
        XCTAssertEqual(decoded.chargingState, .full)
    }

    // MARK: - Helpers

    private func makeCurrentSettings() -> CurrentSettings {
        CurrentSettings(
            resolution: "1920x1080",
            fps: 30,
            bitrate: 10_000_000,
            codec: "h264",
            wbMode: .manual,
            wbKelvin: 5000,
            wbTint: nil,
            isoMode: .manual,
            iso: 160,
            shutterMode: .manual,
            shutterS: 0.01,
            focusMode: .auto,
            focusDistance: nil,
            zoomFactor: 1.0,
            cameraPosition: "back",
            lens: "wide",
            streamingMode: .ndi,
            srtPort: nil,
            srtLatency: nil
        )
    }

    private func makeTelemetry() -> Telemetry {
        Telemetry(
            fps: 29.97,
            bitrate: 9_800_000,
            battery: 0.82,
            tempC: 38.4,
            wifiRssi: -55,
            cpuUsage: 45.2,
            queueMs: 12,
            droppedFrames: 3,
            chargingState: .charging
        )
    }
}
