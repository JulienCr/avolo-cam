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
  export let onSettings: () => void;
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
      <h3 class="flex-1 text-lg font-semibold text-gray-900">{camera.alias}</h3>
      <button
        on:click={onRemove}
        class="rounded-md p-1 text-red-500 hover:bg-red-50 focus:outline-none focus:ring-2 focus:ring-red-500"
        aria-label="Remove camera"
      >
        ✕
      </button>
    </div>

    <!-- Info -->
    <div class="text-sm text-gray-600">
      <p><strong>IP:</strong> {camera.ip}:{camera.port}</p>
      <p class="flex items-center gap-2">
        <strong>State:</strong>
        <span
          class="inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium {isStreaming
            ? 'bg-green-100 text-green-700'
            : 'bg-gray-100 text-gray-600'}"
        >
          {#if isStreaming}
            <span class="h-1.5 w-1.5 rounded-full bg-green-500" />
          {/if}
          {camera.status?.ndi_state || 'unknown'}
        </span>
      </p>
    </div>

    <!-- Telemetry -->
    {#if telemetry}
      <div class="grid grid-cols-4 gap-3 rounded-lg bg-gray-50 p-3">
        <TelemetryBadge label="FPS" value={telemetry.fps.toFixed(1)} />
        <TelemetryBadge label="Bitrate" value={formatBitrate(telemetry.bitrate)} />
        <TelemetryBadge label="Battery" value={formatBattery(telemetry.battery)} />
        <TelemetryBadge label="Temp" value={formatTemperature(telemetry.temp_c)} />
      </div>
    {/if}

    <!-- Controls -->
    {#if camera.status}
      <div class="flex gap-2">
        {#if isStreaming}
          <Button variant="secondary" size="sm" on:click={onStop} class="flex-1">⏹ Stop</Button>
          <Button
            variant="ghost"
            size="sm"
            on:click={onForceKeyframe}
            title="Force IDR keyframe"
          >
            🔑
          </Button>
        {:else}
          <Button variant="primary" size="sm" on:click={onStart} class="flex-1">▶️ Start</Button>
        {/if}
        <Button variant="secondary" size="sm" on:click={onSettings} title="Camera Settings">
          ⚙️
        </Button>
      </div>
    {:else}
      <p class="text-center text-sm italic text-red-600">Disconnected</p>
    {/if}
  </div>
</Card>
