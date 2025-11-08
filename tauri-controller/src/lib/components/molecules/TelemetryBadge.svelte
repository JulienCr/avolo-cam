<script lang="ts">
  export let label: string;
  export let value: string | number;
  export let variant: 'default' | 'success' | 'warning' | 'danger' = 'default';

  const variantClasses = {
    default: 'text-gray-900',
    success: 'text-green-600',
    warning: 'text-yellow-600',
    danger: 'text-red-600',
  };
</script>

<div class="flex flex-col gap-0.5">
  <span class="text-xs text-gray-500 uppercase tracking-wide">{label}</span>
  <strong class="text-lg font-mono leading-tight {variantClasses[variant]}">
    {value}
  </strong>
</div>
