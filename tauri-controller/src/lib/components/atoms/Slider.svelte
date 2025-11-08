<script lang="ts">
  import { createSlider, melt } from '@melt-ui/svelte';

  export let value: number;
  export let min: number;
  export let max: number;
  export let step = 1;
  export let disabled = false;
  export let label = '';

  const {
    elements: { root, range, thumb, tick },
    states: { value: sliderValue },
  } = createSlider({
    value: [value],
    min,
    max,
    step,
    disabled,
  });

  // Sync internal value with external prop
  $: sliderValue.set([value]);
  $: value = $sliderValue[0];
</script>

<div class="flex flex-col gap-2">
  {#if label}
    <label class="text-sm font-medium text-gray-700">{label}</label>
  {/if}

  <div
    use:melt={$root}
    class="relative flex h-2 w-full touch-none select-none items-center"
  >
    <div class="h-2 w-full rounded-full bg-gray-200">
      <div
        use:melt={$range}
        class="h-full rounded-full bg-gradient-to-r from-gray-200 via-primary-500 to-gray-200"
      />
    </div>

    <div
      use:melt={$thumb()}
      class="block h-5 w-5 cursor-pointer rounded-full border-3 border-primary-500 bg-white shadow-md transition-all hover:scale-110 focus:outline-none focus:ring-2 focus:ring-primary-500 focus:ring-offset-2 active:scale-115 disabled:cursor-not-allowed disabled:opacity-40"
    />
  </div>
</div>
