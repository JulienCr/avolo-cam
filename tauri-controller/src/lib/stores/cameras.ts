import { writable, derived, get } from 'svelte/store';
import type { Camera, DiscoveredCamera } from '../types/camera';
import * as api from '../utils/api';

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
    const filtered = data.filter((discovered) => {
      return !currentCameras.some((camera) =>
        camera.ip === discovered.ip && camera.port === discovered.port
      );
    });

    discoveredCameras.set(filtered);
    console.log('Discovered cameras:', filtered);
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
