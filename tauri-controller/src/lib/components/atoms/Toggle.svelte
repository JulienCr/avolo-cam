<script lang="ts">
  import { createSwitch, melt } from '@melt-ui/svelte';
  import { createEventDispatcher } from 'svelte';

  export let checked = false;
  export let disabled = false;
  export let label = '';

  const dispatch = createEventDispatcher();

  const {
    elements: { root, input },
    states: { checked: switchChecked },
  } = createSwitch({
    defaultChecked: checked,
    disabled,
    onCheckedChange: ({ next }) => {
      checked = next;
      dispatch('change', next);
      return next;
    },
  });

  // Sync external prop changes to internal store
  $: if (checked !== $switchChecked) {
    switchChecked.set(checked);
  }
</script>

<button
  use:melt={$root}
  class="relative inline-flex h-5 w-9 flex-shrink-0 cursor-pointer items-center rounded-full transition-colors duration-200 focus:outline-none focus:ring-2 focus:ring-primary-500 focus:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-50 data-[state=checked]:bg-primary-500 data-[state=unchecked]:bg-gray-300"
  aria-label={label}
>
  <span
    class="inline-block h-4 w-4 transform rounded-full bg-white shadow-sm transition-transform duration-200 data-[state=checked]:translate-x-4 data-[state=unchecked]:translate-x-0.5"
    data-state={$switchChecked ? 'checked' : 'unchecked'}
  />
  <input use:melt={$input} />
</button>
