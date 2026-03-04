<script lang="ts">
  import type { Camera } from '$lib/types/camera';
  import type { StreamSettings, CameraSettings } from '$lib/types/settings';
  import { DEFAULT_CAMERA_SETTINGS } from '$lib/types/settings';
  import ColumnHeader from './ColumnHeader.svelte';
  import StreamSection from '../sections/StreamSection.svelte';
  import CameraSection from '../sections/CameraSection.svelte';
  import {
    getStreamSettings,
    loadStreamSettingsForEditing,
    currentStreamSettings,
    currentCameraSettings,
    measuringWB,
  } from '$lib/stores/settings';
  import { get } from 'svelte/store';
  import * as api from '$lib/utils/api';
  import { refreshCameras } from '$lib/stores/cameras';
  import { debounce } from '$lib/utils/debounce';

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

  // Local camera settings for this column
  let cameraSettings = $state<CameraSettings>(
    camera.status?.current
      ? {
          wb_mode: camera.status.current.wb_mode || 'auto',
          wb_kelvin: camera.status.current.wb_kelvin || 5000,
          wb_tint: camera.status.current.wb_tint || 0,
          iso_mode: camera.status.current.iso_mode || 'auto',
          iso: camera.status.current.iso || 400,
          shutter_mode: camera.status.current.shutter_mode || 'auto',
          shutter_s: camera.status.current.shutter_s || 0.01,
          focus_mode: camera.status.current.focus_mode || 'auto',
          focus_distance: camera.status.current.focus_distance || 0.5,
          zoom_factor: camera.status.current.zoom_factor || 2.0,
          lens: (camera.status.current.lens as any) || 'wide',
          camera_position: (camera.status.current.camera_position as any) || 'back',
          torch_mode: 'auto',
          torch_level: camera.status.current.torch_level || 0.03,
        }
      : { ...DEFAULT_CAMERA_SETTINGS }
  );

  // Debounced stream settings save
  const debouncedSaveStreamSettings = debounce(async () => {
    try {
      await api.updateStreamSettings(camera.id, streamSettings);
    } catch (e) {
      console.error('Failed to save stream settings:', e);
    }
  }, 300);

  // Debounced camera settings save
  const debouncedSaveCameraSettings = debounce(async () => {
    try {
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
      await api.updateCameraSettings(camera.id, payload);
    } catch (e) {
      console.error('Failed to save camera settings:', e);
    }
  }, 300);

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
    debouncedSaveStreamSettings();
  });

  // Watch camera settings changes
  $effect(() => {
    if (!isOnline) return;
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
    debouncedSaveCameraSettings();
  });

  async function handleStartStream() {
    try {
      await api.startStream(camera.id, streamSettings);
      await refreshCameras();
    } catch (e) {
      alert(`Failed to start stream: ${e}`);
    }
  }

  async function handleStopStream() {
    try {
      await api.stopStream(camera.id);
      await refreshCameras();
    } catch (e) {
      alert(`Failed to stop stream: ${e}`);
    }
  }

  async function handleMeasureWB() {
    try {
      measuringWB.set(true);
      const result = await api.measureWhiteBalance(camera.id);
      cameraSettings.wb_kelvin = result.scene_cct_k;
      cameraSettings.wb_tint = Math.round(result.tint);
      cameraSettings.wb_mode = 'manual';
    } catch (e) {
      alert(`Failed to measure WB: ${e}`);
    } finally {
      measuringWB.set(false);
    }
  }

  let measuring = $derived(get(measuringWB));
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
