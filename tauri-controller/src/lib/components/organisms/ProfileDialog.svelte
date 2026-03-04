<script lang="ts">
  import type { Profile } from '$lib/types/profile';
  import type { Writable } from 'svelte/store';
  import { toastError } from '$lib/stores/toast';

  let {
    open,
    profiles,
    onSave,
    onApply,
    onDelete,
    canSave = false,
  }: {
    open: Writable<boolean>;
    profiles: Profile[];
    onSave: (name: string) => Promise<void>;
    onApply: (profileName: string) => Promise<void>;
    onDelete: (profileName: string) => Promise<void>;
    canSave: boolean;
  } = $props();

  let profileName = $state('');
  let saving = $state(false);

  async function handleSave() {
    if (!profileName.trim()) return;
    try {
      saving = true;
      await onSave(profileName.trim());
      profileName = '';
    } catch (e) {
      toastError(`Failed to save profile: ${e}`);
    } finally {
      saving = false;
    }
  }

  async function handleApply(name: string) {
    try { await onApply(name); } catch (e) { toastError(String(e)); }
  }

  async function handleDelete(name: string) {
    if (!confirm(`Delete profile "${name}"?`)) return;
    try { await onDelete(name); } catch (e) { toastError(`Failed: ${e}`); }
  }
</script>

{#if $open}
  <!-- svelte-ignore a11y_click_events_have_key_events -->
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/60" onclick={() => open.set(false)}>
    <div class="w-96 max-h-[80vh] bg-card border border-border rounded-sm p-4 shadow-lg flex flex-col" onclick={(e) => e.stopPropagation()}>
      <div class="flex items-center justify-between mb-3">
        <h2 class="text-xs font-semibold text-foreground">Profiles</h2>
        <button onclick={() => open.set(false)} class="text-muted-foreground hover:text-foreground text-sm">X</button>
      </div>

      {#if canSave}
        <div class="flex gap-1.5 mb-3">
          <input type="text" bind:value={profileName} placeholder="Profile name" disabled={saving}
            class="flex-1 h-6 px-1.5 text-[11px] bg-input border border-border rounded-sm text-foreground placeholder-muted-foreground" />
          <button onclick={handleSave} disabled={saving || !profileName.trim()}
            class="h-6 px-2 text-[10px] font-medium rounded-sm bg-primary text-primary-foreground hover:opacity-90 disabled:opacity-40">
            {saving ? 'Saving...' : 'Save'}
          </button>
        </div>
      {/if}

      <div class="flex-1 overflow-y-auto">
        <span class="text-[10px] text-muted-foreground mb-1 block">Saved ({profiles.length})</span>
        {#if profiles.length === 0}
          <p class="text-[10px] text-muted-foreground italic py-4 text-center">No profiles yet</p>
        {:else}
          <div class="flex flex-col gap-1">
            {#each profiles as profile (profile.name)}
              <div class="flex items-center justify-between gap-2 p-1.5 border border-border rounded-sm">
                <div class="min-w-0 flex-1">
                  <span class="text-[11px] font-medium text-foreground block truncate">{profile.name}</span>
                  <span class="text-[9px] text-muted-foreground">
                    WB: {profile.settings.wb_mode || 'auto'}
                    {#if profile.settings.wb_mode === 'manual' && profile.settings.wb_kelvin}
                      ({profile.settings.wb_kelvin}K)
                    {/if}
                    | ISO: {profile.settings.iso_mode || 'auto'}
                    | Lens: {profile.settings.lens || 'wide'}
                  </span>
                </div>
                <div class="flex gap-0.5 shrink-0">
                  <button onclick={() => handleApply(profile.name)}
                    class="h-5 px-1.5 text-[9px] font-medium rounded-sm bg-primary text-primary-foreground hover:opacity-90">Apply</button>
                  <button onclick={() => handleDelete(profile.name)}
                    class="h-5 px-1.5 text-[9px] font-medium rounded-sm bg-destructive text-destructive-foreground hover:opacity-90">Del</button>
                </div>
              </div>
            {/each}
          </div>
        {/if}
      </div>

      <div class="flex justify-end mt-3">
        <button onclick={() => open.set(false)}
          class="h-6 px-3 text-[10px] font-medium rounded-sm bg-secondary text-secondary-foreground hover:bg-accent transition-colors">
          Close
        </button>
      </div>
    </div>
  </div>
{/if}
