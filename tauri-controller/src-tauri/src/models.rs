//! Data models matching iOS API contracts

use serde::{Deserialize, Serialize};

// MARK: - Camera Status

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatusResponse {
    pub alias: String,
    pub ndi_state: NdiState,
    pub current: CurrentSettings,
    pub telemetry: Telemetry,
    pub capabilities: Vec<Capability>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum NdiState {
    Streaming,
    Idle,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CurrentSettings {
    pub resolution: String,
    pub fps: u32,
    pub bitrate: u32,
    pub codec: String,
    pub wb_mode: WhiteBalanceMode,
    pub wb_kelvin: Option<u32>,
    pub wb_tint: Option<f64>,
    pub iso_mode: ExposureMode,
    pub iso: u32,
    pub shutter_mode: ExposureMode,
    pub shutter_s: f64,
    pub focus_mode: FocusMode,
    pub zoom_factor: f64,
    pub camera_position: String,
    pub lens: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum WhiteBalanceMode {
    Auto,
    Manual,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum FocusMode {
    Auto,
    Manual,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ExposureMode {
    Auto,
    Manual,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Telemetry {
    pub fps: f64,
    pub bitrate: u32,
    pub battery: f64,
    pub temp_c: f64,
    pub wifi_rssi: i32,
    pub cpu_usage: f64,
    pub queue_ms: Option<u32>,
    pub dropped_frames: Option<u32>,
    pub charging_state: Option<ChargingState>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ChargingState {
    Charging,
    Full,
    Unplugged,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Capability {
    pub resolution: String,
    pub fps: Vec<u32>,
    pub codec: Vec<String>,
    pub lens: Option<String>,
    pub max_zoom: Option<f64>,
}

// MARK: - Stream Control

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StreamStartRequest {
    pub resolution: String,
    pub framerate: u32,
    pub bitrate: u32,
    pub codec: String,
}

// MARK: - Camera Control

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CameraSettingsRequest {
    pub wb_mode: Option<WhiteBalanceMode>,
    pub wb_kelvin: Option<u32>,
    pub wb_tint: Option<f64>,
    pub iso_mode: Option<ExposureMode>,
    pub iso: Option<u32>,
    pub shutter_mode: Option<ExposureMode>,
    pub shutter_s: Option<f64>,
    pub focus_mode: Option<FocusMode>,
    pub zoom_factor: Option<f64>,
    pub lens: Option<String>,
    pub camera_position: Option<String>,
    pub orientation_lock: Option<String>,
}

// MARK: - Profiles

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CameraProfile {
    pub name: String,
    pub settings: CameraSettingsRequest,
}

// MARK: - WebSocket Messages

/// Telemetry message sent from iOS camera to controller via WebSocket (1Hz)
/// This is the Server→Client direction of the WebSocket protocol
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WebSocketTelemetryMessage {
    pub fps: f64,
    pub bitrate: u32,
    pub queue_ms: u32,
    pub battery: f64,
    pub temp_c: f64,
    pub wifi_rssi: i32,
    pub cpu_usage: f64,
    pub ndi_state: NdiState,
    pub dropped_frames: u32,
    pub charging_state: ChargingState,
}

/// Command message to be sent from controller to iOS camera via WebSocket
/// This is the Client→Server direction of the WebSocket protocol
///
/// **Status:** Defined but not yet implemented (LOT C - Image Quality & Ops)
///
/// **Purpose:** Enable low-latency camera control commands via WebSocket
/// instead of HTTP POST. Useful for real-time adjustments like manual focus/zoom.
///
/// **Example payload:**
/// ```json
/// {
///   "op": "set",
///   "camera": {
///     "focus_mode": "manual",
///     "zoom_factor": 2.0
///   }
/// }
/// ```
///
/// **To implement:**
/// 1. Modify `CameraClient::connect_websocket()` to support bidirectional communication
/// 2. Add iOS WebSocket handler for incoming commands in `WebSocketHandler.swift`
/// 3. Add Tauri command `send_camera_command_ws()` for frontend to use
///
/// See [DEAD_CODE_ANALYSIS.md](../../DEAD_CODE_ANALYSIS.md#1-websocketcommandmessage) for full implementation guide
#[allow(dead_code)]
pub struct WebSocketCommandMessage {
    pub op: String,
    pub camera: Option<CameraSettingsRequest>,
}

// MARK: - White Balance Measure

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WhiteBalanceMeasureResponse {
    pub scene_cct_k: u32,  // Physical scene illumination temperature
    pub tint: f64,
}

// MARK: - Error Response

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ErrorResponse {
    pub code: String,
    pub message: String,
}

// MARK: - Camera Info

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CameraInfo {
    pub id: String,
    pub alias: String,
    pub ip: String,
    pub port: u16,
    pub token: String,
    pub status: Option<StatusResponse>,
    pub connection_state: ConnectionState,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ConnectionState {
    Connected,
    Disconnected,
    Connecting,
    Error,
}

// MARK: - Discovery

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiscoveredCamera {
    pub alias: String,
    pub ip: String,
    pub port: u16,
    pub txt_records: std::collections::HashMap<String, String>,
}

// MARK: - Group Control

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GroupCommandResult {
    pub camera_id: String,
    pub success: bool,
    pub error: Option<String>,
}
