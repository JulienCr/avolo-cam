import type {
  WhiteBalanceMode,
  IsoMode,
  ShutterMode,
  LensType,
  CameraPosition
} from './camera';

// Stream Settings (for starting NDI stream)
export interface StreamSettings {
  resolution: string;
  framerate: number;
  bitrate: number;
  codec: string;
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
  zoom_factor: number;
  lens: LensType;
  camera_position: CameraPosition;
  torch_level?: number;  // NDI tally torch brightness (0.01-1.0)
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
};

export const DEFAULT_CAMERA_SETTINGS: CameraSettings = {
  wb_mode: 'auto',
  wb_kelvin: 5000,
  wb_tint: 0,
  iso_mode: 'auto',
  iso: 400,
  shutter_mode: 'auto',
  shutter_s: 0.01, // 1/100
  zoom_factor: 2.0,
  lens: 'wide',
  camera_position: 'back',
  torch_level: 0.03,  // Default torch brightness
};
