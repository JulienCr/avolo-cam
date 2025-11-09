<script lang="ts">
  import type { LensType } from "$lib/types/camera";

  export let selected: LensType;
  export let disabled = false;

  interface LensOption {
    value: LensType;
    label: string;
    sublabel: string;
  }

  const options: LensOption[] = [
    { value: "ultra_wide", label: "Ultra Wide", sublabel: "0.5×" },
    { value: "wide", label: "Wide", sublabel: "1×" },
    { value: "telephoto", label: "Telephoto", sublabel: "5×" },
  ];

  import { createEventDispatcher } from "svelte";
  const dispatch = createEventDispatcher();

  function handleSelect(value: LensType) {
    if (!disabled) {
      dispatch("change", value);
    }
  }
</script>

<div
  class="grid grid-cols-3 gap-1.5"
  role="radiogroup"
  aria-label="Lens selection"
>
  {#each options as option (option.value)}
    <button
      type="button"
      role="radio"
      aria-checked={selected === option.value}
      {disabled}
      class="flex flex-col items-center gap-0.5 rounded-md border-2 px-1.5 py-1 transition-all duration-200 focus:outline-none focus:ring-2 focus:ring-primary-500 focus:ring-offset-1 disabled:cursor-not-allowed disabled:opacity-40 {selected ===
      option.value
        ? 'border-primary-500 bg-primary-50'
        : 'border-gray-300 bg-white hover:border-gray-400 hover:bg-gray-50'}"
      on:click={() => handleSelect(option.value)}
    >
      <span
        class="text-[10px] font-medium leading-tight text-center {selected ===
        option.value
          ? 'text-primary-700'
          : 'text-gray-700'}"
      >
        {option.label}
        <br />
        <span
          class="text-[10px] {selected === option.value
            ? 'text-primary-600'
            : 'text-gray-500'}">{option.sublabel}</span
        >
      </span>
    </button>
  {/each}
</div>
