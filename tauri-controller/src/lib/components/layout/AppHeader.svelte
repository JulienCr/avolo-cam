<script lang="ts">
  import type { Camera } from '$lib/types/camera';
  import { formatBitrate } from '$lib/utils/format';
  import ConfirmButton from '$lib/components/ui/ConfirmButton.svelte';

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

  let counts = $derived(cameras.reduce((acc, c) => {
    if (c.status !== null) acc.online++;
    if (c.status?.ndi_state === 'streaming') acc.live++;
    return acc;
  }, { live: 0, online: 0 }));
  let liveCount = $derived(counts.live);
  let offlineCount = $derived(cameras.length - counts.online);
</script>

<header class="flex items-center justify-between h-10 px-3 border-b border-border bg-card shrink-0 select-none">
  <!-- Left: Logo + Status -->
  <div class="flex items-center gap-3">
    <span class="text-sm font-bold text-foreground tracking-tight">AvoloCam</span>
    {#if cameras.length > 0}
      <span class="text-[10px]">
        {#if liveCount > 0}
          <span class="text-green-400 font-medium">{liveCount} live</span>
        {/if}
        {#if offlineCount > 0}
          <span class="text-muted-foreground"> / {offlineCount} offline</span>
        {/if}
      </span>
    {/if}
    {#if totalBandwidth > 0}
      <span class="text-[10px] font-medium text-primary tabular-nums">{totalBandwidthStr} Mbps</span>
    {/if}
  </div>

  <!-- Right: Actions -->
  <div class="flex items-center gap-1">
    <button
      class="h-6 px-2.5 text-[10px] font-medium rounded-sm bg-secondary text-secondary-foreground hover:bg-accent disabled:opacity-40 transition-colors"
      onclick={onDiscover}
      disabled={discovering}
    >{discovering ? 'Scanning...' : 'Discover'}</button>

    <button
      class="h-6 px-2.5 text-[10px] font-medium rounded-sm bg-secondary text-secondary-foreground hover:bg-accent transition-colors"
      onclick={onAddCamera}
    >+ Add</button>

    <div class="w-px h-4 bg-border mx-1"></div>

    <ConfirmButton
      label="Start All"
      confirmLabel="Start All?"
      onclick={onStartAll}
      variant="primary"
      disabled={cameras.length === 0}
    />

    <ConfirmButton
      label="Stop All"
      confirmLabel="Stop All?"
      onclick={onStopAll}
      variant="destructive"
      disabled={cameras.length === 0}
    />

    <div class="w-px h-4 bg-border mx-1"></div>

    <button
      class="h-6 px-2.5 text-[10px] font-medium rounded-sm bg-secondary text-secondary-foreground hover:bg-accent transition-colors"
      onclick={onProfiles}
    >Profiles</button>

    <button
      class="h-6 px-2.5 text-[10px] font-medium rounded-sm bg-secondary text-secondary-foreground hover:bg-accent transition-colors"
      onclick={onRefresh}
    >Refresh</button>

    <button
      class="h-6 w-6 flex items-center justify-center rounded-sm bg-secondary text-secondary-foreground hover:bg-accent transition-colors"
      onclick={onSettings}
      title="Settings"
    >
      <svg class="h-3.5 w-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z" />
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
      </svg>
    </button>
  </div>
</header>
