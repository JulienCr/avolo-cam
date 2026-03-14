<script lang="ts">
  import type { Camera } from '$lib/types/camera';
  import type { StreamSettings, CameraSettings } from '$lib/types/settings';
  import StatusBadge from '$lib/components/ui/StatusBadge.svelte';
  import TelemetryBadge from '$lib/components/shared/TelemetryBadge.svelte';
  import StreamSection from '$lib/components/sections/StreamSection.svelte';
  import CameraSection from '$lib/components/sections/CameraSection.svelte';
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
  } from '$lib/utils/camera-controller';
  import { openDetail, selectedCameraIds, toggleCameraSelection } from '$lib/stores/ui';
  import { formatBattery, formatTemperature, formatBitrate } from '$lib/utils/format';
  import { cameraStreamSettings } from '$lib/stores/settings';
  import * as api from '$lib/utils/api';
  import { toastError } from '$lib/stores/toast';
  import { onMount } from 'svelte';

  let {
    camera,
    onRemove,
    onAliasUpdated,
  }: {
    camera: Camera;
    onRemove: () => void;
    onAliasUpdated: (alias: string) => void;
  } = $props();

  let isOnline = $derived(camera.status !== null);
  let isStreaming = $derived(camera.status?.ndi_state === 'streaming');
  let telemetry = $derived(camera.status?.telemetry);
  let streamingMode = $derived(camera.status?.current?.streaming_mode || 'ndi');
  let selected = $derived($selectedCameraIds.has(camera.id));

  let badgeStatus = $derived(
    isStreaming ? 'live' as const :
    isOnline ? 'ready' as const :
    'offline' as const
  );

  // Settings
  let streamSettings = $state<StreamSettings>(initStreamSettings(camera));
  let cameraSettings = $state<CameraSettings>(initCameraSettings(camera));

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

  // Alias editing
  let isEditingAlias = $state(false);
  let editedAlias = $state(camera.alias);
  let aliasSaving = $state(false);

  function startEditAlias() {
    isEditingAlias = true;
    editedAlias = camera.alias;
  }

  async function saveAlias() {
    const trimmed = editedAlias.trim();
    if (!trimmed || trimmed.length > 64) return;
    aliasSaving = true;
    try {
      const response = await fetch(`http://${camera.ip}:${camera.port}/api/v1/settings/alias`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ alias: trimmed })
      });
      if (!response.ok) throw new Error('Failed to update alias');
      const result = await response.json();
      const { invoke } = await import('@tauri-apps/api/core');
      await invoke('update_camera_alias', { cameraId: camera.id, alias: result.alias });
      onAliasUpdated(result.alias);
      isEditingAlias = false;
    } catch (e) {
      console.error('Failed to update alias:', e);
    } finally {
      aliasSaving = false;
    }
  }

  // Tabs
  let activeTab = $state<'stream' | 'image' | 'lens'>('stream');
  let hasMultipleTabs = $derived(isOnline);
</script>

<div class="flex flex-col rounded-lg border bg-card overflow-hidden transition-opacity
  {!isOnline ? 'opacity-60 border-dashed' : 'border-border'}">

  <!-- Header -->
  <div class="flex items-center gap-2 px-3 py-2 border-b border-border">
    <input
      type="checkbox"
      checked={selected}
      onchange={() => toggleCameraSelection(camera.id)}
      class="h-3 w-3 rounded-sm border-border accent-primary cursor-pointer shrink-0"
    />

    {#if isEditingAlias}
      <div class="flex items-center gap-1 flex-1 min-w-0">
        <input
          type="text"
          bind:value={editedAlias}
          class="flex-1 min-w-0 h-5 px-1 text-[11px] bg-input border border-border rounded-sm text-foreground"
          maxlength="64"
          disabled={aliasSaving}
        />
        <button onclick={saveAlias} disabled={aliasSaving} class="text-[10px] text-primary hover:underline">OK</button>
        <button onclick={() => { isEditingAlias = false; editedAlias = camera.alias; }} class="text-[10px] text-muted-foreground hover:underline">X</button>
      </div>
    {:else}
      <button
        onclick={startEditAlias}
        class="flex-1 min-w-0 text-left text-xs font-bold text-foreground truncate hover:text-primary transition-colors"
        title="Click to rename"
      >{camera.alias}</button>
    {/if}

    <StatusBadge status={badgeStatus} />

    {#if isStreaming}
      <span class="mode-badge {streamingMode === 'ndi' ? 'mode-badge-ndi' : streamingMode === 'flash' ? 'mode-badge-flash' : 'mode-badge-srt'}">
        {streamingMode === 'ndi' ? 'NDI' : streamingMode === 'flash' ? 'FLASH' : 'SRT'}
      </span>
    {/if}

    <button
      onclick={() => openDetail(camera.id)}
      class="h-5 px-1.5 text-[10px] font-medium rounded-sm border border-border text-muted-foreground hover:text-primary hover:border-primary/50 transition-colors shrink-0"
      title="Open detail view"
    >Open &rarr;</button>

    <button
      onclick={onRemove}
      class="h-5 w-5 flex items-center justify-center text-muted-foreground hover:text-destructive transition-colors shrink-0 rounded-sm"
      title="Remove camera"
    >
      <svg class="h-3 w-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
      </svg>
    </button>
  </div>

  <!-- Telemetry band (inline) -->
  {#if isOnline && telemetry}
    <div class="flex items-center gap-3 px-3 py-1.5 border-b border-border">
      <TelemetryBadge label="BAT" value={formatBattery(telemetry.battery)} />
      <TelemetryBadge label="TEMP" value={formatTemperature(telemetry.temp_c)} warn={telemetry.temp_c > 40} />
      <TelemetryBadge label="CPU" value={`${telemetry.cpu_usage.toFixed(0)}%`} warn={telemetry.cpu_usage > 85} />
      <TelemetryBadge label="BIT" value={`${formatBitrate(telemetry.bitrate)} Mb`} />
      {#if telemetry.dropped_frames && telemetry.dropped_frames > 0}
        <TelemetryBadge label="DROP" value={String(telemetry.dropped_frames)} warn={true} />
      {/if}
    </div>
  {:else if !isOnline}
    <div class="flex items-center gap-2 px-3 py-1.5 border-b border-border">
      <span class="text-[10px] text-muted-foreground italic">Changes apply on reconnect</span>
    </div>
  {/if}

  <!-- Start/Stop Stream — primary action, prominent -->
  {#if isOnline}
    <div class="px-3 py-1.5 border-b border-border">
      {#if isStreaming}
        <button
          onclick={handleStopStream}
          class="w-full h-7 text-[11px] font-semibold rounded-sm bg-destructive text-destructive-foreground hover:opacity-90 transition-opacity"
        >Stop Stream</button>
      {:else}
        <button
          onclick={handleStartStream}
          class="w-full h-7 text-[11px] font-semibold rounded-sm bg-primary text-primary-foreground hover:opacity-90 transition-opacity"
        >Start Stream</button>
      {/if}
    </div>
  {/if}

  <!-- Tabs (skip tab bar if only one tab) -->
  {#if hasMultipleTabs}
    <div class="flex border-b border-border">
      {#each [
        { id: 'stream' as const, label: 'Stream' },
        { id: 'image' as const, label: 'Image' },
        { id: 'lens' as const, label: 'Lens' },
      ] as tab}
        <button
          onclick={() => activeTab = tab.id}
          class="flex-1 h-7 text-[10px] font-medium transition-colors
            {activeTab === tab.id ? 'text-primary border-b-2 border-primary' : 'text-muted-foreground hover:text-foreground'}"
        >{tab.label}</button>
      {/each}
    </div>
  {/if}

  <!-- Tab content -->
  <div class="px-3 py-2">
    {#if activeTab === 'stream'}
      <StreamSection
        bind:settings={streamSettings}
        onStart={handleStartStream}
        onStop={handleStopStream}
        {isStreaming}
        {isOnline}
        compact={true}
      />
    {:else if activeTab === 'image' && isOnline}
      <CameraSection
        bind:settings={cameraSettings}
        onMeasureWB={handleMeasureWB}
        {measuring}
        {isOnline}
        compact={true}
        showSections={['wb', 'exposure']}
      />
    {:else if activeTab === 'lens' && isOnline}
      <CameraSection
        bind:settings={cameraSettings}
        onMeasureWB={handleMeasureWB}
        {measuring}
        {isOnline}
        compact={true}
        showSections={['focus', 'lens', 'torch']}
      />
    {/if}
  </div>
</div>
