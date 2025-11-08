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
    discoveredCameras.set(data);
    console.log('Discovered cameras:', data);
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

  // Remove from discovered list
  discoveredCameras.update((cameras) =>
    cameras.filter((c) => c.alias !== discovered.alias)
  );
}

export async function removeCameraAction(cameraId: string): Promise<void> {
  await api.removeCamera(cameraId);
  await refreshCameras();
}

// Setup intervals for auto-refresh and auto-discovery
let refreshInterval: ReturnType<typeof setInterval> | null = null;
let discoveryInterval: ReturnType<typeof setInterval> | null = null;

export function startAutoRefresh(refreshMs = 2000, discoveryMs = 10000): void {
  // Initial refresh
  refreshCameras();
  discoverCamerasAction();

  // Setup intervals
  refreshInterval = setInterval(refreshCameras, refreshMs);
  discoveryInterval = setInterval(discoverCamerasAction, discoveryMs);
}

export function stopAutoRefresh(): void {
  if (refreshInterval) {
    clearInterval(refreshInterval);
    refreshInterval = null;
  }
  if (discoveryInterval) {
    clearInterval(discoveryInterval);
    discoveryInterval = null;
  }
}
