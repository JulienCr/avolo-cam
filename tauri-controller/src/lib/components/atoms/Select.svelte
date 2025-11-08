<script lang="ts">
  export let value: string | number;
  export let disabled = false;

  const classes =
    'w-full px-3 py-2 border border-gray-300 rounded-lg text-base text-gray-900 bg-white cursor-pointer transition-all duration-200 focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-transparent disabled:bg-gray-100 disabled:cursor-not-allowed';
</script>

<select bind:value {disabled} class={classes} on:change>
  <slot />
</select>
