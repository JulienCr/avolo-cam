<script lang="ts">
  import Modal from './Modal.svelte';
  import StreamSettingsPanel from './StreamSettingsPanel.svelte';
  import CameraSettingsPanel from './CameraSettingsPanel.svelte';
  import Button from '../atoms/Button.svelte';
  import type { StreamSettings, CameraSettings } from '$lib/types/settings';

  export let open = false;
  export let cameraId: string | null;
  export let streamSettings: StreamSettings;
  export let cameraSettings: CameraSettings;
  export let onMeasureWB: () => Promise<void>;
  export let measuring = false;
  export let saving = false;
</script>

<Modal bind:open title="Camera Settings" size="xl">
  <div class="flex flex-col gap-6">
    {#if saving}
      <div class="text-sm font-medium text-green-600">
        ● Saving...
      </div>
    {/if}

    <!-- Stream Settings -->
    <StreamSettingsPanel bind:settings={streamSettings} />

    <!-- Camera Settings -->
    <CameraSettingsPanel
      bind:settings={cameraSettings}
      {onMeasureWB}
      {measuring}
    />

    <!-- Close Button -->
    <div class="flex justify-end">
      <Button variant="secondary" size="md" on:click={() => (open = false)}>
        Close
      </Button>
    </div>
  </div>
</Modal>
