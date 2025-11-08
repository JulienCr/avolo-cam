<script lang="ts">
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

  function handleModeToggle() {
    autoMode = isAuto ? 'manual' : 'auto';
  }
</script>

<div class="flex flex-col gap-2">
  <!-- Header -->
  <div class="flex items-center justify-between">
    <span class="text-sm font-medium text-gray-700">{label}</span>
    <div class="flex items-center gap-3">
      <span class="text-sm font-semibold text-primary-600 min-w-[60px] text-right">
        {displayValue}
      </span>
      <Toggle checked={!isAuto} {disabled} label="Toggle manual mode" on:click={handleModeToggle} />
    </div>
  </div>

  <!-- Slider Container -->
  <div class="transition-opacity duration-300 {isDisabled ? 'opacity-40 pointer-events-none' : ''}">
    <div class="relative flex h-8 w-full items-center">
      <div class="h-2 w-full rounded-full bg-gray-200">
        <div class="h-full rounded-full bg-gradient-to-r from-gray-200 via-primary-500 to-gray-200" />
      </div>

      <input
        type="range"
        bind:value
        {min}
        {max}
        {step}
        disabled={isDisabled}
        class="slider-input"
        aria-label={label}
      />
    </div>

    <!-- Min/Max Labels -->
    <div class="flex justify-between mt-1">
      <span class="text-xs text-gray-500">{minLabel}</span>
      <span class="text-xs text-gray-500">{maxLabel}</span>
    </div>
  </div>
</div>

<style>
  .slider-input {
    position: absolute;
    width: 100%;
    height: 2rem;
    top: 50%;
    transform: translateY(-50%);
    appearance: none;
    background: transparent;
    outline: none;
    cursor: pointer;
  }

  .slider-input::-webkit-slider-thumb {
    appearance: none;
    width: 1.25rem;
    height: 1.25rem;
    border-radius: 50%;
    background: white;
    border: 3px solid #667eea;
    box-shadow: 0 2px 4px rgba(0, 0, 0, 0.15);
    cursor: pointer;
    transition: all 0.2s;
  }

  .slider-input::-webkit-slider-thumb:hover {
    transform: scale(1.1);
    box-shadow: 0 3px 6px rgba(0, 0, 0, 0.2);
  }

  .slider-input::-webkit-slider-thumb:active {
    transform: scale(1.15);
  }

  .slider-input::-moz-range-thumb {
    width: 1.25rem;
    height: 1.25rem;
    border-radius: 50%;
    background: white;
    border: 3px solid #667eea;
    box-shadow: 0 2px 4px rgba(0, 0, 0, 0.15);
    cursor: pointer;
    transition: all 0.2s;
  }

  .slider-input::-moz-range-thumb:hover {
    transform: scale(1.1);
    box-shadow: 0 3px 6px rgba(0, 0, 0, 0.2);
  }

  .slider-input:disabled {
    cursor: not-allowed;
  }
</style>
