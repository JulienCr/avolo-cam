<script lang="ts">
  export let type: 'text' | 'number' | 'password' = 'text';
  export let value: string | number = '';
  export let placeholder = '';
  export let disabled = false;
  export let required = false;
  export let min: number | undefined = undefined;
  export let max: number | undefined = undefined;
  export let step: number | undefined = undefined;

  const classes =
    'w-full px-3 py-2 border border-gray-300 rounded-lg text-base text-gray-900 bg-white placeholder-gray-400 transition-all duration-200 focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-transparent disabled:bg-gray-100 disabled:cursor-not-allowed';
</script>

{#if type === 'text'}
  <input
    type="text"
    bind:value
    {placeholder}
    {disabled}
    {required}
    class={classes}
    on:input
    on:change
    on:blur
    on:focus
  />
{:else if type === 'number'}
  <input
    type="number"
    bind:value
    {placeholder}
    {disabled}
    {required}
    {min}
    {max}
    {step}
    class={classes}
    on:input
    on:change
    on:blur
    on:focus
  />
{:else if type === 'password'}
  <input
    type="password"
    bind:value
    {placeholder}
    {disabled}
    {required}
    class={classes}
    on:input
    on:change
    on:blur
    on:focus
  />
{/if}
