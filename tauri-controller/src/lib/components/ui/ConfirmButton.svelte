<script lang="ts">
  import { onDestroy } from 'svelte';

  let {
    label,
    confirmLabel = 'Confirm?',
    onclick,
    variant = 'primary',
    disabled = false,
  }: {
    label: string;
    confirmLabel?: string;
    onclick: () => void;
    variant?: 'primary' | 'destructive';
    disabled?: boolean;
  } = $props();

  let confirming = $state(false);
  let timeout: ReturnType<typeof setTimeout> | null = null;

  function handleClick() {
    if (confirming) {
      confirming = false;
      if (timeout) clearTimeout(timeout);
      onclick();
    } else {
      confirming = true;
      timeout = setTimeout(() => { confirming = false; }, 3000);
    }
  }

  onDestroy(() => { if (timeout) clearTimeout(timeout); });

  const variantClasses = {
    primary: 'bg-primary text-primary-foreground',
    destructive: 'bg-destructive text-destructive-foreground',
  };
</script>

<button
  onclick={handleClick}
  {disabled}
  class="h-6 px-2 text-[10px] font-medium rounded-sm hover:opacity-90 disabled:opacity-40 transition-all
    {confirming ? 'bg-amber-600 text-white animate-pulse' : variantClasses[variant]}"
>
  {confirming ? confirmLabel : label}
</button>
