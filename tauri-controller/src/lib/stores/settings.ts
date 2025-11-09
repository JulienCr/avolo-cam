import { writable, get } from 'svelte/store';
import type { StreamSettings, CameraSettings } from '../types/settings';
import { DEFAULT_STREAM_SETTINGS, DEFAULT_CAMERA_SETTINGS } from '../types/settings';
import type { LensType } from '../types/camera';

// Per-camera stream settings (cameraId -> StreamSettings)
export const cameraStreamSettings = writable<Record<string, StreamSettings>>({});

// Current stream settings being edited
export const currentStreamSettings = writable<StreamSettings>(DEFAULT_STREAM_SETTINGS);

// Current camera settings being edited
export const currentCameraSettings = writable<CameraSettings>(DEFAULT_CAMERA_SETTINGS);

// Saving state
export const savingSettings = writable(false);

// Measuring white balance
export const measuringWB = writable(false);

// Actions
export function getStreamSettings(cameraId: string): StreamSettings {
  const settings = get(cameraStreamSettings);
  if (!settings[cameraId]) {
    updateStreamSettings(cameraId, DEFAULT_STREAM_SETTINGS);
    return DEFAULT_STREAM_SETTINGS;
  }
  return settings[cameraId];
}

export function loadStreamSettingsForEditing(cameraId: string): void {
  const settings = getStreamSettings(cameraId);
  currentStreamSettings.set({ ...settings });
}

export function saveStreamSettingsFromEditing(cameraId: string): void {
  const settings = get(currentStreamSettings);
  updateStreamSettings(cameraId, settings);
}

export function updateStreamSettings(
  cameraId: string,
  settings: Partial<StreamSettings>
): void {
  cameraStreamSettings.update((all) => ({
    ...all,
    [cameraId]: {
      ...(all[cameraId] || DEFAULT_STREAM_SETTINGS),
      ...settings,
    },
  }));
}

export function updateStreamSetting(
  cameraId: string,
  key: keyof StreamSettings,
  value: any
): void {
  cameraStreamSettings.update((all) => ({
    ...all,
    [cameraId]: {
      ...(all[cameraId] || DEFAULT_STREAM_SETTINGS),
      [key]: value,
    },
  }));
}

// Lens detection from zoom factor
export function getLensFromZoom(zoomFactor: number): LensType {
  if (zoomFactor < 1.5) {
    return 'ultra_wide';
  } else if (zoomFactor >= 6.0) {
    return 'telephoto';
  } else {
    return 'wide';
  }
}

// Zoom factor from lens preset
export function getZoomFromLens(lens: LensType): number {
  switch (lens) {
    case 'ultra_wide':
      return 1.0;
    case 'wide':
      return 2.0;
    case 'telephoto':
      return 10.0;
  }
}
