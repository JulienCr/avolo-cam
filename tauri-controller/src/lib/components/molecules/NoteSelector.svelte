<script lang="ts">
  import { createEventDispatcher } from 'svelte';

  export let value: number = 60; // MIDI note number (0-127)
  export let disabled: boolean = false;
  export let learning: boolean = false; // Learning mode active

  const dispatch = createEventDispatcher<{ 
    change: number;
    startLearn: void;
  }>();

  // MIDI note names mapping
  const NOTE_NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

  /**
   * Convert MIDI note number to musical name (e.g., 60 -> "C3")
   */
  function noteNumberToName(noteNum: number): string {
    if (noteNum < 0 || noteNum > 127) {
      return 'Invalid';
    }
    const octave = Math.floor(noteNum / 12) - 1;
    const noteName = NOTE_NAMES[noteNum % 12];
    return `${noteName}${octave}`;
  }

  function handleInput(event: Event) {
    const target = event.target as HTMLInputElement;
    const newValue = parseInt(target.value, 10);
    
    // Validate range
    if (!isNaN(newValue) && newValue >= 0 && newValue <= 127) {
      value = newValue;
      dispatch('change', value);
    }
  }

  function handleBlur(event: Event) {
    const target = event.target as HTMLInputElement;
    const newValue = parseInt(target.value, 10);
    
    // Clamp to valid range if out of bounds
    if (isNaN(newValue) || newValue < 0) {
      value = 0;
    } else if (newValue > 127) {
      value = 127;
    }
    
    // Update input display
    target.value = value.toString();
    dispatch('change', value);
  }

  function handleLearnClick() {
    dispatch('startLearn');
  }

  $: noteName = noteNumberToName(value);
</script>

<div class="flex items-center gap-2">
  <input
    type="number"
    min="0"
    max="127"
    {value}
    disabled={disabled || learning}
    on:input={handleInput}
    on:blur={handleBlur}
    class="w-20 rounded-md border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 disabled:cursor-not-allowed disabled:bg-gray-50 disabled:text-gray-500 dark:border-gray-600 dark:bg-gray-800 dark:text-white dark:focus:border-blue-400 dark:focus:ring-blue-400"
  />
  <span class="min-w-[3rem] rounded-md bg-gray-100 px-3 py-2 text-sm font-medium text-gray-700 dark:bg-gray-700 dark:text-gray-300">
    {noteName}
  </span>
  <button
    type="button"
    on:click={handleLearnClick}
    disabled={disabled || learning}
    class="rounded-md px-3 py-2 text-sm font-medium transition-colors
      {learning 
        ? 'bg-blue-600 text-white animate-pulse cursor-wait' 
        : 'bg-blue-500 text-white hover:bg-blue-600 active:bg-blue-700 disabled:cursor-not-allowed disabled:bg-gray-300 disabled:text-gray-500 dark:disabled:bg-gray-700'
      }"
    title="Click to learn from next MIDI note"
  >
    {learning ? 'Listening...' : 'Learn'}
  </button>
  <span class="text-xs text-gray-500 dark:text-gray-400">
    (0-127)
  </span>
</div>

