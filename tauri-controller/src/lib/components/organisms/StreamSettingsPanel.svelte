<script lang="ts">
  import FormRow from '../molecules/FormRow.svelte';
  import Select from '../atoms/Select.svelte';
  import Slider from '../atoms/Slider.svelte';
  import SectionHeader from '../molecules/SectionHeader.svelte';
  import type { StreamSettings } from '$lib/types/settings';
  import type { StreamingMode } from '$lib/types/camera';

  export let settings: StreamSettings;

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
    { value: 'ndi', label: 'NDI (Low Latency)' },
    { value: 'srt', label: 'SRT (Low CPU)' },
    { value: 'flash', label: 'Flash (Ultra Low-Latency)' },
  ];

  const flashJitterModeOptions = [
    { value: 'ultra_low', label: 'Ultra-Low (0-8ms buffer)' },
    { value: 'stable', label: 'Stable (16-50ms buffer)' },
  ];

  // Reactive computed values for display
  $: gopLatencyMs = settings.srt_gop_size && settings.framerate
    ? Math.round((settings.srt_gop_size / settings.framerate) * 1000)
    : 0;
</script>

<div class="rounded-lg bg-gray-50 p-4">
  <SectionHeader title="Stream Settings" showDivider={false} />

  <div class="grid gap-4 md:grid-cols-2">
    <FormRow label="Streaming Mode" layout="vertical">
      <Select bind:value={settings.streaming_mode}>
        {#each streamingModeOptions as option}
          <option value={option.value}>{option.label}</option>
        {/each}
      </Select>
    </FormRow>

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

  {#if settings.streaming_mode === 'srt'}
    <div class="mt-4 border-t border-gray-200 pt-4">
      <SectionHeader title="SRT Advanced Settings" showDivider={false} />

      <div class="grid gap-4 md:grid-cols-2">
        <FormRow label="SRT Port" layout="vertical">
          <div class="text-sm text-gray-600">{settings.srt_port ?? 9000}</div>
        </FormRow>

        <FormRow label="SRT Latency: {settings.srt_latency ?? 80}ms" layout="vertical">
          <Slider
            bind:value={settings.srt_latency}
            min={20}
            max={500}
            step={10}
          />
          <div class="mt-1 text-xs text-gray-500">
            Lower = less delay, more sensitive to network jitter
          </div>
        </FormRow>

        <FormRow label="GOP Size: {settings.srt_gop_size ?? 3} frames (~{gopLatencyMs}ms)" layout="vertical">
          <Slider
            bind:value={settings.srt_gop_size}
            min={2}
            max={30}
            step={1}
          />
          <div class="mt-1 text-xs text-gray-500">
            Lower = less latency, more bandwidth usage
          </div>
        </FormRow>
      </div>
    </div>
  {/if}

  {#if settings.streaming_mode === 'flash'}
    <div class="mt-4 border-t border-gray-200 pt-4">
      <SectionHeader title="Flash Advanced Settings" showDivider={false} />

      <div class="grid gap-4 md:grid-cols-2">
        <FormRow label="Destination Host" layout="vertical">
          <input
            type="text"
            bind:value={settings.flash_destination_host}
            placeholder="e.g., 192.168.1.100"
            class="w-full rounded border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
          />
          <div class="mt-1 text-xs text-gray-500">
            IP address of the receiving computer running OBS
          </div>
        </FormRow>

        <FormRow label="Destination Port" layout="vertical">
          <div class="text-sm text-gray-600">{settings.flash_destination_port ?? 5000}</div>
        </FormRow>

        <FormRow label="Jitter Buffer Mode" layout="vertical">
          <Select bind:value={settings.flash_jitter_mode}>
            {#each flashJitterModeOptions as option}
              <option value={option.value}>{option.label}</option>
            {/each}
          </Select>
          <div class="mt-1 text-xs text-gray-500">
            Ultra-low for stable networks, Stable for WiFi
          </div>
        </FormRow>

        <FormRow label="GOP Size: {settings.srt_gop_size ?? 25} frames" layout="vertical">
          <Slider
            bind:value={settings.srt_gop_size}
            min={1}
            max={60}
            step={1}
          />
          <div class="mt-1 text-xs text-gray-500">
            Lower = faster resync, higher bandwidth
          </div>
        </FormRow>
      </div>
    </div>
  {/if}
</div>
