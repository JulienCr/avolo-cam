<script lang="ts">
  import type { Camera } from '$lib/types/camera';
  import Card from '../atoms/Card.svelte';
  import Button from '../atoms/Button.svelte';
  import Checkbox from '../atoms/Checkbox.svelte';
  import TelemetryBadge from '../molecules/TelemetryBadge.svelte';
  import { formatBitrate, formatBattery, formatTemperature } from '$lib/utils/format';

  export let camera: Camera;
  export let selected = false;
  export let onToggleSelection: () => void;
  export let onStart: () => void;
  export let onStop: () => void;
  export let onCameraSettings: () => void;
  export let onStreamSettings: () => void;
  export let onRemove: () => void;
  export let onForceKeyframe: () => void;

  $: isStreaming = camera.status?.ndi_state === 'streaming';
  $: telemetry = camera.status?.telemetry;
</script>

<Card padding="md" interactive>
  <div class="flex flex-col gap-4">
    <!-- Header -->
    <div class="flex items-center gap-3">
      <Checkbox bind:checked={selected} on:change={onToggleSelection} label="Select camera" />
      <h3 class="flex-1 text-base font-semibold text-gray-900 dark:text-gray-100">{camera.alias}</h3>
      <button
        on:click={onRemove}
        class="rounded-md p-1.5 text-gray-400 transition-colors hover:bg-red-50 hover:text-red-600 focus:outline-none focus:ring-2 focus:ring-red-500 dark:hover:bg-red-900/20 dark:hover:text-red-400"
        aria-label="Remove camera"
      >
        <svg class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
        </svg>
      </button>
    </div>

    <!-- Info -->
    <div class="flex items-center justify-between text-sm">
      <span class="text-gray-600 dark:text-gray-400">{camera.ip}:{camera.port}</span>
      <span
        class="inline-flex items-center gap-1.5 rounded-full px-2.5 py-0.5 text-xs font-medium {isStreaming
          ? 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400'
          : 'bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-400'}"
      >
        {#if isStreaming}
          <span class="h-1.5 w-1.5 rounded-full bg-green-500 dark:bg-green-400" />
        {/if}
        {camera.status?.ndi_state || 'unknown'}
      </span>
    </div>

    <!-- Telemetry -->
    {#if telemetry}
      <div class="grid grid-cols-4 gap-3 rounded-lg bg-gray-50 p-3 dark:bg-gray-800/50">
        <TelemetryBadge label="FPS" value={telemetry.fps.toFixed(1)} />
        <TelemetryBadge label="Bitrate" value={formatBitrate(telemetry.bitrate)} />
        <TelemetryBadge label="Battery" value={formatBattery(telemetry.battery)} />
        <TelemetryBadge label="Temp" value={formatTemperature(telemetry.temp_c)} />
      </div>
    {/if}

    <!-- Controls -->
    {#if camera.status}
      <div class="flex flex-col gap-2">
        <!-- Streaming Controls -->
        <div class="flex gap-2">
          {#if isStreaming}
            <Button variant="secondary" size="sm" on:click={onStop} class="flex-1">
              <svg class="h-3.5 w-3.5" fill="currentColor" viewBox="0 0 24 24">
                <rect x="6" y="6" width="12" height="12" />
              </svg>
              Stop
            </Button>
            <Button
              variant="ghost"
              size="sm"
              on:click={onForceKeyframe}
              title="Force IDR keyframe"
            >
              <svg class="h-3.5 w-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z" />
              </svg>
            </Button>
          {:else}
            <Button variant="primary" size="sm" on:click={onStart} class="flex-1">
              <svg class="h-3.5 w-3.5" fill="currentColor" viewBox="0 0 24 24">
                <path d="M8 5v14l11-7z" />
              </svg>
              Start
            </Button>
          {/if}
        </div>

        <!-- Settings Controls -->
        <div class="flex gap-2">
          <Button variant="secondary" size="sm" on:click={onCameraSettings} class="flex-1">
            <svg class="h-3.5 w-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 9a2 2 0 012-2h.93a2 2 0 001.664-.89l.812-1.22A2 2 0 0110.07 4h3.86a2 2 0 011.664.89l.812 1.22A2 2 0 0018.07 7H19a2 2 0 012 2v9a2 2 0 01-2 2H5a2 2 0 01-2-2V9z" />
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 13a3 3 0 11-6 0 3 3 0 016 0z" />
            </svg>
            Camera
          </Button>
          <Button variant="secondary" size="sm" on:click={onStreamSettings} class="flex-1">
            <svg class="h-3.5 w-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z" />
            </svg>
            Stream
          </Button>
        </div>
      </div>
    {:else}
      <p class="py-2 text-center text-sm font-medium italic text-red-600 dark:text-red-400">Disconnected</p>
    {/if}
  </div>
</Card>
