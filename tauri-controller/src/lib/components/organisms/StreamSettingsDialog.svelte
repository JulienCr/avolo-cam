<script lang="ts">
  import Modal from './Modal.svelte';
  import Button from '../atoms/Button.svelte';
  import FormRow from '../molecules/FormRow.svelte';
  import Select from '../atoms/Select.svelte';
  import type { StreamSettings } from '$lib/types/settings';
  import type { Writable } from 'svelte/store';
  import { detectedLocalIP } from '$lib/stores/settings';

  export let open: Writable<boolean>;
  export let settings: StreamSettings;
  export let onApply: (() => void) | undefined = undefined;
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  export let flashPort: number | undefined = undefined;

  let useSeparateLatencies = false;

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
    { value: 'flash', label: 'Flash (Ultra Low-Latency)' },
  ];

  const flashJitterModeOptions = [
    { value: 'ultra_low', label: 'Ultra-Low (0-8ms buffer)' },
    { value: 'stable', label: 'Stable (16-50ms buffer)' },
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
    if (settings.srt_latency === undefined) {
      settings.srt_latency = 120;
    }
    if (settings.srt_gop_size === undefined) {
      settings.srt_gop_size = settings.framerate || 25; // Default to 1 second
    }
    if (settings.srt_tlpktdrop === undefined) {
      settings.srt_tlpktdrop = true;
    }
  }

  // Initialize Flash settings with defaults if not set
  $: if (settings.streaming_mode === 'flash') {
    if (settings.flash_jitter_mode === undefined) {
      settings.flash_jitter_mode = 'stable';
    }
    if (settings.srt_gop_size === undefined) {
      settings.srt_gop_size = 25; // Smaller GOP for Flash
    }
  }

  // Initialize flash port with default if not set
  $: if (settings.streaming_mode === 'flash' && !settings.flash_destination_port) {
    settings.flash_destination_port = 5000;
  }

  // Check if separate latencies are being used
  $: useSeparateLatencies = settings.srt_rcv_latency !== undefined || settings.srt_peer_latency !== undefined;

  // Compute GOP latency in ms for display
  $: gopLatencyMs = settings.srt_gop_size && settings.framerate
    ? Math.round((settings.srt_gop_size / settings.framerate) * 1000)
    : 0;

  function toggleSeparateLatencies() {
    if (useSeparateLatencies) {
      // Turning off - clear separate values
      settings.srt_rcv_latency = undefined;
      settings.srt_peer_latency = undefined;
    } else {
      // Turning on - initialize with main latency value
      settings.srt_rcv_latency = settings.srt_latency;
      settings.srt_peer_latency = settings.srt_latency;
    }
    useSeparateLatencies = !useSeparateLatencies;
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
      <div class="rounded-lg border border-blue-200 bg-blue-50 p-4 dark:border-blue-700 dark:bg-blue-900/20">
        <h4 class="text-sm font-medium text-blue-900 dark:text-blue-100 mb-3">SRT Advanced Settings</h4>

        <div class="grid gap-4 sm:grid-cols-2">
          <FormRow label="SRT Port" layout="vertical">
            <input
              type="number"
              bind:value={settings.srt_port}
              min="1024"
              max="65535"
              readonly
              class="w-full px-3 py-2 border border-gray-300 rounded-lg text-base text-gray-700 bg-gray-100 cursor-not-allowed dark:bg-gray-800 dark:text-gray-300 dark:border-gray-600"
            />
            <span class="mt-1 text-xs text-gray-600 dark:text-gray-400">Auto-assigned</span>
          </FormRow>

          <FormRow label="GOP Size ({gopLatencyMs}ms)" layout="vertical">
            <input
              type="number"
              bind:value={settings.srt_gop_size}
              min="1"
              max="120"
              step="1"
              class="w-full px-3 py-2 border border-gray-300 rounded-lg text-base text-gray-900 bg-white transition-all duration-200 focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-transparent dark:bg-gray-800 dark:text-gray-100 dark:border-gray-600"
            />
            <span class="mt-1 text-xs text-gray-600 dark:text-gray-400">Recommended: {settings.framerate} (1 sec)</span>
          </FormRow>

          <FormRow label="Latency (ms)" layout="vertical">
            <input
              type="number"
              bind:value={settings.srt_latency}
              min="20"
              max="8000"
              step="10"
              class="w-full px-3 py-2 border border-gray-300 rounded-lg text-base text-gray-900 bg-white transition-all duration-200 focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-transparent dark:bg-gray-800 dark:text-gray-100 dark:border-gray-600"
            />
            <span class="mt-1 text-xs text-gray-600 dark:text-gray-400">General SRT latency</span>
          </FormRow>

          <FormRow label="Drop Late Packets" layout="vertical">
            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                bind:checked={settings.srt_tlpktdrop}
                class="w-4 h-4 text-primary-600 border-gray-300 rounded focus:ring-primary-500"
              />
              <span class="text-sm text-gray-700 dark:text-gray-300">tlpktdrop (essential for live)</span>
            </label>
          </FormRow>
        </div>

        <!-- Separate latencies toggle -->
        <div class="mt-4 pt-3 border-t border-blue-200 dark:border-blue-700">
          <label class="flex items-center gap-2 cursor-pointer mb-3">
            <input
              type="checkbox"
              checked={useSeparateLatencies}
              on:change={toggleSeparateLatencies}
              class="w-4 h-4 text-primary-600 border-gray-300 rounded focus:ring-primary-500"
            />
            <span class="text-sm text-gray-700 dark:text-gray-300">Use separate RCV/Peer latencies</span>
          </label>

          {#if useSeparateLatencies}
            <div class="grid gap-4 sm:grid-cols-2">
              <FormRow label="RCV Latency (ms)" layout="vertical">
                <input
                  type="number"
                  bind:value={settings.srt_rcv_latency}
                  min="20"
                  max="8000"
                  step="10"
                  class="w-full px-3 py-2 border border-gray-300 rounded-lg text-base text-gray-900 bg-white transition-all duration-200 focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-transparent dark:bg-gray-800 dark:text-gray-100 dark:border-gray-600"
                />
                <span class="mt-1 text-xs text-gray-600 dark:text-gray-400">Receive buffer latency</span>
              </FormRow>

              <FormRow label="Peer Latency (ms)" layout="vertical">
                <input
                  type="number"
                  bind:value={settings.srt_peer_latency}
                  min="20"
                  max="8000"
                  step="10"
                  class="w-full px-3 py-2 border border-gray-300 rounded-lg text-base text-gray-900 bg-white transition-all duration-200 focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-transparent dark:bg-gray-800 dark:text-gray-100 dark:border-gray-600"
                />
                <span class="mt-1 text-xs text-gray-600 dark:text-gray-400">Peer negotiation latency</span>
              </FormRow>
            </div>
          {/if}
        </div>
      </div>
    {/if}

    <!-- Flash-specific settings -->
    {#if settings.streaming_mode === 'flash'}
      <div class="rounded-lg border border-purple-200 bg-purple-50 p-4 dark:border-purple-700 dark:bg-purple-900/20">
        <h4 class="text-sm font-medium text-purple-900 dark:text-purple-100 mb-3">Flash Advanced Settings</h4>

        <div class="grid gap-4 sm:grid-cols-2">
          <FormRow label="Destination Host" layout="vertical">
            <input
              type="text"
              bind:value={settings.flash_destination_host}
              placeholder={$detectedLocalIP ?? 'e.g., 192.168.1.100'}
              class="w-full px-3 py-2 border border-gray-300 rounded-lg text-base text-gray-900 bg-white transition-all duration-200 focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-transparent dark:bg-gray-800 dark:text-gray-100 dark:border-gray-600"
            />
            <span class="mt-1 text-xs text-gray-600 dark:text-gray-400">
              {#if $detectedLocalIP}
                Leave empty to use detected IP ({$detectedLocalIP})
              {:else}
                IP address of the receiving computer
              {/if}
            </span>
          </FormRow>

          <FormRow label="Destination Port" layout="vertical">
            <input
              type="number"
              bind:value={settings.flash_destination_port}
              min="1024"
              max="65535"
              class="w-full px-3 py-2 border border-gray-300 rounded-lg text-base text-gray-900 bg-white transition-all duration-200 focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-transparent dark:bg-gray-800 dark:text-gray-100 dark:border-gray-600"
            />
            <span class="mt-1 text-xs text-gray-600 dark:text-gray-400">UDP port on the receiving computer (must match OBS source)</span>
          </FormRow>

          <FormRow label="Jitter Buffer Mode" layout="vertical">
            <select
              bind:value={settings.flash_jitter_mode}
              class="w-full px-3 py-2 border border-gray-300 rounded-lg text-base text-gray-900 bg-white transition-all duration-200 focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-transparent dark:bg-gray-800 dark:text-gray-100 dark:border-gray-600"
            >
              {#each flashJitterModeOptions as option}
                <option value={option.value}>{option.label}</option>
              {/each}
            </select>
            <span class="mt-1 text-xs text-gray-600 dark:text-gray-400">Ultra-low for stable networks, Stable for WiFi</span>
          </FormRow>

          <FormRow label="GOP Size" layout="vertical">
            <input
              type="number"
              bind:value={settings.srt_gop_size}
              min="1"
              max="60"
              step="1"
              class="w-full px-3 py-2 border border-gray-300 rounded-lg text-base text-gray-900 bg-white transition-all duration-200 focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-transparent dark:bg-gray-800 dark:text-gray-100 dark:border-gray-600"
            />
            <span class="mt-1 text-xs text-gray-600 dark:text-gray-400">Lower = faster resync, higher bandwidth</span>
          </FormRow>
        </div>
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
