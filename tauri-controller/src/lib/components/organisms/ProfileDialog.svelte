<script lang="ts">
  import Modal from './Modal.svelte';
  import Button from '../atoms/Button.svelte';
  import Input from '../atoms/Input.svelte';
  import Card from '../atoms/Card.svelte';
  import type { Profile } from '$lib/types/profile';

  export let open = false;
  export let profiles: Profile[];
  export let onSave: (name: string) => Promise<void>;
  export let onApply: (profileName: string) => Promise<void>;
  export let onDelete: (profileName: string) => Promise<void>;
  export let canSave = false;

  let profileName = '';
  let saving = false;

  async function handleSave() {
    if (!profileName.trim()) {
      alert('Please enter a profile name');
      return;
    }

    try {
      saving = true;
      await onSave(profileName.trim());
      profileName = '';
    } catch (e) {
      alert(`Failed to save profile: ${e}`);
    } finally {
      saving = false;
    }
  }

  async function handleApply(name: string) {
    try {
      await onApply(name);
    } catch (e) {
      alert(String(e));
    }
  }

  async function handleDelete(name: string) {
    if (!confirm(`Delete profile "${name}"?`)) return;

    try {
      await onDelete(name);
    } catch (e) {
      alert(`Failed to delete profile: ${e}`);
    }
  }
</script>

<Modal bind:open title="Profile Management" size="lg">
  <div class="flex flex-col gap-6">
    <!-- Save Current Settings -->
    {#if canSave}
      <Card padding="md">
        <h3 class="mb-3 text-base font-semibold text-gray-700">Save Current Settings</h3>
        <div class="flex gap-2">
          <Input
            type="text"
            bind:value={profileName}
            placeholder="Profile name"
            disabled={saving}
          />
          <Button
            variant="primary"
            size="md"
            on:click={handleSave}
            disabled={saving || !profileName.trim()}
          >
            {saving ? 'Saving...' : 'Save'}
          </Button>
        </div>
      </Card>
    {/if}

    <!-- Saved Profiles -->
    <div>
      <h3 class="mb-3 text-base font-semibold text-gray-700">
        Saved Profiles ({profiles.length})
      </h3>

      {#if profiles.length === 0}
        <p class="py-8 text-center italic text-gray-500">No profiles saved yet</p>
      {:else}
        <div class="flex flex-col gap-2">
          {#each profiles as profile (profile.name)}
            <Card padding="sm">
              <div class="flex items-center justify-between gap-4">
                <div class="flex-1">
                  <strong class="block text-sm text-gray-900">{profile.name}</strong>
                  <span class="text-xs text-gray-600">
                    WB: {profile.settings.wb_mode || 'auto'}
                    {#if profile.settings.wb_mode === 'manual' && profile.settings.wb_kelvin}
                      ({profile.settings.wb_kelvin}K)
                    {/if}
                    | ISO: {profile.settings.iso_mode || 'auto'}
                    {#if profile.settings.iso_mode === 'manual' && profile.settings.iso}
                      ({profile.settings.iso})
                    {/if}
                    | Lens: {profile.settings.lens || 'wide'}
                  </span>
                </div>

                <div class="flex gap-2">
                  <Button variant="primary" size="sm" on:click={() => handleApply(profile.name)}>
                    Apply
                  </Button>
                  <Button variant="danger" size="sm" on:click={() => handleDelete(profile.name)}>
                    Delete
                  </Button>
                </div>
              </div>
            </Card>
          {/each}
        </div>
      {/if}
    </div>

    <div class="flex justify-end">
      <Button variant="secondary" size="md" on:click={() => (open = false)}>
        Close
      </Button>
    </div>
  </div>
</Modal>
