<script lang="ts">
  let {
    value = $bindable(60),
    disabled = false,
    learning = false,
    onchange,
    onstartLearn,
  }: {
    value: number;
    disabled?: boolean;
    learning?: boolean;
    onchange?: (note: number) => void;
    onstartLearn?: () => void;
  } = $props();

  const NOTE_NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

  function noteNumberToName(noteNum: number): string {
    if (noteNum < 0 || noteNum > 127) return 'Invalid';
    const octave = Math.floor(noteNum / 12) - 1;
    return `${NOTE_NAMES[noteNum % 12]}${octave}`;
  }

  function handleInput(event: Event) {
    const target = event.target as HTMLInputElement;
    const newValue = parseInt(target.value, 10);
    if (!isNaN(newValue) && newValue >= 0 && newValue <= 127) {
      value = newValue;
      onchange?.(value);
    }
  }

  let noteName = $derived(noteNumberToName(value));
</script>

<div class="flex items-center gap-1.5">
  <input
    type="number"
    min="0"
    max="127"
    {value}
    disabled={disabled || learning}
    oninput={handleInput}
    class="w-12 h-5 px-1 text-[10px] bg-input border border-border rounded-sm text-foreground disabled:opacity-40"
  />
  <span class="text-[10px] font-mono text-muted-foreground w-8">{noteName}</span>
  <button
    type="button"
    onclick={onstartLearn}
    disabled={disabled || learning}
    class="h-5 px-1.5 text-[9px] font-medium rounded-sm transition-colors
      {learning
        ? 'bg-primary text-primary-foreground animate-pulse'
        : 'bg-secondary text-secondary-foreground hover:bg-accent disabled:opacity-40'}"
  >{learning ? 'Listen...' : 'Learn'}</button>
</div>
