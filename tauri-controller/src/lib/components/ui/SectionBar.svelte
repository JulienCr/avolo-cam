<script lang="ts">
  let {
    label,
    open = $bindable(true),
    icon = '',
  }: {
    label: string;
    open: boolean;
    icon?: string;
  } = $props();
</script>

<button
  onclick={() => open = !open}
  class="w-full flex items-center justify-between py-0.5 text-[10px] font-medium text-muted-foreground hover:text-foreground transition-colors"
>
  <span class="flex items-center gap-1">
    {#if icon}<span class="text-[10px]">{icon}</span>{/if}
    {label}
  </span>
  <svg class="h-2.5 w-2.5 transition-transform {open ? 'rotate-180' : ''}" fill="none" stroke="currentColor" viewBox="0 0 24 24">
    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
  </svg>
</button>
