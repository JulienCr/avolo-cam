<script lang="ts">
  let { label, value, warn = false }: { label: string; value: string; warn?: boolean } = $props();
</script>

<span class="inline-flex items-center gap-1 min-w-0">
  <span class="text-[9px] uppercase tracking-wider text-muted-foreground">{label}</span>
  <span class="text-[10px] font-medium tabular-nums {warn ? 'text-orange-400' : 'text-foreground'}">
    {value}
  </span>
</span>
