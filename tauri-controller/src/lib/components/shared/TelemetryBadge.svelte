<script lang="ts">
  let { label, value, warn = false }: { label: string; value: string; warn?: boolean } = $props();
</script>

<div class="flex flex-col gap-0.5 min-w-0">
  <span class="text-[9px] uppercase tracking-wider text-muted-foreground truncate">{label}</span>
  <span class="text-[11px] font-medium tabular-nums {warn ? 'text-orange-400' : 'text-foreground'} truncate">
    {value}
  </span>
</div>
