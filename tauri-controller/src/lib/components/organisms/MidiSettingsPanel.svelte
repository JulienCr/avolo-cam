<script lang="ts">
  import { onMount } from 'svelte';
  import Card from '../atoms/Card.svelte';
  import Button from '../atoms/Button.svelte';
  import {
    midiInputDevices,
    midiOutputDevices,
    selectedMidiInput,
    selectedMidiOutput,
    midiInputConnected,
    midiOutputConnected,
    loadingMidiDevices,
    loadMidiDevices,
    connectMidiInput,
    connectMidiOutput,
    disconnectMidiInput,
    disconnectMidiOutput,
    loadMidiConnectionStatus,
  } from '$lib/stores/midi';

  let selectedInputId = '';
  let selectedOutputId = '';
  let inputError = '';
  let outputError = '';

  onMount(async () => {
    // Load connection status first
    await loadMidiConnectionStatus();
    
    // Load available devices
    try {
      await loadMidiDevices();
      
      // Set selected devices from loaded status
      if ($selectedMidiInput) {
        const inputDevice = $midiInputDevices.find(d => d.name === $selectedMidiInput);
        if (inputDevice) {
          selectedInputId = inputDevice.name;
        }
      }
      
      if ($selectedMidiOutput) {
        const outputDevice = $midiOutputDevices.find(d => d.name === $selectedMidiOutput);
        if (outputDevice) {
          selectedOutputId = outputDevice.name;
        }
      }
    } catch (error) {
      console.error('Failed to load MIDI devices:', error);
    }
  });

  async function handleConnectInput() {
    if (!selectedInputId) {
      inputError = 'Please select a MIDI input device';
      return;
    }

    try {
      inputError = '';
      await connectMidiInput(selectedInputId);
    } catch (error) {
      inputError = String(error);
    }
  }

  async function handleDisconnectInput() {
    try {
      inputError = '';
      await disconnectMidiInput();
    } catch (error) {
      inputError = String(error);
    }
  }

  async function handleConnectOutput() {
    if (!selectedOutputId) {
      outputError = 'Please select a MIDI output device';
      return;
    }

    try {
      outputError = '';
      await connectMidiOutput(selectedOutputId);
    } catch (error) {
      outputError = String(error);
    }
  }

  async function handleDisconnectOutput() {
    try {
      outputError = '';
      await disconnectMidiOutput();
    } catch (error) {
      outputError = String(error);
    }
  }

  async function handleRefreshDevices() {
    try {
      await loadMidiDevices();
    } catch (error) {
      console.error('Failed to refresh MIDI devices:', error);
    }
  }
</script>

<Card>
  <div class="space-y-6 p-4">
    <div class="flex items-center justify-between border-b border-gray-200 pb-3 dark:border-gray-700">
      <h2 class="text-lg font-semibold text-gray-900 dark:text-white">MIDI Settings</h2>
      <Button
        variant="secondary"
        size="sm"
        on:click={handleRefreshDevices}
        disabled={$loadingMidiDevices}
      >
        {$loadingMidiDevices ? 'Refreshing...' : 'Refresh Devices'}
      </Button>
    </div>

    <!-- Input Section -->
    <div class="space-y-3">
      <div class="flex items-center justify-between">
        <h3 class="font-medium text-gray-900 dark:text-white">MIDI Input (Controls)</h3>
        <div class="flex items-center gap-2">
          <span
            class="text-sm font-medium {$midiInputConnected
              ? 'text-green-600 dark:text-green-400'
              : 'text-gray-500 dark:text-gray-400'}"
          >
            {$midiInputConnected ? '● Connected' : '○ Disconnected'}
          </span>
        </div>
      </div>

      <div class="space-y-2">
        <select
          bind:value={selectedInputId}
          disabled={$midiInputConnected || $loadingMidiDevices}
          class="w-full rounded-md border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 disabled:cursor-not-allowed disabled:bg-gray-50 disabled:text-gray-500 dark:border-gray-600 dark:bg-gray-800 dark:text-white dark:focus:border-blue-400 dark:focus:ring-blue-400"
        >
          <option value="">Select MIDI Input Device...</option>
          {#each $midiInputDevices as device}
            <option value={device.name}>{device.name}</option>
          {/each}
        </select>

        {#if inputError}
          <p class="text-sm text-red-600 dark:text-red-400">{inputError}</p>
        {/if}

        <div class="flex gap-2">
          {#if $midiInputConnected}
            <Button variant="secondary" size="sm" on:click={handleDisconnectInput}>
              Disconnect
            </Button>
          {:else}
            <Button variant="primary" size="sm" on:click={handleConnectInput} disabled={!selectedInputId}>
              Connect
            </Button>
          {/if}
        </div>
      </div>
    </div>

    <!-- Output Section (Feedback) -->
    <div class="space-y-3">
      <div class="flex items-center justify-between">
        <h3 class="font-medium text-gray-900 dark:text-white">MIDI Output (Motorized Faders Feedback)</h3>
        <div class="flex items-center gap-2">
          <span
            class="text-sm font-medium {$midiOutputConnected
              ? 'text-green-600 dark:text-green-400'
              : 'text-gray-500 dark:text-gray-400'}"
          >
            {$midiOutputConnected ? '● Connected' : '○ Disconnected'}
          </span>
        </div>
      </div>

      <div class="space-y-2">
        <select
          bind:value={selectedOutputId}
          disabled={$midiOutputConnected || $loadingMidiDevices}
          class="w-full rounded-md border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 disabled:cursor-not-allowed disabled:bg-gray-50 disabled:text-gray-500 dark:border-gray-600 dark:bg-gray-800 dark:text-white dark:focus:border-blue-400 dark:focus:ring-blue-400"
        >
          <option value="">Select MIDI Output Device...</option>
          {#each $midiOutputDevices as device}
            <option value={device.name}>{device.name}</option>
          {/each}
        </select>

        {#if outputError}
          <p class="text-sm text-red-600 dark:text-red-400">{outputError}</p>
        {/if}

        <div class="flex gap-2">
          {#if $midiOutputConnected}
            <Button variant="secondary" size="sm" on:click={handleDisconnectOutput}>
              Disconnect
            </Button>
          {:else}
            <Button variant="primary" size="sm" on:click={handleConnectOutput} disabled={!selectedOutputId}>
              Connect
            </Button>
          {/if}
        </div>

        <p class="text-xs text-gray-500 dark:text-gray-400">
          Output sends zoom position feedback to motorized faders and LED status for manual mode
        </p>
      </div>
    </div>

    <!-- Info Section -->
    <div class="rounded-md bg-blue-50 p-3 dark:bg-blue-900/20">
      <p class="text-sm text-blue-800 dark:text-blue-300">
        <strong>MIDI Control:</strong> Assign MIDI channels to cameras in their settings. Use Note C3 (60) to toggle manual mode, and pitch bend to control zoom.
      </p>
    </div>
  </div>
</Card>


