<script lang="ts">
  import type { Camera } from '$lib/types/camera';
  import Button from '../atoms/Button.svelte';
  import { formatBitrate } from '$lib/utils/format';

  export let cameras: Camera[] = [];
  export let onAddCamera: () => void;
  export let onProfiles: () => void;
  export let onRefresh: () => void;
  export let onDiscover: () => void;
  export let discovering = false;

  // Calculate total bandwidth from all cameras
  $: totalBandwidth = cameras.reduce((sum, camera) => {
    const bitrate = camera.status?.telemetry?.bitrate || 0;
    return sum + bitrate;
  }, 0);

  $: totalBandwidthMbps = formatBitrate(totalBandwidth);
</script>

<header class="mb-6 flex flex-wrap items-center justify-between gap-4">
  <div class="flex items-center gap-4">
    <h1 class="text-3xl font-bold text-gray-900 dark:text-gray-100">
      🎥 AvoCam Controller
    </h1>
    {#if totalBandwidth > 0}
      <div class="flex items-center gap-2 rounded-lg bg-blue-50 px-3 py-1.5 dark:bg-blue-900/20">
        <svg class="h-4 w-4 text-blue-600 dark:text-blue-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z" />
        </svg>
        <span class="text-sm font-semibold text-blue-700 dark:text-blue-300">
          {totalBandwidthMbps} Mbps
        </span>
      </div>
    {/if}
  </div>

  <div class="flex gap-2">
    <Button variant="secondary" size="md" on:click={onDiscover} disabled={discovering}>
      {discovering ? '🔍 Discovering...' : '🔍 Discover'}
    </Button>
    <Button variant="secondary" size="md" on:click={onAddCamera}>
      + Add Camera
    </Button>
    <Button variant="secondary" size="md" on:click={onProfiles}>
      📋 Profiles
    </Button>
    <Button variant="secondary" size="md" on:click={onRefresh}>
      🔄 Refresh
    </Button>
  </div>
</header>
