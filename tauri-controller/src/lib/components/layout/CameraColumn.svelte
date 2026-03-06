<script lang="ts">
  import type { Camera } from '$lib/types/camera';
  import type { StreamSettings, CameraSettings } from '$lib/types/settings';
  import { DEFAULT_CAMERA_SETTINGS } from '$lib/types/settings';
  import ColumnHeader from './ColumnHeader.svelte';
  import StreamSection from '../sections/StreamSection.svelte';
  import CameraSection from '../sections/CameraSection.svelte';
  import {
    getStreamSettings,
  } from '$lib/stores/settings';
  import * as api from '$lib/utils/api';
  import { refreshCameras } from '$lib/stores/cameras';
  import { debounce } from '$lib/utils/debounce';
  import { onMount } from 'svelte';
  import { toastError } from '$lib/stores/toast';

  let {
    camera,
    selected = false,
    onToggleSelection,
    onRemove,
    onAliasUpdated,
  }: {
    camera: Camera;
    selected: boolean;
    onToggleSelection: () => void;
    onRemove: () => void;
    onAliasUpdated: (alias: string) => void;
  } = $props();

  let isOnline = $derived(camera.status !== null);
  let isStreaming = $derived(camera.status?.ndi_state === 'streaming');

  // Local stream settings for this column
  let streamSettings = $state<StreamSettings>(getStreamSettings(camera.id));

  // Merge partial source over defaults to build a full CameraSettings
  function toCameraSettings(source: Partial<CameraSettings>): CameraSettings {
    return { ...DEFAULT_CAMERA_SETTINGS, ...source, torch_mode: 'auto' };
  }

  // Local camera settings for this column
  let cameraSettings = $state<CameraSettings>(
    camera.status?.current
      ? toCameraSettings(camera.status.current as Partial<CameraSettings>)
      : { ...DEFAULT_CAMERA_SETTINGS }
  );

  // Load persisted settings on mount (for offline cameras)
  onMount(async () => {
    if (!camera.status?.current) {
      try {
        const persisted = await api.getPersistedCameraSettings(camera.id);
        if (persisted) {
          cameraSettings = toCameraSettings(persisted as Partial<CameraSettings>);
        }
      } catch (e) {
        console.warn('Could not load persisted camera settings:', e);
      }
    }
  });

  // Debounced stream settings save
  const debouncedSaveStreamSettings = debounce(async () => {
    try {
      await api.updateStreamSettings(camera.id, streamSettings);
    } catch (e) {
      console.error('Failed to save stream settings:', e);
    }
  }, 300);

  // Build camera settings payload
  function buildCameraPayload() {
    const payload: any = {
      wb_mode: cameraSettings.wb_mode,
      iso_mode: cameraSettings.iso_mode,
      shutter_mode: cameraSettings.shutter_mode,
      focus_mode: cameraSettings.focus_mode,
      zoom_factor: cameraSettings.zoom_factor,
      lens: cameraSettings.lens,
      camera_position: cameraSettings.camera_position,
    };
    if (cameraSettings.wb_mode === 'manual') {
      payload.wb_kelvin = cameraSettings.wb_kelvin;
      payload.wb_tint = cameraSettings.wb_tint;
    }
    if (cameraSettings.iso_mode === 'manual') {
      payload.iso = cameraSettings.iso;
    }
    if (cameraSettings.shutter_mode === 'manual') {
      payload.shutter_s = cameraSettings.shutter_s;
    }
    if (cameraSettings.focus_mode === 'manual') {
      payload.focus_distance = cameraSettings.focus_distance;
    }
    if (cameraSettings.torch_mode === 'manual') {
      payload.torch_level = cameraSettings.torch_level;
    }
    return payload;
  }

  // Debounced camera settings save (online: sends to camera + persists)
  const debouncedSaveCameraSettings = debounce(async () => {
    try {
      await api.updateCameraSettings(camera.id, buildCameraPayload());
    } catch (e) {
      console.error('Failed to save camera settings:', e);
    }
  }, 300);

  // Debounced camera settings persist (offline: persists only, no HTTP)
  const debouncedPersistCameraSettings = debounce(async () => {
    try {
      await api.persistCameraSettings(camera.id, buildCameraPayload());
    } catch (e) {
      console.error('Failed to persist camera settings:', e);
    }
  }, 300);

  // Skip first $effect run to avoid spurious API calls on mount
  let streamInitialized = false;
  let cameraInitialized = false;

  // Watch stream settings changes
  $effect(() => {
    // Access all stream setting props to establish reactive tracking
    const _ = [
      streamSettings.streaming_mode,
      streamSettings.resolution,
      streamSettings.framerate,
      streamSettings.bitrate,
      streamSettings.codec,
      streamSettings.srt_latency,
      streamSettings.srt_gop_size,
      streamSettings.flash_jitter_mode,
    ];
    if (!streamInitialized) { streamInitialized = true; return; }
    debouncedSaveStreamSettings();
  });

  // Watch camera settings changes
  $effect(() => {
    const _ = [
      cameraSettings.wb_mode,
      cameraSettings.wb_kelvin,
      cameraSettings.wb_tint,
      cameraSettings.iso_mode,
      cameraSettings.iso,
      cameraSettings.shutter_mode,
      cameraSettings.shutter_s,
      cameraSettings.focus_mode,
      cameraSettings.focus_distance,
      cameraSettings.zoom_factor,
      cameraSettings.lens,
      cameraSettings.camera_position,
      cameraSettings.torch_mode,
      cameraSettings.torch_level,
    ];
    if (!cameraInitialized) { cameraInitialized = true; return; }
    if (isOnline) {
      debouncedSaveCameraSettings();
    } else {
      debouncedPersistCameraSettings();
    }
  });

  async function handleStartStream() {
    try {
      await api.startStream(camera.id, streamSettings);
      await refreshCameras();
    } catch (e) {
      toastError(`Failed to start stream: ${e}`);
    }
  }

  async function handleStopStream() {
    try {
      await api.stopStream(camera.id);
      await refreshCameras();
    } catch (e) {
      toastError(`Failed to stop stream: ${e}`);
    }
  }

  let measuring = $state(false);

  async function handleMeasureWB() {
    try {
      measuring = true;
      const result = await api.measureWhiteBalance(camera.id);
      cameraSettings.wb_kelvin = result.scene_cct_k;
      cameraSettings.wb_tint = Math.round(result.tint);
      cameraSettings.wb_mode = 'manual';
    } catch (e) {
      toastError(`Failed to measure WB: ${e}`);
    } finally {
      measuring = false;
    }
  }
</script>

<div class="w-[280px] min-w-[280px] h-full flex flex-col border-r border-border bg-card">
  <ColumnHeader
    {camera}
    {selected}
    {onToggleSelection}
    {onRemove}
    {onAliasUpdated}
  />

  <div class="flex-1 overflow-y-auto">
    <StreamSection
      bind:settings={streamSettings}
      onStart={handleStartStream}
      onStop={handleStopStream}
      {isStreaming}
      {isOnline}
    />

    <CameraSection
      bind:settings={cameraSettings}
      onMeasureWB={handleMeasureWB}
      {measuring}
      {isOnline}
    />
  </div>
</div>
