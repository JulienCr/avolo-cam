import type { WhiteBalanceMode, IsoMode, ShutterMode, LensType } from './camera';

export interface ProfileSettings {
  wb_mode: WhiteBalanceMode;
  wb_kelvin?: number | null;
  wb_tint?: number | null;
  iso_mode: IsoMode;
  iso?: number | null;
  shutter_mode: ShutterMode;
  shutter_s?: number | null;
  zoom_factor: number;
  lens: LensType;
}

export interface Profile {
  name: string;
  settings: ProfileSettings;
}

export interface GroupOperationResult {
  camera_id: string;
  success: boolean;
  error?: string;
}
