import { writable, derived, get } from 'svelte/store';
import type { Camera, DiscoveredCamera } from '../types/camera';
import * as api from '../utils/api';
import { updateStreamSettings } from './settings';

// Camera state
export const cameras = writable<Camera[]>([]);
export const discoveredCameras = writable<DiscoveredCamera[]>([]);
export const loading = writable(true);
export const error = writable<string | null>(null);

// Discovery state
export const discovering = writable(false);

// Derived: Get camera by ID
export const getCameraById = derived(
  cameras,
  ($cameras) => (id: string) => $cameras.find((c) => c.id === id)
);

// Actions
export async function refreshCameras(): Promise<void> {
  try {
    const data = await api.getCameras();
    cameras.set(data);

    // Initialize stream settings from camera's current config (only if not already set by user)
    for (const camera of data) {
      if (camera.status?.current) {
        updateStreamSettings(camera.id, {
          resolution: camera.status.current.resolution,
          framerate: camera.status.current.fps,
          bitrate: camera.status.current.bitrate,
          codec: camera.status.current.codec,
        }, true); // onlyIfNotExists = true
      }
    }

    error.set(null);
  } catch (e) {
    error.set(String(e));
    console.error('Failed to get cameras:', e);
  } finally {
    loading.set(false);
  }
}

export async function discoverCamerasAction(): Promise<void> {
  try {
    discovering.set(true);
    const data = await api.discoverCameras();

    // Filter out cameras that are already added
    const currentCameras = get(cameras);
    const newCameras = data.filter((discovered) => {
      return !currentCameras.some((camera) =>
        camera.ip === discovered.ip && camera.port === discovered.port
      );
    });

    // Auto-add new cameras using token from TXT records (token is optional)
    for (const discovered of newCameras) {
      const token = discovered.txt_records?.token || '';

      try {
        await api.addCameraManual(discovered.ip, discovered.port, token);
        console.log(`Auto-added camera: ${discovered.alias}`);
      } catch (e) {
        console.error(`Failed to auto-add camera ${discovered.alias}:`, e);
      }
    }

    // Refresh camera list after adding
    if (newCameras.length > 0) {
      await refreshCameras();
    }

    discoveredCameras.set([]);  // Clear discovered list since all are auto-added
  } catch (e) {
    console.error('Failed to discover cameras:', e);
  } finally {
    discovering.set(false);
  }
}

export async function addCameraManualAction(
  ip: string,
  port: number,
  token: string
): Promise<void> {
  await api.addCameraManual(ip, port, token);
  await refreshCameras();
}

export async function addDiscoveredCameraAction(
  discovered: DiscoveredCamera,
  token: string
): Promise<void> {
  await api.addCameraManual(discovered.ip, discovered.port, token);
  await refreshCameras();

  // Re-filter discovered cameras to remove the one we just added
  const currentCameras = get(cameras);
  discoveredCameras.update((discovered) =>
    discovered.filter((d) =>
      !currentCameras.some((camera) =>
        camera.ip === d.ip && camera.port === d.port
      )
    )
  );
}

export async function removeCameraAction(cameraId: string): Promise<void> {
  await api.removeCamera(cameraId);
  await refreshCameras();
}

// Setup intervals for auto-refresh only (discovery is manual now)
let refreshInterval: ReturnType<typeof setInterval> | null = null;

export function startAutoRefresh(refreshMs = 2000): void {
  // Initial refresh
  refreshCameras();

  // Setup interval for camera refresh only
  refreshInterval = setInterval(refreshCameras, refreshMs);
}

export function stopAutoRefresh(): void {
  if (refreshInterval) {
    clearInterval(refreshInterval);
    refreshInterval = null;
  }
}
