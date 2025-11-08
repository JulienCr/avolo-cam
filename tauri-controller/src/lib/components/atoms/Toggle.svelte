<script lang="ts">
  export let checked = false;
  export let disabled = false;
  export let label = '';

  function handleToggle() {
    if (!disabled) {
      checked = !checked;
    }
  }
</script>

<button
  type="button"
  role="switch"
  aria-checked={checked}
  aria-label={label}
  {disabled}
  class="relative inline-flex h-6 w-11 flex-shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none focus:ring-2 focus:ring-primary-500 focus:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-40 {checked
    ? 'bg-primary-500'
    : 'bg-gray-300'}"
  on:click={handleToggle}
>
  <span
    aria-hidden="true"
    class="pointer-events-none inline-block h-5 w-5 transform rounded-full bg-white shadow-sm ring-0 transition duration-200 ease-in-out {checked
      ? 'translate-x-5'
      : 'translate-x-0'}"
  />
</button>

<style>
  button:active:not(:disabled) span {
    transform: scale(0.95);
  }
</style>
