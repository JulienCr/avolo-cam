export interface Telemetry {
  fps: number;
  bitrate: number;
  battery: number; // 0.0-1.0
  temp_c: number;
  wifi_rssi?: number;
  cpu_usage: number; // 0.0 to 100.0+ percentage
  queue_ms?: number;
  dropped_frames?: number;
  charging_state?: 'charging' | 'full' | 'unplugged';
}

export type NdiState = 'streaming' | 'idle' | 'unknown';
export type WhiteBalanceMode = 'auto' | 'manual';
export type IsoMode = 'auto' | 'manual';
export type ShutterMode = 'auto' | 'manual';
export type TorchMode = 'auto' | 'manual';
export type CameraPosition = 'front' | 'back';
export type LensType = 'ultra_wide' | 'wide' | 'telephoto';

export interface CurrentSettings {
  resolution?: string;
  fps?: number;
  bitrate?: number;
  codec?: string;
  wb_mode?: WhiteBalanceMode;
  wb_kelvin?: number;
  wb_tint?: number;
  iso_mode?: IsoMode;
  iso?: number;
  shutter_mode?: ShutterMode;
  shutter_s?: number;
  zoom_factor?: number;
  lens?: LensType;
  camera_position?: CameraPosition;
  torch_level?: number;  // NDI tally torch brightness (0.01-1.0)
}

export interface CameraStatus {
  ndi_state: NdiState;
  current: CurrentSettings;
  telemetry: Telemetry;
}

export interface Camera {
  id: string;
  alias: string;
  ip: string;
  port: number;
  status: CameraStatus | null;
}

export interface DiscoveredCamera {
  alias: string;
  ip: string;
  port: number;
  txt_records?: { [key: string]: string };
}
