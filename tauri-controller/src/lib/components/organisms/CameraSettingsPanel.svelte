<script lang="ts">
  import SectionHeader from '../molecules/SectionHeader.svelte';
  import SliderField from '../molecules/SliderField.svelte';
  import FormRow from '../molecules/FormRow.svelte';
  import Toggle from '../atoms/Toggle.svelte';
  import PresetRadio from '../molecules/PresetRadio.svelte';
  import Button from '../atoms/Button.svelte';
  import { formatShutterSpeed } from '$lib/utils/format';
  import type { CameraSettings } from '$lib/types/settings';
  import type { LensType } from '$lib/types/camera';
  import { getLensFromZoom, getZoomFromLens } from '$lib/stores/settings';

  export let settings: CameraSettings;
  export let onMeasureWB: () => Promise<void>;
  export let measuring = false;

  // Derived states
  $: selectedLens = getLensFromZoom(settings.zoom_factor);
  $: isBackCamera = settings.camera_position === 'back';

  function handleLensChange(lens: LensType) {
    settings.lens = lens;
    settings.zoom_factor = getZoomFromLens(lens);
  }

  function handleCameraToggle(event: CustomEvent<boolean>) {
    const isFront = event.detail;
    settings.camera_position = isFront ? 'front' : 'back';
  }

  function handleWBModeToggle(event: CustomEvent<boolean>) {
    const isManual = event.detail;
    settings.wb_mode = isManual ? 'manual' : 'auto';
  }
</script>

<div class="flex flex-col gap-4">
  <!-- White Balance -->
  <div>
    <div class="mb-2.5">
      <div class="flex items-center justify-between">
        <h3 class="text-sm font-semibold text-gray-700">White Balance</h3>
        <div class="flex items-center gap-2">
          <span class="text-xs text-gray-600">Auto</span>
          <Toggle
            checked={settings.wb_mode === 'manual'}
            label="Toggle white balance mode"
            on:change={handleWBModeToggle}
          />
          <span class="text-xs text-gray-600">Manual</span>
        </div>
      </div>
      <div class="mt-1.5 h-px bg-gradient-to-r from-transparent via-gray-300 to-transparent" />
    </div>

    <div class="flex flex-col gap-3">
      <SliderField
        label="Temperature"
        bind:value={settings.wb_kelvin}
        autoMode={settings.wb_mode}
        min={2000}
        max={10000}
        step={100}
        unit="K"
        minLabel="2000K"
        maxLabel="10000K"
        showToggle={false}
        trackGradient="linear-gradient(to right, var(--k-2000) 0%, var(--k-3000) 20%, var(--k-4000) 35%, var(--k-5500) 50%, var(--k-6500) 65%, var(--k-8000) 82%, var(--k-10000) 100%)"
      />

      <SliderField
        label="Tint"
        bind:value={settings.wb_tint}
        autoMode={settings.wb_mode}
        min={-100}
        max={100}
        step={1}
        unit=""
        minLabel="Green"
        maxLabel="Magenta"
        showToggle={false}
        trackGradient="linear-gradient(to right, var(--t-green) 0%, var(--t-green-soft) 35%, var(--t-neutral) 50%, var(--t-magenta-soft) 65%, var(--t-magenta) 100%)"
      />

      {#if settings.wb_mode === 'manual'}
        <Button variant="primary" on:click={onMeasureWB} disabled={measuring} size="sm">
          {measuring ? '⏳ Measuring...' : '📸 Auto Calibrate'}
        </Button>
      {/if}
    </div>
  </div>

  <!-- Exposure -->
  <div>
    <SectionHeader title="Exposure" />
    <div class="flex flex-col gap-3">
      <SliderField
        label="ISO"
        bind:value={settings.iso}
        bind:autoMode={settings.iso_mode}
        min={50}
        max={3200}
        step={50}
        unit=""
        minLabel="50"
        maxLabel="3200"
      />

      <SliderField
        label="Shutter Speed"
        bind:value={settings.shutter_s}
        bind:autoMode={settings.shutter_mode}
        min={0.001}
        max={0.1}
        step={0.001}
        unit=""
        minLabel="1/1000"
        maxLabel="1/10"
      />
    </div>
  </div>

  <!-- Camera & Lens -->
  <div>
    <SectionHeader title="Camera & Lens" />

    <!-- Camera Position Toggle -->
    <div class="flex items-center justify-between mb-3">
      <span class="text-sm font-medium text-gray-700 dark:text-gray-300">Camera Position</span>
      <div class="flex items-center gap-2">
        <span class="text-sm text-gray-600 dark:text-gray-400">Back</span>
        <Toggle
          checked={!isBackCamera}
          label="Toggle camera position"
          on:change={handleCameraToggle}
        />
        <span class="text-sm text-gray-600 dark:text-gray-400">Front</span>
      </div>
    </div>

    <!-- Lens Selection (only for back camera) -->
    {#if isBackCamera}
      <FormRow label="Lens Selection" layout="vertical">
        <PresetRadio
          selected={selectedLens}
          on:change={(e) => handleLensChange(e.detail)}
        />
      </FormRow>
    {/if}
  </div>

  <!-- NDI Tally Torch -->
  <div>
    <SectionHeader title="NDI Tally Torch" />
    <div class="flex flex-col gap-3">
      <SliderField
        label="Torch Brightness"
        bind:value={settings.torch_level}
        min={0.01}
        max={1.0}
        step={0.01}
        unit=""
        minLabel="Dim"
        maxLabel="Bright"
        showToggle={false}
      />
      <p class="text-xs text-gray-500 dark:text-gray-400">
        Torch turns ON at this level when camera is on program (NDI tally). Lower values reduce glare and heat.
      </p>
    </div>
  </div>
</div>
