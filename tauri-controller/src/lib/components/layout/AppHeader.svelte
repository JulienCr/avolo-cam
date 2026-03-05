<script lang="ts">
  import type { Camera } from '$lib/types/camera';
  import { formatBitrate } from '$lib/utils/format';

  let {
    cameras = [],
    discovering = false,
    onAddCamera,
    onProfiles,
    onRefresh,
    onDiscover,
    onSettings,
    onStartAll,
    onStopAll,
  }: {
    cameras: Camera[];
    discovering: boolean;
    onAddCamera: () => void;
    onProfiles: () => void;
    onRefresh: () => void;
    onDiscover: () => void;
    onSettings: () => void;
    onStartAll: () => void;
    onStopAll: () => void;
  } = $props();

  let totalBandwidth = $derived(
    cameras.reduce((sum, c) => sum + (c.status?.telemetry?.bitrate || 0), 0)
  );
  let totalBandwidthStr = $derived(formatBitrate(totalBandwidth));
</script>

<header class="flex items-center justify-between h-9 px-2 border-b border-border bg-card shrink-0 select-none">
  <div class="flex items-center gap-2">
    <span class="text-xs font-semibold text-foreground tracking-tight">AvoloCam</span>
    {#if totalBandwidth > 0}
      <span class="text-[10px] font-medium text-blue-400 tabular-nums">{totalBandwidthStr} Mbps</span>
    {/if}
  </div>

  <div class="flex items-center gap-1">
    <button
      class="h-6 px-2 text-[10px] font-medium rounded-sm bg-primary text-primary-foreground hover:opacity-90 disabled:opacity-40 transition-opacity"
      onclick={onStartAll}
      disabled={cameras.length === 0}
    >Start All</button>

    <button
      class="h-6 px-2 text-[10px] font-medium rounded-sm bg-destructive text-destructive-foreground hover:opacity-90 disabled:opacity-40 transition-opacity"
      onclick={onStopAll}
      disabled={cameras.length === 0}
    >Stop All</button>

    <div class="w-px h-4 bg-border mx-0.5"></div>

    <button
      class="h-6 px-2 text-[10px] font-medium rounded-sm bg-secondary text-secondary-foreground hover:bg-accent disabled:opacity-40 transition-colors"
      onclick={onDiscover}
      disabled={discovering}
    >{discovering ? 'Scanning...' : 'Discover'}</button>

    <button
      class="h-6 px-2 text-[10px] font-medium rounded-sm bg-secondary text-secondary-foreground hover:bg-accent transition-colors"
      onclick={onAddCamera}
    >+ Add</button>

    <button
      class="h-6 px-2 text-[10px] font-medium rounded-sm bg-secondary text-secondary-foreground hover:bg-accent transition-colors"
      onclick={onProfiles}
    >Profiles</button>

    <button
      class="h-6 px-2 text-[10px] font-medium rounded-sm bg-secondary text-secondary-foreground hover:bg-accent transition-colors"
      onclick={onRefresh}
    >Refresh</button>

    <button
      class="h-6 w-6 flex items-center justify-center rounded-sm bg-secondary text-secondary-foreground hover:bg-accent transition-colors"
      onclick={onSettings}
      title="Settings"
    >
      <svg class="h-3 w-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z" />
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
      </svg>
    </button>
  </div>
</header>
