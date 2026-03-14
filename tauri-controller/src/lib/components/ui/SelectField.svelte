<script lang="ts">
  let {
    label,
    options,
    value = $bindable(),
    disabled = false,
  }: {
    label: string;
    options: { value: any; label: string }[];
    value: any;
    disabled?: boolean;
  } = $props();
</script>

<div class="flex items-center gap-1">
  <label class="text-[10px] text-muted-foreground w-12 shrink-0">{label}</label>
  <select
    bind:value
    {disabled}
    class="flex-1 h-5 text-[10px] px-1 rounded-sm bg-input border border-border text-foreground disabled:opacity-40"
  >
    {#each options as opt}
      <option value={opt.value}>{opt.label}</option>
    {/each}
  </select>
</div>
