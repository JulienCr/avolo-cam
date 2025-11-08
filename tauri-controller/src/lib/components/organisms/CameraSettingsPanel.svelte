<script lang="ts">
  import SectionHeader from '../molecules/SectionHeader.svelte';
  import SliderField from '../molecules/SliderField.svelte';
  import FormRow from '../molecules/FormRow.svelte';
  import Select from '../atoms/Select.svelte';
  import PresetRadio from '../molecules/PresetRadio.svelte';
  import Button from '../atoms/Button.svelte';
  import { formatShutterSpeed } from '$lib/utils/format';
  import type { CameraSettings } from '$lib/types/settings';
  import type { LensType } from '$lib/types/camera';
  import { getLensFromZoom, getZoomFromLens } from '$lib/stores/settings';

  export let settings: CameraSettings;
  export let onMeasureWB: () => Promise<void>;
  export let measuring = false;

  // Derived lens selection
  $: selectedLens = getLensFromZoom(settings.zoom_factor);

  function handleLensChange(lens: LensType) {
    settings.zoom_factor = getZoomFromLens(lens);
  }
</script>

<div class="flex flex-col gap-6">
  <!-- White Balance -->
  <div>
    <SectionHeader title="White Balance" />
    <div class="flex flex-col gap-4">
      <SliderField
        label="Temperature"
        bind:value={settings.wb_kelvin}
        bind:autoMode={settings.wb_mode}
        min={2000}
        max={10000}
        step={100}
        unit="K"
        minLabel="2000K"
        maxLabel="10000K"
      />

      <SliderField
        label="Tint"
        bind:value={settings.wb_tint}
        bind:autoMode={settings.wb_mode}
        min={-100}
        max={100}
        step={1}
        unit=""
        minLabel="Green"
        maxLabel="Magenta"
      />

      {#if settings.wb_mode === 'manual'}
        <Button variant="primary" on:click={onMeasureWB} disabled={measuring} size="md">
          {measuring ? '⏳ Measuring...' : '📸 Auto Calibrate'}
        </Button>
      {/if}
    </div>
  </div>

  <!-- Exposure -->
  <div>
    <SectionHeader title="Exposure" />
    <div class="flex flex-col gap-4">
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
    <div class="flex flex-col gap-4">
      <FormRow label="Camera Position" layout="vertical">
        <Select bind:value={settings.camera_position}>
          <option value="back">Back Camera</option>
          <option value="front">Front Camera</option>
        </Select>
      </FormRow>

      <FormRow label="Lens Selection" layout="vertical">
        <PresetRadio
          selected={selectedLens}
          on:change={(e) => handleLensChange(e.detail)}
        />
      </FormRow>
    </div>
  </div>
</div>
