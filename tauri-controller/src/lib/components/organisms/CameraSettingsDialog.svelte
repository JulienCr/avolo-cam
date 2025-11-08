<script lang="ts">
  import Modal from './Modal.svelte';
  import CameraSettingsPanel from './CameraSettingsPanel.svelte';
  import Button from '../atoms/Button.svelte';
  import type { CameraSettings } from '$lib/types/settings';

  export let open = false;
  export let cameraSettings: CameraSettings;
  export let onMeasureWB: () => Promise<void>;
  export let measuring = false;
  export let saving = false;
</script>

<Modal bind:open title="Camera Settings" size="lg">
  <div class="flex flex-col gap-5">
    {#if saving}
      <div class="flex items-center gap-2 text-sm font-medium text-green-600 dark:text-green-400">
        <svg class="h-4 w-4 animate-spin" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
          <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
          <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
        </svg>
        Saving changes...
      </div>
    {/if}

    <CameraSettingsPanel
      bind:settings={cameraSettings}
      {onMeasureWB}
      {measuring}
    />

    <div class="flex justify-end border-t border-gray-200 pt-4 dark:border-gray-700">
      <Button variant="secondary" size="md" on:click={() => (open = false)}>
        Close
      </Button>
    </div>
  </div>
</Modal>
