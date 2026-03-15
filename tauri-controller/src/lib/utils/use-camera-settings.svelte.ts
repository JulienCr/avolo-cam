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
import { refreshCameras } from '$lib/stores/cameras';
import { onMount, onDestroy, untrack } from 'svelte';

// Accept a getter so $derived/$effect track the live prop, not a stale snapshot.
export function useCameraSettings(getCamera: () => Camera) {
  const camera = $derived(getCamera());
  let streamSettings = $state<StreamSettings>(initStreamSettings(camera));
  let cameraSettings = $state<CameraSettings>(initCameraSettings(camera));
  let measuring = $state(false);

  const isOnline = $derived(camera.status !== null);
  const isStreaming = $derived(camera.status?.ndi_state === 'streaming');
  let wasOnline = false;

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

  onDestroy(() => {
    debouncedSaveStream.cancel();
    debouncedSaveCamera.cancel();
    debouncedPersistCamera.cancel();
  });

  let streamInitialized = false;
  let cameraInitialized = false;

  // When camera comes online, flush any pending offline edits to the live API
  $effect(() => {
    const online = isOnline;
    if (online && !wasOnline && cameraInitialized) {
      debouncedPersistCamera.cancel();
      debouncedSaveCamera();
    }
    wasOnline = online;
  });

  $effect(() => {
    const _ = [
      streamSettings.streaming_mode, streamSettings.resolution,
      streamSettings.framerate, streamSettings.bitrate, streamSettings.codec,
      streamSettings.srt_latency, streamSettings.srt_gop_size, streamSettings.flash_jitter_mode,
      streamSettings.flash_destination_port, streamSettings.flash_destination_host,
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
    if (untrack(() => isOnline)) { debouncedSaveCamera(); } else { debouncedPersistCamera(); }
  });

  async function handleStartStream() {
    await startStream(camera.id, streamSettings);
    refreshCameras();
  }

  async function handleStopStream() {
    await stopStream(camera.id);
    refreshCameras();
  }

  async function handleMeasureWB() {
    measuring = true;
    try {
      const { kelvin, tint } = await measureWB(camera.id);
      Object.assign(cameraSettings, { wb_kelvin: kelvin, wb_tint: tint, wb_mode: 'manual' });
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
    get isOnline() { return isOnline; },
    get isStreaming() { return isStreaming; },
    handleStartStream,
    handleStopStream,
    handleMeasureWB,
  };
}
