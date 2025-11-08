<script lang="ts">
  export let padding: 'none' | 'sm' | 'md' | 'lg' = 'md';
  export let interactive = false;

  const paddingClasses = {
    none: '',
    sm: 'p-3',
    md: 'p-5',
    lg: 'p-6',
  };

  const baseClasses = 'bg-white rounded-lg shadow-card border border-gray-100';
  const interactiveClasses = interactive
    ? 'transition-shadow duration-200 hover:shadow-card-hover'
    : '';

  $: classes = `${baseClasses} ${paddingClasses[padding]} ${interactiveClasses}`;
</script>

<div class={classes}>
  <slot />
</div>
