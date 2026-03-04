<script lang="ts">
  import type { CameraSettings } from '$lib/types/settings';
  import type { LensType } from '$lib/types/camera';
  import { getLensFromZoom, getZoomFromLens } from '$lib/stores/settings';

  let {
    settings = $bindable(),
    onMeasureWB,
    measuring = false,
    isOnline = false,
  }: {
    settings: CameraSettings;
    onMeasureWB: () => Promise<void>;
    measuring: boolean;
    isOnline: boolean;
  } = $props();

  let open = $state(true);
  let wbOpen = $state(true);
  let exposureOpen = $state(true);
  let focusOpen = $state(true);
  let lensOpen = $state(true);
  let torchOpen = $state(false);

  let selectedLens = $derived(getLensFromZoom(settings.zoom_factor));
  let isBackCamera = $derived(settings.camera_position === 'back');

  function handleLensChange(lens: LensType) {
    settings.lens = lens;
    settings.zoom_factor = getZoomFromLens(lens);
  }
</script>

{#snippet subSection(title: string, isOpen: boolean, toggle: () => void)}
  <button
    onclick={toggle}
    class="w-full flex items-center justify-between py-0.5 text-[10px] font-medium text-muted-foreground hover:text-foreground transition-colors"
  >
    <span>{title}</span>
    <svg class="h-2.5 w-2.5 transition-transform {isOpen ? 'rotate-180' : ''}" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
    </svg>
  </button>
{/snippet}

{#snippet sliderRow(label: string, value: number, onInput: (v: number) => void, min: number, max: number, step: number, display: string, disabled: boolean, gradient?: string)}
  <div class="flex items-center gap-1 {disabled ? 'opacity-40' : ''}">
    <label class="text-[10px] text-muted-foreground w-14 shrink-0">{label}</label>
    <input
      type="range"
      {value}
      oninput={(e) => onInput(parseFloat((e.target as HTMLInputElement).value))}
      {min} {max} {step}
      {disabled}
      class="flex-1 h-3 accent-primary"
      style={gradient ? `background: ${gradient}` : ''}
    />
    <span class="text-[10px] text-foreground w-12 text-right tabular-nums shrink-0">{display}</span>
  </div>
{/snippet}

{#snippet modeToggle(label: string, mode: string, onToggle: (isManual: boolean) => void)}
  <div class="flex items-center justify-between">
    <span class="text-[10px] text-muted-foreground">{label}</span>
    <div class="flex items-center gap-1">
      <span class="text-[9px] text-muted-foreground">A</span>
      <button
        onclick={() => onToggle(mode === 'auto')}
        class="w-6 h-3 rounded-full relative transition-colors {mode === 'manual' ? 'bg-primary' : 'bg-border'}"
        aria-label="Toggle {label} mode"
      >
        <span class="absolute top-0.5 h-2 w-2 rounded-full bg-white transition-transform {mode === 'manual' ? 'left-3.5' : 'left-0.5'}"></span>
      </button>
      <span class="text-[9px] text-muted-foreground">M</span>
    </div>
  </div>
{/snippet}

<div class="border-b border-border">
  <button
    onclick={() => open = !open}
    class="w-full flex items-center justify-between px-2 py-1 text-[10px] font-semibold uppercase tracking-wider text-muted-foreground hover:text-foreground transition-colors"
  >
    <span>Camera</span>
    <svg class="h-3 w-3 transition-transform {open ? 'rotate-180' : ''}" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
    </svg>
  </button>

  {#if open && isOnline}
    <div class="px-2 pb-2 flex flex-col gap-1">

      <!-- White Balance -->
      <div>
        {@render subSection('White Balance', wbOpen, () => wbOpen = !wbOpen)}
        {#if wbOpen}
          <div class="flex flex-col gap-1 pl-1">
            {@render modeToggle('WB', settings.wb_mode, (manual) => settings.wb_mode = manual ? 'manual' : 'auto')}
            {@render sliderRow(
              'Temp',
              settings.wb_kelvin,
              (v) => settings.wb_kelvin = v,
              2000, 10000, 100,
              `${settings.wb_kelvin}K`,
              settings.wb_mode === 'auto',
              'linear-gradient(to right, var(--k-2000), var(--k-3000), var(--k-5500), var(--k-8000), var(--k-10000))'
            )}
            {@render sliderRow(
              'Tint',
              settings.wb_tint,
              (v) => settings.wb_tint = v,
              -100, 100, 1,
              `${settings.wb_tint}`,
              settings.wb_mode === 'auto',
              'linear-gradient(to right, var(--t-green), var(--t-neutral), var(--t-magenta))'
            )}
            {#if settings.wb_mode === 'manual'}
              <button
                onclick={onMeasureWB}
                disabled={measuring}
                class="h-5 text-[10px] font-medium rounded-sm bg-primary text-primary-foreground hover:opacity-90 disabled:opacity-40 transition-opacity"
              >{measuring ? 'Measuring...' : 'Auto Calibrate'}</button>
            {/if}
          </div>
        {/if}
      </div>

      <!-- Exposure -->
      <div>
        {@render subSection('Exposure', exposureOpen, () => exposureOpen = !exposureOpen)}
        {#if exposureOpen}
          <div class="flex flex-col gap-1 pl-1">
            {@render modeToggle('ISO', settings.iso_mode, (manual) => settings.iso_mode = manual ? 'manual' : 'auto')}
            {@render sliderRow(
              'ISO',
              settings.iso,
              (v) => settings.iso = v,
              50, 3200, 50,
              `${settings.iso}`,
              settings.iso_mode === 'auto'
            )}
            {@render modeToggle('Shutter', settings.shutter_mode, (manual) => settings.shutter_mode = manual ? 'manual' : 'auto')}
            {@render sliderRow(
              'Shutter',
              settings.shutter_s,
              (v) => settings.shutter_s = v,
              0.001, 0.1, 0.001,
              `1/${Math.round(1 / settings.shutter_s)}`,
              settings.shutter_mode === 'auto'
            )}
          </div>
        {/if}
      </div>

      <!-- Focus -->
      <div>
        {@render subSection('Focus', focusOpen, () => focusOpen = !focusOpen)}
        {#if focusOpen}
          <div class="flex flex-col gap-1 pl-1">
            {@render modeToggle('Focus', settings.focus_mode, (manual) => settings.focus_mode = manual ? 'manual' : 'auto')}
            {@render sliderRow(
              'Distance',
              settings.focus_distance,
              (v) => settings.focus_distance = v,
              0, 1, 0.01,
              settings.focus_distance.toFixed(2),
              settings.focus_mode === 'auto'
            )}
          </div>
        {/if}
      </div>

      <!-- Zoom & Lens -->
      <div>
        {@render subSection('Zoom & Lens', lensOpen, () => lensOpen = !lensOpen)}
        {#if lensOpen}
          <div class="flex flex-col gap-1 pl-1">
            <!-- Camera Position Toggle -->
            <div class="flex items-center justify-between">
              <span class="text-[10px] text-muted-foreground">Camera</span>
              <div class="flex items-center gap-1">
                <span class="text-[9px] text-muted-foreground">Back</span>
                <button
                  onclick={() => settings.camera_position = isBackCamera ? 'front' : 'back'}
                  class="w-6 h-3 rounded-full relative transition-colors {!isBackCamera ? 'bg-primary' : 'bg-border'}"
                  aria-label="Toggle camera position"
                >
                  <span class="absolute top-0.5 h-2 w-2 rounded-full bg-white transition-transform {!isBackCamera ? 'left-3.5' : 'left-0.5'}"></span>
                </button>
                <span class="text-[9px] text-muted-foreground">Front</span>
              </div>
            </div>

            {#if isBackCamera}
              <!-- Lens presets -->
              <div class="flex items-center gap-1">
                <label class="text-[10px] text-muted-foreground w-14 shrink-0">Lens</label>
                <div class="flex gap-0.5 flex-1">
                  {#each [{ id: 'ultra_wide', label: 'UW' }, { id: 'wide', label: 'W' }, { id: 'telephoto', label: 'T' }] as lens}
                    <button
                      onclick={() => handleLensChange(lens.id as LensType)}
                      class="flex-1 h-5 text-[10px] font-medium rounded-sm transition-colors
                        {selectedLens === lens.id ? 'bg-primary text-primary-foreground' : 'bg-secondary text-secondary-foreground hover:bg-accent'}"
                    >{lens.label}</button>
                  {/each}
                </div>
              </div>
            {/if}

            {@render sliderRow(
              'Zoom',
              settings.zoom_factor,
              (v) => settings.zoom_factor = v,
              0.5, 15, 0.1,
              `${settings.zoom_factor.toFixed(1)}x`,
              false
            )}
          </div>
        {/if}
      </div>

      <!-- NDI Tally Torch -->
      <div>
        {@render subSection('Tally Torch', torchOpen, () => torchOpen = !torchOpen)}
        {#if torchOpen}
          <div class="flex flex-col gap-1 pl-1">
            {@render modeToggle('Torch', settings.torch_mode, (manual) => settings.torch_mode = manual ? 'manual' : 'auto')}
            {@render sliderRow(
              'Level',
              settings.torch_level,
              (v) => settings.torch_level = v,
              0.01, 1, 0.01,
              `${(settings.torch_level * 100).toFixed(0)}%`,
              settings.torch_mode === 'auto'
            )}
          </div>
        {/if}
      </div>

    </div>
  {:else if open && !isOnline}
    <div class="px-2 pb-2">
      <span class="text-[10px] text-muted-foreground italic">Camera offline</span>
    </div>
  {/if}
</div>
