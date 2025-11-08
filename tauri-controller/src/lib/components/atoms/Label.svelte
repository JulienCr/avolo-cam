<script lang="ts">
  export let htmlFor: string | undefined = undefined;
  export let required = false;
  export let help: string | undefined = undefined;
</script>

<label for={htmlFor} class="block">
  <span class="text-sm font-medium text-gray-700">
    <slot />
    {#if required}
      <span class="text-red-500">*</span>
    {/if}
  </span>
  {#if help}
    <span class="mt-1 block text-xs text-gray-500">{help}</span>
  {/if}
</label>
