<script lang="ts">
  export let variant: 'primary' | 'secondary' | 'danger' | 'ghost' = 'secondary';
  export let size: 'sm' | 'md' | 'lg' = 'md';
  export let disabled = false;
  export let type: 'button' | 'submit' = 'button';

  const baseClasses =
    'inline-flex items-center justify-center gap-2 rounded-lg font-medium transition-all duration-150 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-500 focus-visible:ring-offset-2 active:scale-[0.97] disabled:opacity-50 disabled:cursor-not-allowed disabled:active:scale-100 dark:focus-visible:ring-offset-gray-800';

  const variantClasses = {
    primary:
      'bg-primary-500 text-white hover:bg-primary-600 shadow-sm hover:shadow dark:bg-primary-600 dark:hover:bg-primary-700',
    secondary:
      'bg-white text-gray-700 border border-gray-300 hover:bg-gray-50 shadow-sm hover:shadow dark:bg-gray-800 dark:text-gray-200 dark:border-gray-600 dark:hover:bg-gray-700',
    danger:
      'bg-red-500 text-white hover:bg-red-600 shadow-sm hover:shadow dark:bg-red-600 dark:hover:bg-red-700',
    ghost: 'text-gray-700 hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-700',
  };

  const sizeClasses = {
    sm: 'px-2.5 py-1.5 text-sm',
    md: 'px-3.5 py-2 text-sm',
    lg: 'px-5 py-2.5 text-base',
  };

  $: classes = `${baseClasses} ${variantClasses[variant]} ${sizeClasses[size]}`;
</script>

<button {type} {disabled} class={classes} on:click>
  <slot />
</button>
