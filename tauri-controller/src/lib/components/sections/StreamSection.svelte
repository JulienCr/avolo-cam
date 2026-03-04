<script lang="ts">
  import type { StreamSettings } from '$lib/types/settings';
  import { detectedLocalIP } from '$lib/stores/settings';
  import { get } from 'svelte/store';

  let {
    settings = $bindable(),
    onStart,
    onStop,
    isStreaming = false,
    isOnline = false,
  }: {
    settings: StreamSettings;
    onStart: () => void;
    onStop: () => void;
    isStreaming: boolean;
    isOnline: boolean;
  } = $props();

  let open = $state(true);

  const resolutionOptions = [
    { value: '1280x720', label: '720p' },
    { value: '1920x1080', label: '1080p' },
    { value: '2560x1440', label: '1440p' },
    { value: '3840x2160', label: '4K' },
  ];

  const framerateOptions = [
    { value: 24, label: '24' },
    { value: 25, label: '25' },
    { value: 30, label: '30' },
    { value: 60, label: '60' },
  ];

  const bitrateOptions = [
    { value: 5000000, label: '5 Mbps' },
    { value: 8000000, label: '8 Mbps' },
    { value: 10000000, label: '10 Mbps' },
    { value: 15000000, label: '15 Mbps' },
    { value: 20000000, label: '20 Mbps' },
    { value: 30000000, label: '30 Mbps' },
    { value: 50000000, label: '50 Mbps' },
  ];

  const codecOptions = [
    { value: 'h264', label: 'H.264' },
    { value: 'hevc', label: 'HEVC' },
  ];

  const modeOptions = [
    { value: 'ndi', label: 'NDI' },
    { value: 'srt', label: 'SRT' },
    { value: 'flash', label: 'Flash' },
  ];

  const flashJitterOptions = [
    { value: 'ultra_low', label: 'Ultra-Low' },
    { value: 'stable', label: 'Stable' },
  ];

  let gopLatencyMs = $derived(
    settings.srt_gop_size && settings.framerate
      ? Math.round((settings.srt_gop_size / settings.framerate) * 1000)
      : 0
  );

  let localIP = $derived(get(detectedLocalIP) || '');
  let effectiveFlashHost = $derived(settings.flash_destination_host || localIP || 'N/A');
  let effectiveFlashPort = $derived(settings.flash_destination_port ?? 5000);
</script>

<div class="border-b border-border">
  <!-- Section header -->
  <button
    onclick={() => open = !open}
    class="w-full flex items-center justify-between px-2 py-1 text-[10px] font-semibold uppercase tracking-wider text-muted-foreground hover:text-foreground transition-colors"
  >
    <span>Stream</span>
    <svg class="h-3 w-3 transition-transform {open ? 'rotate-180' : ''}" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
    </svg>
  </button>

  {#if open}
    <div class="px-2 pb-2 flex flex-col gap-1.5">
      <!-- Mode -->
      <div class="flex items-center gap-1">
        <label class="text-[10px] text-muted-foreground w-12 shrink-0">Mode</label>
        <select bind:value={settings.streaming_mode} class="flex-1 h-5 text-[10px] px-1 rounded-sm bg-input border border-border text-foreground">
          {#each modeOptions as opt}
            <option value={opt.value}>{opt.label}</option>
          {/each}
        </select>
      </div>

      <!-- Resolution -->
      <div class="flex items-center gap-1">
        <label class="text-[10px] text-muted-foreground w-12 shrink-0">Res</label>
        <select bind:value={settings.resolution} class="flex-1 h-5 text-[10px] px-1 rounded-sm bg-input border border-border text-foreground">
          {#each resolutionOptions as opt}
            <option value={opt.value}>{opt.label}</option>
          {/each}
        </select>
      </div>

      <!-- FPS + Codec row -->
      <div class="flex items-center gap-1">
        <label class="text-[10px] text-muted-foreground w-12 shrink-0">FPS</label>
        <select bind:value={settings.framerate} class="flex-1 h-5 text-[10px] px-1 rounded-sm bg-input border border-border text-foreground">
          {#each framerateOptions as opt}
            <option value={opt.value}>{opt.label}</option>
          {/each}
        </select>
        <select bind:value={settings.codec} class="w-14 h-5 text-[10px] px-1 rounded-sm bg-input border border-border text-foreground">
          {#each codecOptions as opt}
            <option value={opt.value}>{opt.label}</option>
          {/each}
        </select>
      </div>

      <!-- Bitrate -->
      <div class="flex items-center gap-1">
        <label class="text-[10px] text-muted-foreground w-12 shrink-0">Bitrate</label>
        <select bind:value={settings.bitrate} class="flex-1 h-5 text-[10px] px-1 rounded-sm bg-input border border-border text-foreground">
          {#each bitrateOptions as opt}
            <option value={opt.value}>{opt.label}</option>
          {/each}
        </select>
      </div>

      <!-- SRT settings -->
      {#if settings.streaming_mode === 'srt'}
        <div class="border-t border-border pt-1.5 mt-0.5 flex flex-col gap-1.5">
          <div class="flex items-center gap-1">
            <label class="text-[10px] text-muted-foreground w-12 shrink-0">Port</label>
            <span class="text-[10px] text-foreground font-mono">{settings.srt_port ?? 9000}</span>
          </div>
          <div class="flex items-center gap-1">
            <label class="text-[10px] text-muted-foreground w-12 shrink-0">Latency</label>
            <input type="range" bind:value={settings.srt_latency} min={20} max={500} step={10} class="flex-1 h-3 accent-primary" />
            <span class="text-[10px] text-foreground w-10 text-right tabular-nums">{settings.srt_latency ?? 80}ms</span>
          </div>
          <div class="flex items-center gap-1">
            <label class="text-[10px] text-muted-foreground w-12 shrink-0">GOP</label>
            <input type="range" bind:value={settings.srt_gop_size} min={2} max={30} step={1} class="flex-1 h-3 accent-primary" />
            <span class="text-[10px] text-foreground w-12 text-right tabular-nums">{settings.srt_gop_size ?? 3}f ~{gopLatencyMs}ms</span>
          </div>
        </div>
      {/if}

      <!-- Flash settings -->
      {#if settings.streaming_mode === 'flash'}
        <div class="border-t border-border pt-1.5 mt-0.5 flex flex-col gap-1.5">
          <div class="flex items-center gap-1">
            <label class="text-[10px] text-muted-foreground w-12 shrink-0">Dest</label>
            <span class="text-[10px] text-foreground font-mono truncate">{effectiveFlashHost}:{effectiveFlashPort}</span>
            {#if !settings.flash_destination_host && localIP}
              <span class="text-[9px] text-muted-foreground">(auto)</span>
            {/if}
          </div>
          <div class="flex items-center gap-1">
            <label class="text-[10px] text-muted-foreground w-12 shrink-0">Jitter</label>
            <select bind:value={settings.flash_jitter_mode} class="flex-1 h-5 text-[10px] px-1 rounded-sm bg-input border border-border text-foreground">
              {#each flashJitterOptions as opt}
                <option value={opt.value}>{opt.label}</option>
              {/each}
            </select>
          </div>
          <div class="flex items-center gap-1">
            <label class="text-[10px] text-muted-foreground w-12 shrink-0">GOP</label>
            <input type="range" bind:value={settings.srt_gop_size} min={1} max={60} step={1} class="flex-1 h-3 accent-primary" />
            <span class="text-[10px] text-foreground w-8 text-right tabular-nums">{settings.srt_gop_size ?? 25}f</span>
          </div>
        </div>
      {/if}

      <!-- Start/Stop button -->
      {#if isOnline}
        <div class="mt-1">
          {#if isStreaming}
            <button
              onclick={onStop}
              class="w-full h-6 text-[10px] font-medium rounded-sm bg-destructive text-destructive-foreground hover:opacity-90 transition-opacity"
            >Stop Stream</button>
          {:else}
            <button
              onclick={onStart}
              class="w-full h-6 text-[10px] font-medium rounded-sm bg-primary text-primary-foreground hover:opacity-90 transition-opacity"
            >Start Stream</button>
          {/if}
        </div>
      {/if}
    </div>
  {/if}
</div>
