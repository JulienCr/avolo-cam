import { invoke } from '@tauri-apps/api/core';
import type { Camera, DiscoveredCamera } from '../types/camera';
import type { StreamSettings, CameraSettings, WhiteBalanceResult } from '../types/settings';
import type { Profile, GroupOperationResult } from '../types/profile';

// Camera Management
export async function discoverCameras(): Promise<DiscoveredCamera[]> {
  return invoke('discover_cameras');
}

export async function getCameras(): Promise<Camera[]> {
  return invoke('get_cameras');
}

export async function addCameraManual(ip: string, port: number, token: string): Promise<void> {
  return invoke('add_camera_manual', { ip, port, token });
}

export async function removeCamera(cameraId: string): Promise<void> {
  return invoke('remove_camera', { cameraId });
}

// Streaming
export async function startStream(
  cameraId: string,
  settings: StreamSettings
): Promise<void> {
  return invoke('start_stream', {
    cameraId,
    resolution: settings.resolution,
    framerate: settings.framerate,
    bitrate: settings.bitrate,
    codec: settings.codec,
  });
}

export async function stopStream(cameraId: string): Promise<void> {
  return invoke('stop_stream', { cameraId });
}

// Settings
export async function updateCameraSettings(
  cameraId: string,
  settings: Partial<CameraSettings>
): Promise<void> {
  return invoke('update_camera_settings', { cameraId, settings });
}

export async function updateStreamSettings(
  cameraId: string,
  settings: StreamSettings
): Promise<void> {
  return invoke('update_stream_settings', {
    cameraId,
    resolution: settings.resolution,
    framerate: settings.framerate,
    bitrate: settings.bitrate,
    codec: settings.codec,
  });
}

export async function measureWhiteBalance(cameraId: string): Promise<WhiteBalanceResult> {
  return invoke('measure_white_balance', { cameraId });
}

// Group Operations
export async function groupStartStream(
  cameraIds: string[],
  settings: StreamSettings
): Promise<GroupOperationResult[]> {
  return invoke('group_start_stream', {
    cameraIds,
    resolution: settings.resolution,
    framerate: settings.framerate,
    bitrate: settings.bitrate,
    codec: settings.codec,
  });
}

export async function groupStopStream(cameraIds: string[]): Promise<void> {
  return invoke('group_stop_stream', { cameraIds });
}

export async function groupUpdateSettings(
  cameraIds: string[],
  settings: Partial<CameraSettings>
): Promise<GroupOperationResult[]> {
  return invoke('group_update_settings', { cameraIds, settings });
}

export async function startAllCameras(): Promise<GroupOperationResult[]> {
  return invoke('start_all_cameras');
}

export async function stopAllCameras(): Promise<GroupOperationResult[]> {
  return invoke('stop_all_cameras');
}

// Profiles
export async function getProfiles(): Promise<Profile[]> {
  return invoke('get_profiles');
}

export async function saveProfile(profile: Profile): Promise<void> {
  return invoke('save_profile', {
    name: profile.name,
    settings: profile.settings,
  });
}

export async function deleteProfile(name: string): Promise<void> {
  return invoke('delete_profile', { name });
}

export async function applyProfile(
  profileName: string,
  cameraIds: string[]
): Promise<GroupOperationResult[]> {
  return invoke('apply_profile', { profileName, cameraIds });
}
