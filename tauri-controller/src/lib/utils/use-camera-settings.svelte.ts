import type { Camera } from '$lib/types/camera';
import type { StreamSettings, CameraSettings } from '$lib/types/settings';
import {
  initStreamSettings,
  initCameraSettings,
  loadPersistedSettings,
  loadPersistedStreamSettings,
  createDebouncedSaveStream,
  createDebouncedSaveCamera,
  createDebouncedPersistCamera,
  startStream,
  stopStream,
  measureWB,
} from '$lib/utils/camera-controller';
import { toastError } from '$lib/stores/toast';
import { onMount } from 'svelte';

export function useCameraSettings(camera: Camera) {
  let streamSettings = $state<StreamSettings>(initStreamSettings(camera));
  let cameraSettings = $state<CameraSettings>(initCameraSettings(camera));
  let measuring = $state(false);

  const isOnline = $derived(camera.status !== null);

  onMount(async () => {
    const [persistedCam, persistedStream] = await Promise.all([
      loadPersistedSettings(camera),
      loadPersistedStreamSettings(camera),
    ]);
    if (persistedCam) cameraSettings = persistedCam;
    if (persistedStream) streamSettings = persistedStream;
  });

  const debouncedSaveStream = createDebouncedSaveStream(camera.id, () => streamSettings);
  const debouncedSaveCamera = createDebouncedSaveCamera(camera.id, () => cameraSettings);
  const debouncedPersistCamera = createDebouncedPersistCamera(camera.id, () => cameraSettings);

  let streamInitialized = false;
  let cameraInitialized = false;

  $effect(() => {
    const _ = [
      streamSettings.streaming_mode, streamSettings.resolution,
      streamSettings.framerate, streamSettings.bitrate, streamSettings.codec,
      streamSettings.srt_latency, streamSettings.srt_gop_size, streamSettings.flash_jitter_mode,
    ];
    if (!streamInitialized) { streamInitialized = true; return; }
    debouncedSaveStream();
  });

  $effect(() => {
    const _ = [
      cameraSettings.wb_mode, cameraSettings.wb_kelvin, cameraSettings.wb_tint,
      cameraSettings.iso_mode, cameraSettings.iso,
      cameraSettings.shutter_mode, cameraSettings.shutter_s,
      cameraSettings.focus_mode, cameraSettings.focus_distance,
      cameraSettings.zoom_factor, cameraSettings.lens, cameraSettings.camera_position,
      cameraSettings.torch_mode, cameraSettings.torch_level,
    ];
    if (!cameraInitialized) { cameraInitialized = true; return; }
    if (isOnline) { debouncedSaveCamera(); } else { debouncedPersistCamera(); }
  });

  async function handleStartStream() { await startStream(camera.id, streamSettings); }
  async function handleStopStream() { await stopStream(camera.id); }

  async function handleMeasureWB() {
    measuring = true;
    try {
      await measureWB(camera.id, (kelvin, tint) => {
        cameraSettings.wb_kelvin = kelvin;
        cameraSettings.wb_tint = tint;
        cameraSettings.wb_mode = 'manual';
      });
    } catch (e) {
      toastError(`Failed to measure WB: ${e}`);
    } finally {
      measuring = false;
    }
  }

  return {
    get streamSettings() { return streamSettings; },
    set streamSettings(v: StreamSettings) { streamSettings = v; },
    get cameraSettings() { return cameraSettings; },
    set cameraSettings(v: CameraSettings) { cameraSettings = v; },
    get measuring() { return measuring; },
    handleStartStream,
    handleStopStream,
    handleMeasureWB,
  };
}
