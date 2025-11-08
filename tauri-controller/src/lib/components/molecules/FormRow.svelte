<script lang="ts">
  export let label: string;
  export let help: string | undefined = undefined;
  export let error: string | undefined = undefined;
  export let layout: 'horizontal' | 'vertical' = 'vertical';
  export let required = false;
</script>

<div
  class="form-row {layout === 'horizontal'
    ? 'md:flex md:items-center md:gap-4'
    : 'flex flex-col gap-1.5'}"
>
  {#if label}
    <label class="text-sm font-medium text-gray-700 {layout === 'horizontal' ? 'md:w-40 md:flex-shrink-0' : ''}">
      {label}
      {#if required}
        <span class="text-red-500">*</span>
      {/if}
      {#if help}
        <span class="block text-xs font-normal text-gray-500">{help}</span>
      {/if}
    </label>
  {/if}

  <div class="flex-1">
    <slot />
    {#if error}
      <p class="mt-1 text-xs text-red-600">{error}</p>
    {/if}
  </div>
</div>
