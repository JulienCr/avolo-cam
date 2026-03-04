<script lang="ts">
  import type { Writable } from 'svelte/store';

  let {
    open,
    onAdd,
  }: {
    open: Writable<boolean>;
    onAdd: (ip: string, port: number, token: string) => Promise<void>;
  } = $props();

  let ip = $state('');
  let port = $state(8888);
  let token = $state('');
  let submitting = $state(false);

  async function handleSubmit(e: Event) {
    e.preventDefault();
    try {
      submitting = true;
      await onAdd(ip, port, token);
      ip = '';
      port = 8888;
      token = '';
      open.set(false);
    } catch (err) {
      alert(`Failed to add camera: ${err}`);
    } finally {
      submitting = false;
    }
  }
</script>

{#if $open}
  <!-- svelte-ignore a11y_click_events_have_key_events -->
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/60" onclick={() => open.set(false)}>
    <div class="w-80 bg-card border border-border rounded-sm p-4 shadow-lg" onclick={(e) => e.stopPropagation()}>
      <div class="flex items-center justify-between mb-3">
        <h2 class="text-xs font-semibold text-foreground">Add Camera</h2>
        <button onclick={() => open.set(false)} class="text-muted-foreground hover:text-foreground text-sm">X</button>
      </div>

      <form onsubmit={handleSubmit} class="flex flex-col gap-2">
        <div>
          <label class="text-[10px] text-muted-foreground block mb-0.5">IP Address</label>
          <input type="text" bind:value={ip} placeholder="192.168.1.100" required
            class="w-full h-6 px-1.5 text-[11px] bg-input border border-border rounded-sm text-foreground placeholder-muted-foreground" />
        </div>

        <div>
          <label class="text-[10px] text-muted-foreground block mb-0.5">Port</label>
          <input type="number" bind:value={port} min={1} max={65535} required
            class="w-full h-6 px-1.5 text-[11px] bg-input border border-border rounded-sm text-foreground" />
        </div>

        <div>
          <label class="text-[10px] text-muted-foreground block mb-0.5">Bearer Token</label>
          <input type="text" bind:value={token} placeholder="Token from iPhone" required
            class="w-full h-6 px-1.5 text-[11px] bg-input border border-border rounded-sm text-foreground placeholder-muted-foreground" />
        </div>

        <div class="flex gap-1.5 mt-2">
          <button type="submit" disabled={submitting}
            class="flex-1 h-6 text-[10px] font-medium rounded-sm bg-primary text-primary-foreground hover:opacity-90 disabled:opacity-40 transition-opacity">
            {submitting ? 'Adding...' : 'Add'}
          </button>
          <button type="button" onclick={() => open.set(false)}
            class="h-6 px-3 text-[10px] font-medium rounded-sm bg-secondary text-secondary-foreground hover:bg-accent transition-colors">
            Cancel
          </button>
        </div>
      </form>
    </div>
  </div>
{/if}
