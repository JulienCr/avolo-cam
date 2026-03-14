<script lang="ts">
  let {
    label,
    value = $bindable(),
    min,
    max,
    step,
    unit = '',
    disabled = false,
    gradient = '',
    display = '',
    labelWidth = 'w-14',
  }: {
    label: string;
    value: number;
    min: number;
    max: number;
    step: number;
    unit?: string;
    disabled?: boolean;
    gradient?: string;
    display?: string;
    labelWidth?: string;
  } = $props();

  let displayValue = $derived(display || `${value}${unit}`);
  let ratio = $derived((value - min) / (max - min));
  let fillPos = $derived(`calc(7px + (100% - 14px) * ${ratio})`);
  let trackBg = $derived(
    gradient
      ? gradient
      : `linear-gradient(to right, hsl(var(--primary)) ${fillPos}, hsl(var(--secondary)) ${fillPos})`
  );
</script>

<div class="flex items-center gap-1.5 {disabled ? 'opacity-40 pointer-events-none' : ''}">
  <label class="text-[10px] text-muted-foreground {labelWidth} shrink-0">{label}</label>
  <input
    type="range"
    {min} {max} {step}
    bind:value
    {disabled}
    class="flex-1 h-3"
    style="background: {trackBg}"
  />
  <span class="text-[10px] text-foreground w-12 text-right tabular-nums shrink-0">{displayValue}</span>
</div>
