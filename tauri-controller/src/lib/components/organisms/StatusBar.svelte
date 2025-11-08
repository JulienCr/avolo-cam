<script lang="ts">
  import Button from '../atoms/Button.svelte';

  export let onAddCamera: () => void;
  export let onProfiles: () => void;
  export let onRefresh: () => void;
</script>

<header class="mb-6 flex flex-wrap items-center justify-between gap-4">
  <h1 class="text-3xl font-bold text-gray-900">
    🎥 AvoCam Controller
  </h1>

  <div class="flex gap-2">
    <Button variant="secondary" size="md" on:click={onAddCamera}>
      + Add Camera
    </Button>
    <Button variant="secondary" size="md" on:click={onProfiles}>
      📋 Profiles
    </Button>
    <Button variant="secondary" size="md" on:click={onRefresh}>
      🔄 Refresh
    </Button>
  </div>
</header>
