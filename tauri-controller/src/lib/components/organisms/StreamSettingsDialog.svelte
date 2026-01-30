<script lang="ts">
  import Modal from './Modal.svelte';
  import Button from '../atoms/Button.svelte';
  import FormRow from '../molecules/FormRow.svelte';
  import Select from '../atoms/Select.svelte';
  import type { StreamSettings } from '$lib/types/settings';
  import type { Writable } from 'svelte/store';

  export let open: Writable<boolean>;
  export let settings: StreamSettings;
  export let onApply: (() => void) | undefined = undefined;

  const resolutionOptions = [
    { value: '1280x720', label: '1280×720 (720p)' },
    { value: '1920x1080', label: '1920×1080 (1080p)' },
    { value: '2560x1440', label: '2560×1440 (1440p)' },
    { value: '3840x2160', label: '3840×2160 (4K)' },
  ];

  const framerateOptions = [
    { value: 24, label: '24 fps' },
    { value: 25, label: '25 fps' },
    { value: 30, label: '30 fps' },
    { value: 60, label: '60 fps' },
  ];

  const bitrateOptions = [
    { value: 5000000, label: '5 Mbps' },
    { value: 8000000, label: '8 Mbps' },
    { value: 10000000, label: '10 Mbps' },
    { value: 15000000, label: '15 Mbps' },
    { value: 20000000, label: '20 Mbps' },
    { value: 30000000, label: '30 Mbps' },
    { value: 50000000, label: '50 Mbps' },
  ];

  const codecOptions = [
    { value: 'h264', label: 'H.264' },
    { value: 'hevc', label: 'H.265/HEVC' },
  ];

  const streamingModeOptions = [
    { value: 'ndi', label: 'NDI (Low Latency ~20ms)' },
    { value: 'srt', label: 'SRT (Low CPU ~100ms)' },
  ];

  // Initialize streaming mode if not set
  $: if (!settings.streaming_mode) {
    settings.streaming_mode = 'ndi';
  }

  // Initialize SRT settings with defaults if not set
  $: if (settings.streaming_mode === 'srt') {
    if (!settings.srt_port) {
      settings.srt_port = 9000;
    }
    if (!settings.srt_latency) {
      settings.srt_latency = 120;
    }
  }
</script>

<Modal {open} title="Stream Settings" size="md">
  <div class="flex flex-col gap-5">
    <!-- Streaming Mode -->
    <div class="grid gap-4">
      <FormRow label="Streaming Mode" layout="vertical">
        <Select bind:value={settings.streaming_mode}>
          {#each streamingModeOptions as option}
            <option value={option.value}>{option.label}</option>
          {/each}
        </Select>
      </FormRow>
    </div>

    <!-- Stream Parameters -->
    <div class="grid gap-4 sm:grid-cols-2">
      <FormRow label="Resolution" layout="vertical">
        <Select bind:value={settings.resolution}>
          {#each resolutionOptions as option}
            <option value={option.value}>{option.label}</option>
          {/each}
        </Select>
      </FormRow>

      <FormRow label="Framerate" layout="vertical">
        <Select bind:value={settings.framerate}>
          {#each framerateOptions as option}
            <option value={option.value}>{option.label}</option>
          {/each}
        </Select>
      </FormRow>

      <FormRow label="Bitrate" layout="vertical">
        <Select bind:value={settings.bitrate}>
          {#each bitrateOptions as option}
            <option value={option.value}>{option.label}</option>
          {/each}
        </Select>
      </FormRow>

      <FormRow label="Codec" layout="vertical">
        <Select bind:value={settings.codec}>
          {#each codecOptions as option}
            <option value={option.value}>{option.label}</option>
          {/each}
        </Select>
      </FormRow>
    </div>

    <!-- SRT-specific settings -->
    {#if settings.streaming_mode === 'srt'}
      <div class="grid gap-4 sm:grid-cols-2 rounded-lg border border-blue-200 bg-blue-50 p-4 dark:border-blue-700 dark:bg-blue-900/20">
        <FormRow label="SRT Port" layout="vertical">
          <input
            type="number"
            bind:value={settings.srt_port}
            min="1024"
            max="65535"
            readonly
            class="w-full px-3 py-2 border border-gray-300 rounded-lg text-base text-gray-700 bg-gray-100 cursor-not-allowed dark:bg-gray-800 dark:text-gray-300 dark:border-gray-600"
          />
          <span class="mt-1 text-xs text-gray-600 dark:text-gray-400">Auto-assigned based on camera alias</span>
        </FormRow>

        <FormRow label="SRT Latency (ms)" layout="vertical">
          <input
            type="number"
            bind:value={settings.srt_latency}
            min="20"
            max="8000"
            step="10"
            class="w-full px-3 py-2 border border-gray-300 rounded-lg text-base text-gray-900 bg-white transition-all duration-200 focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-transparent dark:bg-gray-800 dark:text-gray-100 dark:border-gray-600"
          />
          <span class="mt-1 text-xs text-gray-600 dark:text-gray-400">Recommended: 120-200ms for reliable streaming</span>
        </FormRow>
      </div>
    {/if}

    <div class="flex justify-end gap-2 border-t border-gray-200 pt-4 dark:border-gray-700">
      <Button variant="secondary" size="md" on:click={() => open.set(false)}>
        Close
      </Button>
      <Button variant="primary" size="md" on:click={() => {
        if (onApply) onApply();
        open.set(false);
      }}>
        Apply
      </Button>
    </div>
  </div>
</Modal>
