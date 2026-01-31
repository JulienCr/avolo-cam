import { invoke } from '@tauri-apps/api/core';
import { get } from 'svelte/store';
import type { Camera, DiscoveredCamera } from '../types/camera';
import type { StreamSettings, CameraSettings, WhiteBalanceResult } from '../types/settings';
import type { Profile, GroupOperationResult } from '../types/profile';
import type { MidiNoteConfig } from '../types/app-settings';
import { detectedLocalIP } from '../stores/settings';

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

// Helper to get effective flash destination host
function getEffectiveFlashHost(settings: StreamSettings): string | undefined {
  // Use explicit setting if provided, otherwise fallback to auto-detected IP
  return settings.flash_destination_host || get(detectedLocalIP) || undefined;
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
    streamingMode: settings.streaming_mode,
    // SRT params
    srtPort: settings.srt_port,
    srtLatency: settings.srt_latency,
    srtRcvLatency: settings.srt_rcv_latency,
    srtPeerLatency: settings.srt_peer_latency,
    srtTlpktdrop: settings.srt_tlpktdrop,
    srtGopSize: settings.srt_gop_size,
    // Flash params - use auto-detected IP as fallback
    // NOTE: Don't send flashDestinationPort - let backend auto-assign per-camera ports
    flashDestinationHost: getEffectiveFlashHost(settings),
    flashJitterMode: settings.flash_jitter_mode,
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
    streamingMode: settings.streaming_mode,
    // SRT params
    srtPort: settings.srt_port,
    srtLatency: settings.srt_latency,
    srtRcvLatency: settings.srt_rcv_latency,
    srtPeerLatency: settings.srt_peer_latency,
    srtTlpktdrop: settings.srt_tlpktdrop,
    srtGopSize: settings.srt_gop_size,
    // Flash params
    flashDestinationHost: settings.flash_destination_host,
    flashDestinationPort: settings.flash_destination_port,
    flashJitterMode: settings.flash_jitter_mode,
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
    streamingMode: settings.streaming_mode,
    // SRT params
    srtPort: settings.srt_port,
    srtLatency: settings.srt_latency,
    srtRcvLatency: settings.srt_rcv_latency,
    srtPeerLatency: settings.srt_peer_latency,
    srtTlpktdrop: settings.srt_tlpktdrop,
    srtGopSize: settings.srt_gop_size,
    // Flash params - use auto-detected IP as fallback
    // NOTE: Don't send flashDestinationPort - let backend auto-assign per-camera ports
    flashDestinationHost: getEffectiveFlashHost(settings),
    flashJitterMode: settings.flash_jitter_mode,
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

// MIDI
export async function listMidiInputDevices(): Promise<string[]> {
  return invoke('list_midi_input_devices');
}

export async function listMidiOutputDevices(): Promise<string[]> {
  return invoke('list_midi_output_devices');
}

export async function connectMidiInput(deviceName: string): Promise<void> {
  return invoke('connect_midi_input', { deviceName });
}

export async function connectMidiOutput(deviceName: string): Promise<void> {
  return invoke('connect_midi_output', { deviceName });
}

export async function disconnectMidiInput(): Promise<void> {
  return invoke('disconnect_midi_input');
}

export async function disconnectMidiOutput(): Promise<void> {
  return invoke('disconnect_midi_output');
}

export async function updateCameraMidiChannel(
  cameraId: string,
  channel: number | null
): Promise<void> {
  return invoke('update_camera_midi_channel', { cameraId, channel });
}

export async function getMidiConnectionStatus(): Promise<[boolean, boolean, string | null, string | null]> {
  return invoke('get_midi_connection_status');
}

export async function getMidiNotesConfig(): Promise<MidiNoteConfig> {
  return invoke('get_midi_notes_config');
}

export async function updateMidiNotesConfig(notes: MidiNoteConfig): Promise<void> {
  return invoke('update_midi_notes_config', { notes });
}

export async function startMidiLearnMode(): Promise<number> {
  return invoke('start_midi_learn_mode');
}

export async function cancelMidiLearnMode(): Promise<void> {
  return invoke('cancel_midi_learn_mode');
}

