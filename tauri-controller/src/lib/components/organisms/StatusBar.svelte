<script lang="ts">
  import type { Camera } from "$lib/types/camera";
  import Button from "../atoms/Button.svelte";
  import { formatBitrate } from "$lib/utils/format";

  export let cameras: Camera[] = [];
  export let onAddCamera: () => void;
  export let onProfiles: () => void;
  export let onRefresh: () => void;
  export let onDiscover: () => void;
  export let onSettings: () => void;
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
      🎥 AvoloCam Controller
    </h1>
    {#if totalBandwidth > 0}
      <div
        class="flex items-center gap-2 rounded-lg bg-blue-50 px-3 py-1.5 dark:bg-blue-900/20"
      >
        <svg
          class="h-4 w-4 text-blue-600 dark:text-blue-400"
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M13 10V3L4 14h7v7l9-11h-7z"
          />
        </svg>
        <span class="text-sm font-semibold text-blue-700 dark:text-blue-300">
          {totalBandwidthMbps} Mbps
        </span>
      </div>
    {/if}
  </div>

  <div class="flex gap-2">
    <Button
      variant="secondary"
      size="md"
      on:click={onDiscover}
      disabled={discovering}
    >
      {discovering ? "🔍 Discovering..." : "🔍 Discover"}
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
    <Button variant="secondary" size="md" on:click={onSettings}>
      <svg
        class="h-4 w-4"
        fill="none"
        stroke="currentColor"
        viewBox="0 0 24 24"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"
        />
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
        />
      </svg>
    </Button>
  </div>
</header>
