<script lang="ts">
  import type { Camera } from '$lib/types/camera';
  import type { StreamSettings, CameraSettings } from '$lib/types/settings';
  import StatusBadge from '$lib/components/ui/StatusBadge.svelte';
  import StreamSection from '$lib/components/sections/StreamSection.svelte';
  import CameraSection from '$lib/components/sections/CameraSection.svelte';
  import TelemetryPanel from './TelemetryPanel.svelte';
  import SectionBar from '$lib/components/ui/SectionBar.svelte';
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
  import { allPresets, saveCustomPreset, deleteCustomPreset, createPresetFromSettings } from '$lib/utils/presets';
  import { backToOverview } from '$lib/stores/ui';
  import { cameras } from '$lib/stores/cameras';
  import * as api from '$lib/utils/api';
  import { toastError, toastSuccess } from '$lib/stores/toast';
  import { onMount } from 'svelte';
  import { cameraStreamSettings } from '$lib/stores/settings';

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
  let streamingMode = $derived(camera.status?.current?.streaming_mode || 'ndi');
  let telemetry = $derived(camera.status?.telemetry);

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

  // Presets
  let newPresetName = $state('');
  let showPresetSave = $state(false);

  function applyPreset(presetKey: string) {
    const preset = $allPresets[presetKey];
    if (!preset) return;
    Object.assign(cameraSettings, preset.settings);
    toastSuccess(`Preset "${preset.label}" applied`);
  }

  function handleSavePreset() {
    const name = newPresetName.trim();
    if (!name) return;
    const key = name.toLowerCase().replace(/\s+/g, '_');
    saveCustomPreset(key, createPresetFromSettings(name, cameraSettings));
    toastSuccess(`Preset "${name}" saved`);
    newPresetName = '';
    showPresetSave = false;
  }

  function handleDeletePreset(key: string) {
    deleteCustomPreset(key);
    toastSuccess('Preset deleted');
  }

  // Match Main Cam
  let matchSourceId = $state('');
  function matchMainCam() {
    const source = $cameras.find(c => c.id === matchSourceId);
    if (!source?.status?.current) return;
    const s = source.status.current;
    if (s.wb_mode) cameraSettings.wb_mode = s.wb_mode;
    if (s.wb_kelvin) cameraSettings.wb_kelvin = s.wb_kelvin;
    if (s.wb_tint !== undefined) cameraSettings.wb_tint = s.wb_tint;
    if (s.iso_mode) cameraSettings.iso_mode = s.iso_mode;
    if (s.iso) cameraSettings.iso = s.iso;
    if (s.shutter_mode) cameraSettings.shutter_mode = s.shutter_mode;
    if (s.shutter_s) cameraSettings.shutter_s = s.shutter_s;
    if (s.zoom_factor) cameraSettings.zoom_factor = s.zoom_factor;
    if (s.lens) cameraSettings.lens = s.lens;
    toastSuccess(`Matched settings from "${source.alias}"`);
  }

  let otherCameras = $derived($cameras.filter(c => c.id !== camera.id));

  // MIDI
  let selectedMidiChannel = $state(camera.midi_channel?.toString() || '');
  let midiChannelSaving = $state(false);

  async function handleMidiChannelChange(event: Event) {
    const target = event.target as HTMLSelectElement;
    const value = target.value;
    midiChannelSaving = true;
    try {
      const channel = value === '' ? null : parseInt(value);
      await api.updateCameraMidiChannel(camera.id, channel);
      selectedMidiChannel = value;
    } catch (error) {
      console.error('Failed to update MIDI channel:', error);
      selectedMidiChannel = camera.midi_channel?.toString() || '';
    } finally {
      midiChannelSaving = false;
    }
  }

  // Expert section
  let expertOpen = $state(false);

  // SRT copy
  let copiedSrt = $state(false);
  let cameraStreamSetting = $derived($cameraStreamSettings[camera.id]);
  let configuredStreamingMode = $derived(cameraStreamSetting?.streaming_mode || 'ndi');
  let configuredSrtPort = $derived(cameraStreamSetting?.srt_port || 9000);

  async function copyToClipboard(text: string) {
    try {
      await navigator.clipboard.writeText(text);
      copiedSrt = true;
      setTimeout(() => copiedSrt = false, 2000);
    } catch { /* ignore */ }
  }
</script>

<div class="flex flex-col gap-3 h-full">
  <!-- Header -->
  <div class="flex items-center gap-2 p-2 rounded-lg border border-border bg-card">
    <button
      onclick={() => backToOverview()}
      class="h-6 px-2 text-[10px] font-medium rounded-sm bg-secondary text-secondary-foreground hover:bg-accent transition-colors"
    >&larr; Back</button>

    {#if isEditingAlias}
      <div class="flex items-center gap-1 flex-1 min-w-0">
        <input
          type="text"
          bind:value={editedAlias}
          class="flex-1 min-w-0 h-6 px-1.5 text-xs bg-input border border-border rounded-sm text-foreground"
          maxlength="64"
          disabled={aliasSaving}
        />
        <button onclick={saveAlias} disabled={aliasSaving} class="text-[10px] text-primary hover:underline">OK</button>
        <button onclick={() => { isEditingAlias = false; editedAlias = camera.alias; }} class="text-[10px] text-muted-foreground hover:underline">X</button>
      </div>
    {:else}
      <button
        onclick={() => { isEditingAlias = true; editedAlias = camera.alias; }}
        class="text-sm font-semibold text-foreground hover:text-primary transition-colors"
        title="Click to rename"
      >{camera.alias}</button>
    {/if}

    <StatusBadge status={badgeStatus} />

    {#if isStreaming}
      <span class="mode-badge {streamingMode === 'ndi' ? 'mode-badge-ndi' : streamingMode === 'flash' ? 'mode-badge-flash' : 'mode-badge-srt'}">
        {streamingMode === 'ndi' ? 'NDI' : streamingMode === 'flash' ? 'FLASH' : 'SRT'}
      </span>
    {/if}

    <span class="text-[10px] text-muted-foreground font-mono">{camera.ip}:{camera.port}</span>

    {#if configuredStreamingMode === 'srt'}
      <button
        onclick={() => copyToClipboard(`srt://${camera.ip}:${configuredSrtPort}?mode=caller`)}
        class="text-[9px] px-1 py-0 rounded-sm bg-green-900/30 text-green-400 hover:bg-green-800/40 transition-colors"
        title="Copy SRT URL"
      >{copiedSrt ? 'Copied' : 'SRT URL'}</button>
    {/if}

    <div class="flex-1"></div>

    <select
      bind:value={selectedMidiChannel}
      onchange={handleMidiChannelChange}
      disabled={midiChannelSaving}
      class="h-5 text-[9px] px-0.5 rounded-sm bg-secondary border border-border text-secondary-foreground cursor-pointer disabled:opacity-40"
    >
      <option value="">MIDI: --</option>
      {#each [1, 2, 3, 4, 5, 6, 7, 8] as ch}
        <option value={ch.toString()}>MIDI: {ch}</option>
      {/each}
    </select>

    <button
      onclick={onRemove}
      class="h-6 px-2 text-[10px] font-medium rounded-sm text-muted-foreground hover:text-destructive hover:bg-destructive/10 transition-colors"
    >Remove</button>
  </div>

  <!-- Two-column layout -->
  <div class="flex gap-3 flex-1 overflow-hidden">
    <!-- Left: Stream + Camera settings -->
    <div class="flex-[3] overflow-y-auto flex flex-col gap-2">
      <!-- Quick Actions -->
      {#if isOnline}
        <div class="flex gap-1">
          {#if isStreaming}
            <button
              onclick={handleStopStream}
              class="flex-1 h-7 text-[11px] font-medium rounded-sm bg-destructive text-destructive-foreground hover:opacity-90 transition-opacity"
            >Stop Stream</button>
          {:else}
            <button
              onclick={handleStartStream}
              class="flex-1 h-7 text-[11px] font-medium rounded-sm bg-primary text-primary-foreground hover:opacity-90 transition-opacity"
            >Start Stream</button>
          {/if}
        </div>
      {/if}

      <div class="rounded-lg border border-border bg-card overflow-hidden">
        <StreamSection
          bind:settings={streamSettings}
          onStart={handleStartStream}
          onStop={handleStopStream}
          {isStreaming}
          {isOnline}
          compact={false}
          hideActions={true}
        />
      </div>

      <div class="rounded-lg border border-border bg-card overflow-hidden">
        <CameraSection
          bind:settings={cameraSettings}
          onMeasureWB={handleMeasureWB}
          {measuring}
          {isOnline}
          compact={false}
        />
      </div>
    </div>

    <!-- Right: Telemetry + Presets + Expert -->
    <div class="flex-[2] overflow-y-auto flex flex-col gap-2">
      <TelemetryPanel {telemetry} />

      <!-- Quick Presets -->
      <div class="flex flex-col gap-1.5 p-2 rounded-lg border border-border bg-card">
        <div class="flex items-center justify-between">
          <span class="text-[10px] font-semibold uppercase tracking-wider text-muted-foreground">Quick Presets</span>
          <button
            onclick={() => showPresetSave = !showPresetSave}
            class="text-[9px] text-muted-foreground hover:text-primary transition-colors"
          >{showPresetSave ? 'Cancel' : '+ Save current'}</button>
        </div>

        {#if showPresetSave}
          <div class="flex gap-1">
            <input
              type="text"
              bind:value={newPresetName}
              placeholder="Preset name..."
              class="flex-1 h-5 text-[10px] px-1 rounded-sm bg-input border border-border text-foreground placeholder:text-muted-foreground"
              maxlength="32"
            />
            <button
              onclick={handleSavePreset}
              disabled={!newPresetName.trim()}
              class="h-5 px-2 text-[10px] font-medium rounded-sm bg-primary text-primary-foreground hover:opacity-90 disabled:opacity-40 transition-opacity"
            >Save</button>
          </div>
        {/if}

        <div class="grid grid-cols-2 gap-1">
          {#each Object.entries($allPresets) as [key, preset]}
            <button
              onclick={() => applyPreset(key)}
              disabled={!isOnline}
              class="relative group h-6 text-[10px] font-medium rounded-sm bg-secondary text-secondary-foreground hover:bg-accent disabled:opacity-40 transition-colors truncate"
            >
              {preset.label}
              {#if !preset.builtin}
                <span
                  role="button"
                  tabindex="-1"
                  onclick={(e: MouseEvent) => { e.stopPropagation(); handleDeletePreset(key); }}
                  class="absolute right-0.5 top-1/2 -translate-y-1/2 h-4 w-4 flex items-center justify-center rounded-sm
                    opacity-0 group-hover:opacity-100 text-muted-foreground hover:text-destructive hover:bg-destructive/10 transition-all"
                  title="Delete preset"
                >
                  <svg class="h-2.5 w-2.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
                  </svg>
                </span>
              {/if}
            </button>
          {/each}
        </div>
      </div>

      <!-- Match Main Cam -->
      {#if otherCameras.length > 0}
        <div class="flex flex-col gap-1.5 p-2 rounded-lg border border-border bg-card">
          <span class="text-[10px] font-semibold uppercase tracking-wider text-muted-foreground">Match Camera</span>
          <div class="flex gap-1">
            <select
              bind:value={matchSourceId}
              class="flex-1 h-5 text-[10px] px-1 rounded-sm bg-input border border-border text-foreground"
            >
              <option value="">Select source...</option>
              {#each otherCameras as cam}
                <option value={cam.id}>{cam.alias}</option>
              {/each}
            </select>
            <button
              onclick={matchMainCam}
              disabled={!matchSourceId || !isOnline}
              class="h-5 px-2 text-[10px] font-medium rounded-sm bg-primary text-primary-foreground hover:opacity-90 disabled:opacity-40 transition-opacity"
            >Match</button>
          </div>
        </div>
      {/if}

      <!-- Expert -->
      <div class="flex flex-col gap-1 p-2 rounded-lg border border-border bg-card">
        <SectionBar label="Expert" bind:open={expertOpen} />
        {#if expertOpen}
          <div class="flex flex-col gap-1 text-[10px]">
            <div class="flex items-center gap-2">
              <span class="text-muted-foreground w-16">Host</span>
              <span class="font-mono text-foreground">{camera.ip}</span>
            </div>
            <div class="flex items-center gap-2">
              <span class="text-muted-foreground w-16">Port</span>
              <span class="font-mono text-foreground">{camera.port}</span>
            </div>
            {#if camera.flash_port}
              <div class="flex items-center gap-2">
                <span class="text-muted-foreground w-16">Flash Port</span>
                <span class="font-mono text-foreground">{camera.flash_port}</span>
              </div>
            {/if}
            <div class="flex items-center gap-2">
              <span class="text-muted-foreground w-16">Camera ID</span>
              <span class="font-mono text-foreground text-[9px] truncate">{camera.id}</span>
            </div>
          </div>
        {/if}
      </div>
    </div>
  </div>
</div>
