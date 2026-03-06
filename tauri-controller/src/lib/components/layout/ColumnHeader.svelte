<script lang="ts">
  import type { Camera } from '$lib/types/camera';
  import StatusDot from '../shared/StatusDot.svelte';
  import TelemetryBadge from '../shared/TelemetryBadge.svelte';
  import { formatBattery, formatTemperature, formatBitrate } from '$lib/utils/format';
  import * as api from '$lib/utils/api';
  import { cameraStreamSettings } from '$lib/stores/settings';

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
  let connectionStatus = $derived(
    isOnline ? 'connected' as const : 'disconnected' as const
  );
  let telemetry = $derived(camera.status?.telemetry);
  let isStreaming = $derived(camera.status?.ndi_state === 'streaming');
  let streamingMode = $derived(camera.status?.current?.streaming_mode || 'ndi');

  // Alias editing
  let isEditingAlias = $state(false);
  let editedAlias = $state(camera.alias);
  let aliasSaving = $state(false);

  function startEditingAlias() {
    isEditingAlias = true;
    editedAlias = camera.alias;
  }

  function cancelEditingAlias() {
    isEditingAlias = false;
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

  // SRT copy
  let copiedSrt = $state(false);
  let cameraSettings = $derived($cameraStreamSettings[camera.id]);
  let configuredStreamingMode = $derived(cameraSettings?.streaming_mode || 'ndi');
  let configuredSrtPort = $derived(cameraSettings?.srt_port || 9000);
  let constructedSrtUrl = $derived(`srt://${camera.ip}:${configuredSrtPort}?mode=caller`);

  async function copyToClipboard(text: string) {
    try {
      await navigator.clipboard.writeText(text);
      copiedSrt = true;
      setTimeout(() => copiedSrt = false, 2000);
    } catch { /* ignore */ }
  }

  // MIDI channel
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
</script>

<div class="sticky top-0 z-10 bg-card border-b border-border px-2 py-1.5 select-none">
  <!-- Row 1: Checkbox + Name + Status + Remove -->
  <div class="flex items-center gap-1.5 min-h-[20px]">
    <input
      type="checkbox"
      checked={selected}
      onchange={onToggleSelection}
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
        <button onclick={cancelEditingAlias} class="text-[10px] text-muted-foreground hover:underline">X</button>
      </div>
    {:else}
      <button
        onclick={startEditingAlias}
        class="flex-1 min-w-0 text-left text-[11px] font-semibold text-foreground truncate hover:text-primary transition-colors"
        title="Click to rename"
      >{camera.alias}</button>
    {/if}

    <StatusDot status={connectionStatus} />

    {#if isStreaming}
      <span class="mode-badge {streamingMode === 'ndi' ? 'mode-badge-ndi' : streamingMode === 'flash' ? 'mode-badge-flash' : 'mode-badge-srt'}">
        {streamingMode === 'ndi' ? 'NDI' : streamingMode === 'flash' ? 'FLASH' : 'SRT'}
      </span>
    {/if}

    <button
      onclick={onRemove}
      class="h-4 w-4 flex items-center justify-center text-muted-foreground hover:text-destructive transition-colors shrink-0"
      title="Remove camera"
    >
      <svg class="h-3 w-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
      </svg>
    </button>
  </div>

  <!-- Row 2: IP + SRT badge + MIDI -->
  <div class="flex items-center gap-1.5 mt-0.5">
    <span class="text-[10px] text-muted-foreground font-mono">{camera.ip}:{camera.port}</span>

    {#if configuredStreamingMode === 'srt'}
      <button
        onclick={() => copyToClipboard(constructedSrtUrl)}
        class="text-[9px] px-1 py-0 rounded-sm bg-green-900/30 text-green-400 hover:bg-green-800/40 transition-colors"
        title="Copy SRT URL"
      >{copiedSrt ? 'Copied' : 'SRT'}</button>
    {/if}

    <div class="flex-1"></div>

    <select
      bind:value={selectedMidiChannel}
      onchange={handleMidiChannelChange}
      disabled={midiChannelSaving}
      class="h-4 text-[9px] px-0.5 rounded-sm bg-secondary border border-border text-secondary-foreground cursor-pointer disabled:opacity-40"
    >
      <option value="">MIDI: --</option>
      {#each [1, 2, 3, 4, 5, 6, 7, 8] as ch}
        <option value={ch.toString()}>MIDI: {ch}</option>
      {/each}
    </select>
  </div>

  <!-- Row 3: Telemetry (only when online) -->
  {#if !isOnline}
    <div class="mt-1">
      <span class="text-[10px] font-medium text-red-400">Offline</span>
    </div>
  {:else if telemetry}
    <div class="flex items-center gap-2 mt-1">
      <TelemetryBadge label="BAT" value={formatBattery(telemetry.battery)} />
      <TelemetryBadge label="TEMP" value={formatTemperature(telemetry.temp_c)} warn={telemetry.temp_c > 40} />
      <TelemetryBadge label="CPU" value={`${telemetry.cpu_usage.toFixed(0)}%`} warn={telemetry.cpu_usage > 85} />
      <TelemetryBadge label="BIT" value={`${formatBitrate(telemetry.bitrate)} Mb`} />
      {#if telemetry.dropped_frames && telemetry.dropped_frames > 0}
        <TelemetryBadge label="DROP" value={String(telemetry.dropped_frames)} warn={true} />
      {/if}
    </div>
  {/if}
</div>
