<script lang="ts">
  export let title: string;
  export let showDivider = true;
</script>

<div class="mb-2.5">
  <h3 class="text-sm font-semibold text-gray-700">{title}</h3>
  {#if showDivider}
    <div class="mt-1.5 h-px bg-gradient-to-r from-transparent via-gray-300 to-transparent" />
  {/if}
</div>
