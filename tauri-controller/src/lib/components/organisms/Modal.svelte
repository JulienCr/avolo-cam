<script lang="ts">
  import { createDialog, melt } from '@melt-ui/svelte';
  import { fade, scale } from 'svelte/transition';

  export let open = false;
  export let title: string;
  export let size: 'sm' | 'md' | 'lg' | 'xl' = 'md';

  const {
    elements: { portalled, overlay, content, title: dialogTitle, close },
    states: { open: dialogOpen },
  } = createDialog({
    onOpenChange: ({ next }) => {
      console.log('[Modal] onOpenChange:', { next, title });
      open = next;
      return next;
    },
  });

  // Sync external prop changes to internal store
  $: {
    console.log('[Modal] Prop changed:', { open, dialogOpen: $dialogOpen, title });
    if (open !== $dialogOpen) {
      dialogOpen.set(open);
    }
  }

  const sizeClasses = {
    sm: 'max-w-md',
    md: 'max-w-lg',
    lg: 'max-w-2xl',
    xl: 'max-w-4xl',
  };
</script>

{#if $dialogOpen}
  <div use:melt={$portalled}>
    <div use:melt={$overlay} transition:fade={{ duration: 150 }} class="fixed inset-0 z-40 bg-black/50" />

    <div
      use:melt={$content}
      transition:scale={{ duration: 200, start: 0.95 }}
      class="fixed left-1/2 top-1/2 z-50 w-[90vw] {sizeClasses[size]} -translate-x-1/2 -translate-y-1/2 rounded-xl bg-white p-6 shadow-dialog"
    >
      <div class="mb-4 flex items-center justify-between">
        <h2 use:melt={$dialogTitle} class="text-xl font-semibold text-gray-900">
          {title}
        </h2>
        <button
          use:melt={$close}
          class="inline-flex h-8 w-8 items-center justify-center rounded-lg text-gray-400 transition-colors hover:bg-gray-100 hover:text-gray-600 focus:outline-none focus:ring-2 focus:ring-primary-500"
        >
          ✕
        </button>
      </div>

      <slot />
    </div>
  </div>
{/if}
