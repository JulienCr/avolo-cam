import type { WhiteBalanceMode, IsoMode, ShutterMode, CameraPosition, LensType } from './camera';

export interface StreamSettings {
  resolution: string;
  framerate: number;
  bitrate: number;
  codec: string;
}

export const DEFAULT_STREAM_SETTINGS: StreamSettings = {
  resolution: '1920x1080',
  framerate: 25,
  bitrate: 10000000,
  codec: 'h264',
};

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
}

export const DEFAULT_CAMERA_SETTINGS: CameraSettings = {
  wb_mode: 'auto',
  wb_kelvin: 5000,
  wb_tint: 0,
  iso_mode: 'auto',
  iso: 400,
  shutter_mode: 'auto',
  shutter_s: 0.01,
  zoom_factor: 2.0,
  lens: 'wide',
  camera_position: 'back',
};

export interface WhiteBalanceResult {
  scene_cct_k: number;
  tint: number;
}
