<script lang="ts">
  import type { Camera } from '$lib/types/camera';
  import StatusBadge from '$lib/components/ui/StatusBadge.svelte';
  import TelemetryBadge from '$lib/components/shared/TelemetryBadge.svelte';
  import StreamSection from '$lib/components/sections/StreamSection.svelte';
  import CameraSection from '$lib/components/sections/CameraSection.svelte';
  import { useCameraSettings } from '$lib/utils/use-camera-settings.svelte';
  import { openDetail, selectedCameraIds, toggleCameraSelection } from '$lib/stores/ui';
  import { formatBattery, formatTemperature, formatBitrate } from '$lib/utils/format';
  import * as api from '$lib/utils/api';

  let {
    camera,
    onRemove,
    onAliasUpdated,
  }: {
    camera: Camera;
    onRemove: () => void;
    onAliasUpdated: (alias: string) => void;
  } = $props();

  const ctrl = useCameraSettings(camera);

  let telemetry = $derived(camera.status?.telemetry);
  let streamingMode = $derived(camera.status?.current?.streaming_mode || 'ndi');
  let selected = $derived($selectedCameraIds.has(camera.id));

  let badgeStatus = $derived(
    ctrl.isStreaming ? 'live' as const :
    ctrl.isOnline ? 'ready' as const :
    'offline' as const
  );

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
      const alias = await api.updateAlias(camera.id, trimmed);
      onAliasUpdated(alias);
      isEditingAlias = false;
    } catch (e) {
      console.error('Failed to update alias:', e);
    } finally {
      aliasSaving = false;
    }
  }

  // Tabs
  let activeTab = $state<'stream' | 'image' | 'lens'>('stream');
</script>

<div class="flex flex-col rounded-lg border bg-card overflow-hidden transition-opacity
  {!ctrl.isOnline ? 'opacity-60 border-dashed' : 'border-border'}">

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

    {#if ctrl.isStreaming}
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
  {#if ctrl.isOnline && telemetry}
    <div class="flex items-center gap-3 px-3 py-1.5 border-b border-border">
      <TelemetryBadge label="BAT" value={formatBattery(telemetry.battery)} />
      <TelemetryBadge label="TEMP" value={formatTemperature(telemetry.temp_c)} warn={telemetry.temp_c > 40} />
      <TelemetryBadge label="CPU" value={`${telemetry.cpu_usage.toFixed(0)}%`} warn={telemetry.cpu_usage > 85} />
      <TelemetryBadge label="BIT" value={`${formatBitrate(telemetry.bitrate)} Mb`} />
      {#if telemetry.dropped_frames && telemetry.dropped_frames > 0}
        <TelemetryBadge label="DROP" value={String(telemetry.dropped_frames)} warn={true} />
      {/if}
    </div>
  {:else if !ctrl.isOnline}
    <div class="flex items-center gap-2 px-3 py-1.5 border-b border-border">
      <span class="text-[10px] text-muted-foreground italic">Changes apply on reconnect</span>
    </div>
  {/if}

  <!-- Start/Stop Stream — primary action, prominent -->
  {#if ctrl.isOnline}
    <div class="px-3 py-1.5 border-b border-border">
      {#if ctrl.isStreaming}
        <button
          onclick={ctrl.handleStopStream}
          class="w-full h-7 text-[11px] font-semibold rounded-sm bg-destructive text-destructive-foreground hover:opacity-90 transition-opacity"
        >Stop Stream</button>
      {:else}
        <button
          onclick={ctrl.handleStartStream}
          class="w-full h-7 text-[11px] font-semibold rounded-sm bg-primary text-primary-foreground hover:opacity-90 transition-opacity"
        >Start Stream</button>
      {/if}
    </div>
  {/if}

  <!-- Tabs (skip tab bar if only one tab) -->
  {#if ctrl.isOnline}
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
        bind:settings={ctrl.streamSettings}
        onStart={ctrl.handleStartStream}
        onStop={ctrl.handleStopStream}
        isStreaming={ctrl.isStreaming}
        isOnline={ctrl.isOnline}
        compact={true}
      />
    {:else if activeTab === 'image' && ctrl.isOnline}
      <CameraSection
        bind:settings={ctrl.cameraSettings}
        onMeasureWB={ctrl.handleMeasureWB}
        measuring={ctrl.measuring}
        isOnline={ctrl.isOnline}
        compact={true}
        showSections={['wb', 'exposure']}
      />
    {:else if activeTab === 'lens' && ctrl.isOnline}
      <CameraSection
        bind:settings={ctrl.cameraSettings}
        onMeasureWB={ctrl.handleMeasureWB}
        measuring={ctrl.measuring}
        isOnline={ctrl.isOnline}
        compact={true}
        showSections={['focus', 'lens', 'torch']}
      />
    {/if}
  </div>
</div>
