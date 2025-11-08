<script lang="ts">
  export let title: string;
  export let showDivider = true;
</script>

<div class="mb-4">
  <h3 class="text-base font-semibold text-gray-700">{title}</h3>
  {#if showDivider}
    <div class="mt-2 h-px bg-gradient-to-r from-transparent via-gray-300 to-transparent" />
  {/if}
</div>
