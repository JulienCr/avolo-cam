import type {
  WhiteBalanceMode,
  IsoMode,
  ShutterMode,
  FocusMode,
  TorchMode,
  LensType,
  CameraPosition,
  StreamingMode,
  FlashJitterMode
} from './camera';

// Stream Settings (for starting NDI/SRT/Flash stream)
export interface StreamSettings {
  resolution: string;
  framerate: number;
  bitrate: number;
  codec: string;
  streaming_mode?: StreamingMode;
  // SRT settings
  srt_port?: number;
  srt_latency?: number;
  srt_rcv_latency?: number;   // Receive latency in ms (null = use srt_latency)
  srt_peer_latency?: number;  // Peer latency in ms (null = use srt_latency)
  srt_tlpktdrop?: boolean;    // Drop too-late packets
  srt_gop_size?: number;      // GOP in frames (default = fps = 1 second)
  // Flash mode settings
  flash_destination_host?: string;  // Required for flash mode
  flash_destination_port?: number;  // Default 5000
  flash_jitter_mode?: FlashJitterMode;  // "ultra_low" or "stable"
}

// Camera Settings (for camera controls)
export interface CameraSettings {
  wb_mode: WhiteBalanceMode;
  wb_kelvin: number;
  wb_tint: number;
  iso_mode: IsoMode;
  iso: number;
  shutter_mode: ShutterMode;
  shutter_s: number;
  focus_mode: FocusMode;
  focus_distance: number;
  zoom_factor: number;
  lens: LensType;
  camera_position: CameraPosition;
  torch_mode: TorchMode;
  torch_level: number;  // NDI tally torch brightness (0.01-1.0)
}

// White Balance Measurement Result
export interface WhiteBalanceResult {
  scene_cct_k: number;  // Scene color temperature in Kelvin
  tint: number;         // Tint adjustment value
}

// Default Values
export const DEFAULT_STREAM_SETTINGS: StreamSettings = {
  resolution: '1920x1080',
  framerate: 30,
  bitrate: 10000000, // 10 Mbps
  codec: 'h264',
  streaming_mode: 'flash',
  // SRT defaults
  srt_port: 9000,
  srt_latency: 120,
  srt_rcv_latency: undefined,  // Use srt_latency
  srt_peer_latency: undefined, // Use srt_latency
  srt_tlpktdrop: true,
  srt_gop_size: 30,  // 1 second GOP for stable OBS playback
  // Flash defaults
  flash_destination_port: 5000,
  flash_jitter_mode: 'stable',
};

export const DEFAULT_CAMERA_SETTINGS: CameraSettings = {
  wb_mode: 'auto',
  wb_kelvin: 5000,
  wb_tint: 0,
  iso_mode: 'auto',
  iso: 400,
  shutter_mode: 'auto',
  shutter_s: 0.01, // 1/100
  focus_mode: 'auto',
  focus_distance: 0.5,  // Midpoint (0.0=near, 1.0=far)
  zoom_factor: 2.0,
  lens: 'wide',
  camera_position: 'back',
  torch_mode: 'auto',
  torch_level: 0.03,  // Default torch brightness
};
