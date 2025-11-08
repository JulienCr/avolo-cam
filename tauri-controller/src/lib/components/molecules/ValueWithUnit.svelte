<script lang="ts">
  export let value: string | number;
  export let unit: string;
  export let variant: 'primary' | 'secondary' = 'primary';

  const variantClasses = {
    primary: 'text-primary-600 font-semibold',
    secondary: 'text-gray-700 font-medium',
  };
</script>

<span class="inline-flex items-baseline gap-1">
  <span class={variantClasses[variant]}>{value}</span>
  <span class="text-xs text-gray-500">{unit}</span>
</span>
