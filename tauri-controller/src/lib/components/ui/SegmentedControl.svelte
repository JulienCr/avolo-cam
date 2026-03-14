<script lang="ts">
  let {
    options,
    value,
    onValueChange,
    disabled = false,
  }: {
    options: { value: string; label: string }[];
    value: string;
    onValueChange: (value: string) => void;
    disabled?: boolean;
  } = $props();
</script>

<div class="inline-flex rounded-sm border border-border overflow-hidden {disabled ? 'opacity-40 pointer-events-none' : ''}">
  {#each options as opt}
    <button
      onclick={() => onValueChange(opt.value)}
      class="h-5 px-2 text-[10px] font-medium transition-colors
        {value === opt.value ? 'bg-primary text-primary-foreground' : 'bg-secondary text-secondary-foreground hover:bg-accent'}"
      {disabled}
    >{opt.label}</button>
  {/each}
</div>
