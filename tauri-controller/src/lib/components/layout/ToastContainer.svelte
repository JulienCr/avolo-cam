<script lang="ts">
  import { toasts } from '$lib/stores/toast';
</script>

{#if $toasts.length > 0}
  <div class="fixed bottom-3 right-3 z-[100] flex flex-col gap-1.5 pointer-events-none">
    {#each $toasts as t (t.id)}
      <div
        class="pointer-events-auto px-3 py-1.5 rounded-sm text-[11px] font-medium shadow-lg border animate-in fade-in slide-in-from-bottom-2 duration-200
          {t.type === 'success' ? 'bg-emerald-900/90 text-emerald-300 border-emerald-700/50' :
           t.type === 'error' ? 'bg-red-900/90 text-red-300 border-red-700/50' :
           'bg-card/95 text-foreground border-border'}"
      >
        {t.message}
      </div>
    {/each}
  </div>
{/if}
