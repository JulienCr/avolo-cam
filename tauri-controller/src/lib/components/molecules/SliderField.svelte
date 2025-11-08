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
  export let showToggle: boolean = true;
  export let trackGradient: string = '';

  $: isAuto = autoMode === 'auto';
  $: isDisabled = disabled || isAuto;
  $: displayValue = isAuto ? 'Auto' : `${value}${unit}`;

  const {
    elements: { root, range, thumbs },
    states: { value: sliderValue },
    options: { disabled: sliderDisabled },
  } = createSlider({
    defaultValue: [value],
    min,
    max,
    step,
    onValueChange: ({ next }) => {
      value = next[0];
      return next;
    },
  });

  // Sync external prop changes to internal store
  $: if (value !== $sliderValue[0]) {
    sliderValue.set([value]);
  }

  // Sync disabled state
  $: sliderDisabled.set(isDisabled);

  function handleModeToggle(event: CustomEvent<boolean>) {
    const isManual = event.detail;
    autoMode = isManual ? 'manual' : 'auto';
  }
</script>

<div class="flex flex-col gap-1.5">
  <!-- Header -->
  <div class="flex items-center justify-between">
    <span class="text-sm font-medium text-gray-700 dark:text-gray-300">{label}</span>
    <div class="flex items-center gap-2">
      <span class="min-w-[60px] text-right text-sm font-semibold tabular-nums text-primary-600 dark:text-primary-400">
        {displayValue}
      </span>
      {#if showToggle}
        <Toggle checked={!isAuto} {disabled} label="Toggle manual mode" on:change={handleModeToggle} />
      {/if}
    </div>
  </div>

  <!-- Slider -->
  <div class="transition-opacity duration-200 {isDisabled ? 'opacity-40 pointer-events-none' : ''}">
    <div use:melt={$root} class="relative flex h-4 w-full items-center">
      <!-- Track -->
      <span
        class="relative block h-1 w-full overflow-hidden rounded-full"
        style={trackGradient ? `background: ${trackGradient}` : ''}
        class:bg-gray-200={!trackGradient}
        class:dark:bg-gray-700={!trackGradient}
      >
        <!-- Range (only show if no gradient) -->
        {#if !trackGradient}
          <span use:melt={$range} class="absolute inset-y-0 left-0 rounded-full bg-primary-500 dark:bg-primary-400" />
        {/if}
      </span>

      <!-- Thumb -->
      <span
        use:melt={$thumbs[0]}
        class="absolute block h-3.5 w-3.5 rounded-full border-2 border-primary-500 bg-white shadow-sm transition-all hover:scale-110 focus:outline-none focus:ring-2 focus:ring-primary-400 focus:ring-offset-1 active:scale-105 disabled:cursor-not-allowed dark:border-primary-400 dark:bg-gray-900"
      />
    </div>

    <!-- Min/Max Labels -->
    <div class="mt-1 flex justify-between px-0.5">
      <span class="text-xs text-gray-500 dark:text-gray-400">{minLabel}</span>
      <span class="text-xs text-gray-500 dark:text-gray-400">{maxLabel}</span>
    </div>
  </div>
</div>
