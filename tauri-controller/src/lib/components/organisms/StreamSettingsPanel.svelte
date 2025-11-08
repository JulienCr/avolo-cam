<script lang="ts">
  import FormRow from '../molecules/FormRow.svelte';
  import Select from '../atoms/Select.svelte';
  import SectionHeader from '../molecules/SectionHeader.svelte';
  import type { StreamSettings } from '$lib/types/settings';

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
</script>

<div class="rounded-lg bg-gray-50 p-4">
  <SectionHeader title="Stream Settings" showDivider={false} />

  <div class="grid gap-4 md:grid-cols-2">
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
</div>
