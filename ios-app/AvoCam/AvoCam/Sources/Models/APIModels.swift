//
//  APIModels.swift
//  AvoCam
//
//  API data models for HTTP/WebSocket communication
//

import Foundation

// MARK: - Streaming Mode

enum StreamingMode: String, Codable, CaseIterable, Sendable {
    case ndi = "ndi"
    case srt = "srt"
    case flash = "flash"
}

// MARK: - Status Response

struct StatusResponse: Codable {
    let alias: String
    let ndiState: NDIState
    let current: CurrentSettings
    let telemetry: Telemetry
    let capabilities: [Capability]
    let tallyProgram: Bool?
    let tallyPreview: Bool?
    let streamingMode: StreamingMode
    let srtConnectionUrl: String?
    let srtPort: Int?
    let flashUdpPort: Int?  // Active UDP port for Flash mode (announced via mDNS)

    enum CodingKeys: String, CodingKey {
        case alias
        case ndiState = "ndi_state"
        case current
        case telemetry
        case capabilities
        case tallyProgram = "tally_program"
        case tallyPreview = "tally_preview"
        case streamingMode = "streaming_mode"
        case srtConnectionUrl = "srt_connection_url"
        case srtPort = "srt_port"
        case flashUdpPort = "flash_udp_port"
    }
}

enum NDIState: String, Codable {
    case streaming
    case idle
}

struct CurrentSettings: Codable {
    var resolution: String
    var fps: Int
    var bitrate: Int
    var codec: String
    var wbMode: WhiteBalanceMode
    var wbKelvin: Int?
    var wbTint: Double?
    var isoMode: ExposureMode
    var iso: Int
    var shutterMode: ExposureMode
    var shutterS: Double
    var focusMode: FocusMode
    var focusDistance: Double?
    var zoomFactor: Double
    var cameraPosition: String  // "back" or "front"
    var lens: String            // "wide", "ultra_wide", "telephoto"
    var streamingMode: StreamingMode
    var srtPort: Int?
    var srtLatency: Int?
    var flashDestinationHost: String?
    var flashDestinationPort: Int?

    enum CodingKeys: String, CodingKey {
        case resolution
        case fps
        case bitrate
        case codec
        case wbMode = "wb_mode"
        case wbKelvin = "wb_kelvin"
        case wbTint = "wb_tint"
        case isoMode = "iso_mode"
        case iso
        case shutterMode = "shutter_mode"
        case shutterS = "shutter_s"
        case focusMode = "focus_mode"
        case focusDistance = "focus_distance"
        case zoomFactor = "zoom_factor"
        case cameraPosition = "camera_position"
        case lens
        case streamingMode = "streaming_mode"
        case srtPort = "srt_port"
        case srtLatency = "srt_latency"
        case flashDestinationHost = "flash_destination_host"
        case flashDestinationPort = "flash_destination_port"
    }
}

enum WhiteBalanceMode: String, Codable {
    case auto
    case manual
}

enum FocusMode: String, Codable {
    case auto
    case manual
}

enum ExposureMode: String, Codable {
    case auto
    case manual
}

struct Telemetry: Codable {
    let fps: Double
    let bitrate: Int
    let battery: Double
    let tempC: Double
    let wifiRssi: Int
    let cpuUsage: Double
    let queueMs: Int?
    let droppedFrames: Int?
    let chargingState: ChargingState?

    enum CodingKeys: String, CodingKey {
        case fps
        case bitrate
        case battery
        case tempC = "temp_c"
        case wifiRssi = "wifi_rssi"
        case cpuUsage = "cpu_usage"
        case queueMs = "queue_ms"
        case droppedFrames = "dropped_frames"
        case chargingState = "charging_state"
    }

    /// Default telemetry with zeroed counters and neutral sensor values.
    ///
    /// Used as a placeholder before the first real telemetry collection cycle completes.
    static func makeDefault() -> Telemetry {
        return Telemetry(
            fps: 0,
            bitrate: 0,
            battery: 1.0,
            tempC: 25.0,
            wifiRssi: -50,
            cpuUsage: 0,
            queueMs: nil,
            droppedFrames: nil,
            chargingState: nil
        )
    }
}

enum ChargingState: String, Codable {
    case charging
    case full
    case unplugged
}

struct Capability: Codable {
    let resolution: String
    let fps: [Int]
    let codec: [String]
    let lens: String?
    let maxZoom: Double?

    enum CodingKeys: String, CodingKey {
        case resolution
        case fps
        case codec
        case lens
        case maxZoom = "max_zoom"
    }
}

// MARK: - Stream Control

struct StreamStartRequest: Codable {
    let resolution: String
    let framerate: Int
    let bitrate: Int
    let codec: String
    let streamingMode: StreamingMode?
    let srtPort: Int?
    let srtLatency: Int?
    let srtRcvLatency: Int?    // Receive latency in ms (nil = use srtLatency)
    let srtPeerLatency: Int?   // Peer latency in ms (nil = use srtLatency)
    let srtTlPktDrop: Bool?    // Drop too-late packets
    let srtPassphrase: String?
    let srtGopSize: Int?       // GOP in frames

    // Flash mode settings
    let flashDestinationHost: String?  // Target host for UDP packets (required for flash)
    let flashDestinationPort: Int?     // Target UDP port (default 5000)
    let flashJitterMode: String?       // "ultra_low" or "stable" (hint for receiver)

    enum CodingKeys: String, CodingKey {
        case resolution
        case framerate
        case bitrate
        case codec
        case streamingMode = "streaming_mode"
        case srtPort = "srt_port"
        case srtLatency = "srt_latency"
        case srtRcvLatency = "srt_rcv_latency"
        case srtPeerLatency = "srt_peer_latency"
        case srtTlPktDrop = "srt_tlpktdrop"
        case srtPassphrase = "srt_passphrase"
        case srtGopSize = "srt_gop_size"
        case flashDestinationHost = "flash_destination_host"
        case flashDestinationPort = "flash_destination_port"
        case flashJitterMode = "flash_jitter_mode"
    }
}

// MARK: - Camera Control

struct CameraSettingsRequest: Codable {
    let wbMode: WhiteBalanceMode?
    let wbKelvin: Int?
    let wbTint: Double?
    let isoMode: ExposureMode?
    let iso: Int?
    let shutterMode: ExposureMode?
    let shutterS: Double?
    let focusMode: FocusMode?
    let focusDistance: Double?
    let zoomFactor: Double?
    let cameraPosition: String?
    let lens: String?
    let orientationLock: String?
    let torchLevel: Float?

    enum CodingKeys: String, CodingKey {
        case wbMode = "wb_mode"
        case wbKelvin = "wb_kelvin"
        case wbTint = "wb_tint"
        case isoMode = "iso_mode"
        case iso
        case shutterMode = "shutter_mode"
        case shutterS = "shutter_s"
        case focusMode = "focus_mode"
        case focusDistance = "focus_distance"
        case zoomFactor = "zoom_factor"
        case cameraPosition = "camera_position"
        case lens
        case orientationLock = "orientation_lock"
        case torchLevel = "torch_level"
    }
}

// MARK: - Screen Control

struct ScreenBrightnessRequest: Codable {
    let dimmed: Bool
}

// MARK: - White Balance Measure

struct WhiteBalanceMeasureResponse: Codable {
    let sceneCCT_K: Int  // Physical scene illumination temperature (Apple's value)
    let tint: Double

    enum CodingKeys: String, CodingKey {
        case sceneCCT_K = "scene_cct_k"
        case tint
    }
}

// MARK: - WebSocket Messages

struct WebSocketTelemetryMessage: Codable {
    let fps: Double
    let bitrate: Int
    let queueMs: Int
    let battery: Double
    let tempC: Double
    let wifiRssi: Int
    let cpuUsage: Double
    let ndiState: NDIState
    let droppedFrames: Int
    let chargingState: ChargingState
    let flashUdpPort: Int?  // Active Flash UDP port for OBS auto-discovery

    enum CodingKeys: String, CodingKey {
        case fps
        case bitrate
        case queueMs = "queue_ms"
        case battery
        case tempC = "temp_c"
        case wifiRssi = "wifi_rssi"
        case cpuUsage = "cpu_usage"
        case ndiState = "ndi_state"
        case droppedFrames = "dropped_frames"
        case chargingState = "charging_state"
        case flashUdpPort = "flash_udp_port"
    }
}

struct WebSocketCommandMessage: Codable {
    let op: String
    let camera: CameraSettingsRequest?
}

/// Tally message received from OBS plugin via WebSocket
/// OBS sends: {"op":"tally","program":true,"preview":false}
struct WebSocketTallyMessage: Codable {
    let op: String  // "tally"
    let program: Bool
    let preview: Bool
}

struct WebSocketFrameInfo: Codable {
    let op: String  // "frame_info"
    let frameIdx: Int64
    let rtpTimestamp: UInt32  // RTP timestamp (90kHz clock) for correlating with RTP packets
    let captureTs: Int64  // nanoseconds since boot
    let encodeTs: Int64   // nanoseconds since boot

    enum CodingKeys: String, CodingKey {
        case op
        case frameIdx = "frame_idx"
        case rtpTimestamp = "rtp_ts"
        case captureTs = "capture_ts_ns"
        case encodeTs = "encode_ts_ns"
    }
}

// MARK: - Video Settings

struct VideoPresetResponse: Codable {
    let id: String
    let name: String
    let resolution: String
    let fps: Int
    let codec: String
    let bitrate: Int
}

struct VideoSettingsResponse: Codable {
    let selectedPresetId: String?
    let customResolution: String?
    let customFps: Int?
    let customCodec: String?
    let customBitrate: Int?
    let availablePresets: [VideoPresetResponse]

    enum CodingKeys: String, CodingKey {
        case selectedPresetId = "selected_preset_id"
        case customResolution = "custom_resolution"
        case customFps = "custom_fps"
        case customCodec = "custom_codec"
        case customBitrate = "custom_bitrate"
        case availablePresets = "available_presets"
    }
}

struct VideoSettingsUpdateRequest: Codable {
    let selectedPresetId: String?
    let customResolution: String?
    let customFps: Int?
    let customCodec: String?
    let customBitrate: Int?

    enum CodingKeys: String, CodingKey {
        case selectedPresetId = "selected_preset_id"
        case customResolution = "custom_resolution"
        case customFps = "custom_fps"
        case customCodec = "custom_codec"
        case customBitrate = "custom_bitrate"
    }
}

// MARK: - Settings Control

struct AliasUpdateRequest: Codable {
    let alias: String
}

struct AliasUpdateResponse: Codable {
    let alias: String
    let requiresRestart: Bool

    enum CodingKeys: String, CodingKey {
        case alias
        case requiresRestart = "requires_restart"
    }
}

// MARK: - Torch Control

struct TorchLevelResponse: Codable {
    let currentLevel: Float
    let defaultLevel: Float
    let deviceModel: String

    enum CodingKeys: String, CodingKey {
        case currentLevel = "current_level"
        case defaultLevel = "default_level"
        case deviceModel = "device_model"
    }
}

struct TorchLevelUpdateRequest: Codable {
    let level: Float?  // nil to reset to default

    enum CodingKeys: String, CodingKey {
        case level
    }
}

// MARK: - Error Response

struct ErrorResponse: Codable {
    let code: String
    let message: String
}
