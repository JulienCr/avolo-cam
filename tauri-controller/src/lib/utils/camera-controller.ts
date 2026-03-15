import type { Camera } from '$lib/types/camera';
import type { StreamSettings, CameraSettings } from '$lib/types/settings';
import { DEFAULT_CAMERA_SETTINGS, DEFAULT_STREAM_SETTINGS } from '$lib/types/settings';
import { getStreamSettings, updateStreamSettings } from '$lib/stores/settings';
import * as api from '$lib/utils/api';
import { debounce } from '$lib/utils/debounce';
import { toastError } from '$lib/stores/toast';

function toCameraSettings(source: Partial<CameraSettings>): CameraSettings {
  return { ...DEFAULT_CAMERA_SETTINGS, ...source, torch_mode: 'auto' };
}

function buildCameraPayload(cs: CameraSettings): Record<string, any> {
  const payload: Record<string, any> = {
    wb_mode: cs.wb_mode,
    iso_mode: cs.iso_mode,
    shutter_mode: cs.shutter_mode,
    focus_mode: cs.focus_mode,
    zoom_factor: cs.zoom_factor,
    lens: cs.lens,
    camera_position: cs.camera_position,
  };
  if (cs.wb_mode === 'manual') {
    payload.wb_kelvin = cs.wb_kelvin;
    payload.wb_tint = cs.wb_tint;
  }
  if (cs.iso_mode === 'manual') {
    payload.iso = cs.iso;
  }
  if (cs.shutter_mode === 'manual') {
    payload.shutter_s = cs.shutter_s;
  }
  if (cs.focus_mode === 'manual') {
    payload.focus_distance = cs.focus_distance;
  }
  if (cs.torch_mode === 'manual') {
    payload.torch_level = cs.torch_level;
  }
  return payload;
}

export async function measureWB(
  cameraId: string,
  applyResult: (kelvin: number, tint: number) => void
): Promise<void> {
  const result = await api.measureWhiteBalance(cameraId);
  applyResult(result.scene_cct_k, Math.round(result.tint));
}

export function initStreamSettings(camera: Camera): StreamSettings {
  return getStreamSettings(camera.id);
}

export function initCameraSettings(camera: Camera): CameraSettings {
  return camera.status?.current
    ? toCameraSettings(camera.status.current as Partial<CameraSettings>)
    : { ...DEFAULT_CAMERA_SETTINGS };
}

export async function loadPersistedSettings(camera: Camera): Promise<CameraSettings | null> {
  if (!camera.status?.current) {
    try {
      const persisted = await api.getPersistedCameraSettings(camera.id);
      if (persisted) {
        return toCameraSettings(persisted as Partial<CameraSettings>);
      }
    } catch (e) {
      console.warn('Could not load persisted camera settings:', e);
    }
  }
  return null;
}

/**
 * Load persisted stream settings from Rust backend and merge into the in-memory store.
 * Returns the merged settings so the caller can update its local state.
 */
export async function loadPersistedStreamSettings(camera: Camera): Promise<StreamSettings | null> {
  try {
    const persisted = await api.getPersistedStreamSettings(camera.id);
    if (persisted) {
      const current = getStreamSettings(camera.id);
      const merged: StreamSettings = { ...DEFAULT_STREAM_SETTINGS, ...current, ...persisted };
      // Update the store so future getStreamSettings calls return the persisted values
      updateStreamSettings(camera.id, merged);
      return merged;
    }
  } catch (e) {
    console.warn('Could not load persisted stream settings:', e);
  }
  return null;
}

export function createDebouncedSaveStream(cameraId: string, getSettings: () => StreamSettings) {
  return debounce(async () => {
    try {
      await api.updateStreamSettings(cameraId, getSettings());
    } catch (e) {
      console.error('Failed to save stream settings:', e);
    }
  }, 300);
}

export function createDebouncedSaveCamera(cameraId: string, getSettings: () => CameraSettings) {
  return debounce(async () => {
    try {
      await api.updateCameraSettings(cameraId, buildCameraPayload(getSettings()));
    } catch (e) {
      console.error('Failed to save camera settings:', e);
    }
  }, 300);
}

export function createDebouncedPersistCamera(cameraId: string, getSettings: () => CameraSettings) {
  return debounce(async () => {
    try {
      await api.persistCameraSettings(cameraId, buildCameraPayload(getSettings()));
    } catch (e) {
      console.error('Failed to persist camera settings:', e);
    }
  }, 300);
}

export async function startStream(cameraId: string, streamSettings: StreamSettings): Promise<void> {
  try {
    await api.startStream(cameraId, streamSettings);
  } catch (e) {
    toastError(`Failed to start stream: ${e}`);
  }
}

export async function stopStream(cameraId: string): Promise<void> {
  try {
    await api.stopStream(cameraId);
  } catch (e) {
    toastError(`Failed to stop stream: ${e}`);
  }
}

export { buildCameraPayload, toCameraSettings };
