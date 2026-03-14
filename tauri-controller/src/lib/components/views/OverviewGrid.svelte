<script lang="ts">
  import type { Camera } from '$lib/types/camera';
  import CameraCard from './CameraCard.svelte';
  import { showAddDialog } from '$lib/stores/ui';
  import { discoverCamerasAction } from '$lib/stores/cameras';

  let {
    cameras,
    onRemoveCamera,
    onAliasUpdated,
  }: {
    cameras: Camera[];
    onRemoveCamera: (cameraId: string) => void;
    onAliasUpdated: (cameraId: string, alias: string) => void;
  } = $props();
</script>

{#if cameras.length === 0}
  <div class="flex-1 flex flex-col items-center justify-center gap-2 h-full">
    <span class="text-xs text-muted-foreground">No cameras found</span>
    <span class="text-[10px] text-muted-foreground">Add a camera or discover on the network</span>
    <div class="flex gap-1 mt-2">
      <button
        onclick={() => discoverCamerasAction()}
        class="h-6 px-3 text-[10px] font-medium rounded-sm bg-secondary text-secondary-foreground hover:bg-accent transition-colors"
      >Discover</button>
      <button
        onclick={() => $showAddDialog = true}
        class="h-6 px-3 text-[10px] font-medium rounded-sm bg-primary text-primary-foreground hover:opacity-90 transition-opacity"
      >+ Add</button>
    </div>
  </div>
{:else}
  <div class="grid gap-3" style="grid-template-columns: repeat(auto-fill, minmax(320px, 1fr));">
    {#each cameras as camera (camera.id)}
      <CameraCard
        {camera}
        onRemove={() => onRemoveCamera(camera.id)}
        onAliasUpdated={(alias) => onAliasUpdated(camera.id, alias)}
      />
    {/each}
  </div>
{/if}
