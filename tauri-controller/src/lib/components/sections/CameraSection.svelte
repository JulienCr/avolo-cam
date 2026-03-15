<script lang="ts">
  import type { CameraSettings } from '$lib/types/settings';
  import type { LensType } from '$lib/types/camera';
  import { getLensFromZoom, getZoomFromLens } from '$lib/stores/settings';
  import { formatShutterSpeed } from '$lib/utils/format';
  import SliderField from '$lib/components/ui/SliderField.svelte';

  let {
    settings = $bindable(),
    onMeasureWB,
    measuring = false,
    isOnline = false,
    compact = false,
    showSections,
  }: {
    settings: CameraSettings;
    onMeasureWB: () => Promise<void>;
    measuring: boolean;
    isOnline: boolean;
    compact?: boolean;
    showSections?: ('wb' | 'exposure' | 'focus' | 'lens' | 'torch')[];
  } = $props();

  let open = $state(true);

  let selectedLens = $derived(getLensFromZoom(settings.zoom_factor));
  let isBackCamera = $derived(settings.camera_position === 'back');

  function handleLensChange(lens: LensType) {
    settings.lens = lens;
    settings.zoom_factor = getZoomFromLens(lens);
  }

  function shouldShow(section: string): boolean {
    if (!showSections) return true;
    return showSections.includes(section as any);
  }
</script>

<!-- Mini segmented [A|M] toggle -->
{#snippet modeToggle(mode: string, onToggle: (isManual: boolean) => void)}
  <div class="flex shrink-0">
    <button
      onclick={() => { if (mode === 'manual') onToggle(false); }}
      class="w-5 h-5 text-[9px] font-semibold rounded-l transition-colors
        {mode === 'auto' ? 'bg-primary text-primary-foreground' : 'bg-secondary/60 text-muted-foreground hover:bg-secondary'}"
    >A</button>
    <button
      onclick={() => { if (mode === 'auto') onToggle(true); }}
      class="w-5 h-5 text-[9px] font-semibold rounded-r transition-colors
        {mode === 'manual' ? 'bg-primary text-primary-foreground' : 'bg-secondary/60 text-muted-foreground hover:bg-secondary'}"
    >M</button>
  </div>
{/snippet}

<!-- White Balance group block -->
{#snippet wbGroup()}
  <div class="bg-secondary/40 border border-border/50 rounded p-2 flex flex-col gap-1">
    <div class="flex items-center justify-between">
      <span class="text-[10px] font-medium text-foreground">White Balance</span>
      {@render modeToggle(settings.wb_mode, (manual) => settings.wb_mode = manual ? 'manual' : 'auto')}
    </div>
    <SliderField label="Temp" bind:value={settings.wb_kelvin} min={2000} max={10000} step={100} display="{settings.wb_kelvin}K" disabled={settings.wb_mode === 'auto'} gradient="linear-gradient(to right, var(--k-2000), var(--k-3000), var(--k-5500), var(--k-8000), var(--k-10000))" labelWidth="w-10" />
    <SliderField label="Tint" bind:value={settings.wb_tint} min={-100} max={100} step={1} display="{settings.wb_tint}" disabled={settings.wb_mode === 'auto'} gradient="linear-gradient(to right, var(--t-green), var(--t-neutral), var(--t-magenta))" labelWidth="w-10" />
    {#if settings.wb_mode === 'manual'}
      <button
        onclick={onMeasureWB}
        disabled={measuring || !isOnline}
        class="h-5 text-[10px] font-medium rounded-sm border border-primary/50 text-primary hover:bg-primary/10 disabled:opacity-40 transition-colors"
      >{measuring ? 'Measuring...' : 'Auto Calibrate'}</button>
    {/if}
  </div>
{/snippet}

<!-- Lens group block -->
{#snippet lensGroup()}
  <div class="bg-secondary/40 border border-border/50 rounded p-2 flex flex-col gap-1">
    <div class="flex items-center justify-between">
      <span class="text-[10px] font-medium text-foreground">Lens</span>
      <div class="flex shrink-0">
        <button
          onclick={() => { if (!isBackCamera) settings.camera_position = 'back'; }}
          class="px-1.5 h-5 text-[9px] font-semibold rounded-l transition-colors
            {isBackCamera ? 'bg-primary text-primary-foreground' : 'bg-secondary/60 text-muted-foreground hover:bg-secondary'}"
        >Back</button>
        <button
          onclick={() => { if (isBackCamera) settings.camera_position = 'front'; }}
          class="px-1.5 h-5 text-[9px] font-semibold rounded-r transition-colors
            {!isBackCamera ? 'bg-primary text-primary-foreground' : 'bg-secondary/60 text-muted-foreground hover:bg-secondary'}"
        >Front</button>
      </div>
    </div>
    {#if isBackCamera}
      <div class="flex gap-0.5">
        {#each [{ id: 'ultra_wide', label: 'UW' }, { id: 'wide', label: 'W' }, { id: 'telephoto', label: 'T' }] as lens}
          <button
            onclick={() => handleLensChange(lens.id as LensType)}
            class="flex-1 h-5 text-[10px] font-medium rounded-sm transition-colors
              {selectedLens === lens.id ? 'bg-primary text-primary-foreground' : 'bg-secondary text-secondary-foreground hover:bg-accent'}"
          >{lens.label}</button>
        {/each}
      </div>
    {/if}
    <SliderField label="Zoom" bind:value={settings.zoom_factor} min={0.5} max={15} step={0.1} display="{settings.zoom_factor.toFixed(1)}x" labelWidth="w-10" />
  </div>
{/snippet}

{#if compact}
  <!-- Compact mode (CameraCard tabs) -->
  <div class="flex flex-col gap-1.5">
    {#if !isOnline}
      <div class="py-0.5 px-1.5 rounded bg-amber-500/10 text-amber-400">
        <span class="text-[10px] italic">Pending — will apply on connect</span>
      </div>
    {/if}

    {#if shouldShow('wb')}
      {@render wbGroup()}
    {/if}

    {#if shouldShow('exposure') || shouldShow('focus')}
      <div class="bg-secondary/40 border border-border/50 rounded p-2 flex flex-col gap-1">
        {#if shouldShow('exposure')}
          <div class="flex items-center gap-1.5">
            <div class="flex-1 {settings.iso_mode === 'auto' ? 'opacity-40 pointer-events-none' : ''}">
              <SliderField label="ISO" bind:value={settings.iso} min={50} max={3200} step={50} display="{settings.iso}" />
            </div>
            {@render modeToggle(settings.iso_mode, (manual) => settings.iso_mode = manual ? 'manual' : 'auto')}
          </div>
          <div class="flex items-center gap-1.5">
            <div class="flex-1 {settings.shutter_mode === 'auto' ? 'opacity-40 pointer-events-none' : ''}">
              <SliderField label="Shutter" bind:value={settings.shutter_s} min={0.001} max={0.1} step={0.001} display={formatShutterSpeed(settings.shutter_s)} />
            </div>
            {@render modeToggle(settings.shutter_mode, (manual) => settings.shutter_mode = manual ? 'manual' : 'auto')}
          </div>
        {/if}
        {#if shouldShow('focus')}
          <div class="flex items-center gap-1.5">
            <div class="flex-1 {settings.focus_mode === 'auto' ? 'opacity-40 pointer-events-none' : ''}">
              <SliderField label="Focus" bind:value={settings.focus_distance} min={0} max={1} step={0.01} display={settings.focus_distance.toFixed(2)} />
            </div>
            {@render modeToggle(settings.focus_mode, (manual) => settings.focus_mode = manual ? 'manual' : 'auto')}
          </div>
        {/if}
      </div>
    {/if}

    {#if shouldShow('lens')}
      {@render lensGroup()}
    {/if}

    {#if shouldShow('torch')}
      <div class="bg-secondary/40 border border-border/50 rounded p-2">
        <div class="flex items-center gap-1.5">
          <div class="flex-1 {settings.torch_mode === 'auto' ? 'opacity-40 pointer-events-none' : ''}">
            <SliderField label="Torch" bind:value={settings.torch_level} min={0.01} max={1} step={0.01} display="{(settings.torch_level * 100).toFixed(0)}%" />
          </div>
          {@render modeToggle(settings.torch_mode, (manual) => settings.torch_mode = manual ? 'manual' : 'auto')}
        </div>
      </div>
    {/if}
  </div>

{:else}
  <!-- Full mode (DetailView) -->
  <div class="border-b border-border">
    <button
      onclick={() => open = !open}
      class="w-full flex items-center justify-between px-2 py-1.5 text-[10px] font-semibold uppercase tracking-wider text-muted-foreground hover:text-foreground transition-colors"
    >
      <span>Camera</span>
      <svg class="h-3 w-3 transition-transform {open ? 'rotate-180' : ''}" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
      </svg>
    </button>

    {#if open}
      <div class="px-3 pb-3 flex flex-col gap-1.5">
        {#if !isOnline}
          <div class="py-0.5 px-1.5 rounded bg-amber-500/10 text-amber-400 mb-2">
            <span class="text-[10px] italic">Pending — will apply on connect</span>
          </div>
        {/if}

        <!-- White Balance (grouped) -->
        {@render wbGroup()}

        <!-- Exposure + Focus (grouped) -->
        <div class="bg-secondary/40 border border-border/50 rounded p-2 flex flex-col gap-1">
          <div class="flex items-center gap-1.5">
            <div class="flex-1 {settings.iso_mode === 'auto' ? 'opacity-40 pointer-events-none' : ''}">
              <SliderField label="ISO" bind:value={settings.iso} min={50} max={3200} step={50} display="{settings.iso}" />
            </div>
            {@render modeToggle(settings.iso_mode, (manual) => settings.iso_mode = manual ? 'manual' : 'auto')}
          </div>
          <div class="flex items-center gap-1.5">
            <div class="flex-1 {settings.shutter_mode === 'auto' ? 'opacity-40 pointer-events-none' : ''}">
              <SliderField label="Shutter" bind:value={settings.shutter_s} min={0.001} max={0.1} step={0.001} display={formatShutterSpeed(settings.shutter_s)} />
            </div>
            {@render modeToggle(settings.shutter_mode, (manual) => settings.shutter_mode = manual ? 'manual' : 'auto')}
          </div>
          <div class="flex items-center gap-1.5">
            <div class="flex-1 {settings.focus_mode === 'auto' ? 'opacity-40 pointer-events-none' : ''}">
              <SliderField label="Focus" bind:value={settings.focus_distance} min={0} max={1} step={0.01} display={settings.focus_distance.toFixed(2)} />
            </div>
            {@render modeToggle(settings.focus_mode, (manual) => settings.focus_mode = manual ? 'manual' : 'auto')}
          </div>
        </div>

        <!-- Lens (grouped) -->
        {@render lensGroup()}

        <!-- Torch (grouped) -->
        <div class="bg-secondary/40 border border-border/50 rounded p-2">
          <div class="flex items-center gap-1.5">
            <div class="flex-1 {settings.torch_mode === 'auto' ? 'opacity-40 pointer-events-none' : ''}">
              <SliderField label="Torch" bind:value={settings.torch_level} min={0.01} max={1} step={0.01} display="{(settings.torch_level * 100).toFixed(0)}%" />
            </div>
            {@render modeToggle(settings.torch_mode, (manual) => settings.torch_mode = manual ? 'manual' : 'auto')}
          </div>
        </div>
      </div>
    {/if}
  </div>
{/if}
