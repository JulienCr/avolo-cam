<script lang="ts">
  export let checked = false;
  export let disabled = false;
  export let label = '';

  const classes =
    'h-5 w-5 rounded border-2 border-gray-300 text-primary-500 transition-colors duration-200 focus:ring-2 focus:ring-primary-500 focus:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-40';
</script>

<input
  type="checkbox"
  bind:checked
  {disabled}
  aria-label={label}
  class={classes}
  on:change
/>
