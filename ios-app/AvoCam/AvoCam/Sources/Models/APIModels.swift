//
//  APIModels.swift
//  AvoCam
//
//  API data models for HTTP/WebSocket communication
//

import Foundation

// MARK: - Status Response

struct StatusResponse: Codable {
    let alias: String
    let ndiState: NDIState
    let current: CurrentSettings
    let telemetry: Telemetry
    let capabilities: [Capability]

    enum CodingKeys: String, CodingKey {
        case alias
        case ndiState = "ndi_state"
        case current
        case telemetry
        case capabilities
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
    var iso: Int
    var shutterS: Double
    var focusMode: FocusMode
    var zoomFactor: Double

    enum CodingKeys: String, CodingKey {
        case resolution
        case fps
        case bitrate
        case codec
        case wbMode = "wb_mode"
        case wbKelvin = "wb_kelvin"
        case wbTint = "wb_tint"
        case iso
        case shutterS = "shutter_s"
        case focusMode = "focus_mode"
        case zoomFactor = "zoom_factor"
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

struct Telemetry: Codable {
    let fps: Double
    let bitrate: Int
    let battery: Double
    let tempC: Double
    let wifiRssi: Int
    let queueMs: Int?
    let droppedFrames: Int?
    let chargingState: ChargingState?

    enum CodingKeys: String, CodingKey {
        case fps
        case bitrate
        case battery
        case tempC = "temp_c"
        case wifiRssi = "wifi_rssi"
        case queueMs = "queue_ms"
        case droppedFrames = "dropped_frames"
        case chargingState = "charging_state"
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
}

// MARK: - Camera Control

struct CameraSettingsRequest: Codable {
    let wbMode: WhiteBalanceMode?
    let wbKelvin: Int?
    let wbTint: Double?
    let iso: Int?
    let shutterS: Double?
    let focusMode: FocusMode?
    let zoomFactor: Double?
    let lens: String?
    let orientationLock: String?

    enum CodingKeys: String, CodingKey {
        case wbMode = "wb_mode"
        case wbKelvin = "wb_kelvin"
        case wbTint = "wb_tint"
        case iso
        case shutterS = "shutter_s"
        case focusMode = "focus_mode"
        case zoomFactor = "zoom_factor"
        case lens
        case orientationLock = "orientation_lock"
    }
}

// MARK: - Screen Control

struct ScreenBrightnessRequest: Codable {
    let dimmed: Bool
}

// MARK: - WebSocket Messages

struct WebSocketTelemetryMessage: Codable {
    let fps: Double
    let bitrate: Int
    let queueMs: Int
    let battery: Double
    let tempC: Double
    let wifiRssi: Int
    let ndiState: NDIState
    let droppedFrames: Int
    let chargingState: ChargingState

    enum CodingKeys: String, CodingKey {
        case fps
        case bitrate
        case queueMs = "queue_ms"
        case battery
        case tempC = "temp_c"
        case wifiRssi = "wifi_rssi"
        case ndiState = "ndi_state"
        case droppedFrames = "dropped_frames"
        case chargingState = "charging_state"
    }
}

struct WebSocketCommandMessage: Codable {
    let op: String
    let camera: CameraSettingsRequest?
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

// MARK: - Error Response

struct ErrorResponse: Codable {
    let code: String
    let message: String
}
