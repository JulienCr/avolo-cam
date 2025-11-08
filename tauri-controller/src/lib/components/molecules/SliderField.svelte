<script lang="ts">
  import { createSlider, melt } from '@melt-ui/svelte';
  import Toggle from '../atoms/Toggle.svelte';

  export let label: string;
  export let value: number;
  export let min: number;
  export let max: number;
  export let step: number = 1;
  export let unit: string = '';
  export let autoMode: 'auto' | 'manual' = 'auto';
  export let minLabel: string = String(min);
  export let maxLabel: string = String(max);
  export let disabled: boolean = false;

  $: isAuto = autoMode === 'auto';
  $: isDisabled = disabled || isAuto;
  $: displayValue = isAuto ? 'Auto' : `${value}${unit}`;

  const {
    elements: { root, range, thumb },
    states: { value: sliderValue },
    options: { disabled: sliderDisabled },
  } = createSlider({
    min,
    max,
    step,
  });

  // Sync with parent
  $: sliderValue.set([value]);
  $: value = $sliderValue[0];
  $: sliderDisabled.set(isDisabled);

  function handleModeToggle() {
    autoMode = isAuto ? 'manual' : 'auto';
  }
</script>

<div class="flex flex-col gap-2.5">
  <!-- Header -->
  <div class="flex items-center justify-between">
    <span class="text-sm font-medium text-gray-700 dark:text-gray-300">{label}</span>
    <div class="flex items-center gap-3">
      <span class="min-w-[65px] text-right text-sm font-semibold tabular-nums text-primary-600 dark:text-primary-400">
        {displayValue}
      </span>
      <Toggle checked={!isAuto} {disabled} label="Toggle manual mode" on:click={handleModeToggle} />
    </div>
  </div>

  <!-- Slider -->
  <div class="transition-opacity duration-200 {isDisabled ? 'opacity-40 pointer-events-none' : ''}">
    <div use:melt={$root} class="relative flex h-5 w-full items-center">
      <!-- Track -->
      <span class="block h-1.5 w-full rounded-full bg-gray-200 dark:bg-gray-700">
        <!-- Range -->
        <span use:melt={$range} class="block h-full rounded-full bg-primary-500 dark:bg-primary-400" />
      </span>

      <!-- Thumb -->
      <span
        use:melt={$thumb()}
        class="block h-4 w-4 rounded-full border-2 border-primary-500 bg-white shadow-md transition-all hover:scale-110 focus:outline-none focus:ring-2 focus:ring-primary-500 focus:ring-offset-2 active:scale-105 disabled:cursor-not-allowed dark:border-primary-400 dark:bg-gray-900 dark:focus:ring-offset-gray-800"
      />
    </div>

    <!-- Min/Max Labels -->
    <div class="mt-1.5 flex justify-between px-0.5">
      <span class="text-xs text-gray-500 dark:text-gray-400">{minLabel}</span>
      <span class="text-xs text-gray-500 dark:text-gray-400">{maxLabel}</span>
    </div>
  </div>
</div>
