<script lang="ts">
  import { onMount } from 'svelte';
  import NoteSelector from '../molecules/NoteSelector.svelte';
  import * as api from '$lib/utils/api';
  import {
    midiInputDevices,
    midiOutputDevices,
    selectedMidiInput,
    selectedMidiOutput,
    midiInputConnected,
    midiOutputConnected,
    loadingMidiDevices,
    midiNoteConfig,
    loadMidiDevices,
    connectMidiInput,
    connectMidiOutput,
    disconnectMidiInput,
    disconnectMidiOutput,
    loadMidiConnectionStatus,
    loadMidiNotesConfig,
    updateMidiNoteConfig,
  } from '$lib/stores/midi';

  let selectedInputId = $state('');
  let selectedOutputId = $state('');
  let inputError = $state('');
  let outputError = $state('');
  let focusToggleNote = $state(60);
  let noteConfigError = $state('');
  let isLearningFocusToggle = $state(false);

  onMount(async () => {
    await loadMidiConnectionStatus();
    await loadMidiNotesConfig();
    focusToggleNote = $midiNoteConfig.focusToggleNote;
    try {
      await loadMidiDevices();
      if ($selectedMidiInput) {
        const inputDevice = $midiInputDevices.find((d: any) => d.name === $selectedMidiInput);
        if (inputDevice) selectedInputId = inputDevice.name;
      }
      if ($selectedMidiOutput) {
        const outputDevice = $midiOutputDevices.find((d: any) => d.name === $selectedMidiOutput);
        if (outputDevice) selectedOutputId = outputDevice.name;
      }
    } catch (error) {
      console.error('Failed to load MIDI devices:', error);
    }
  });

  async function handleConnectInput() {
    if (!selectedInputId) { inputError = 'Select a device'; return; }
    try { inputError = ''; await connectMidiInput(selectedInputId); } catch (e) { inputError = String(e); }
  }

  async function handleDisconnectInput() {
    try { inputError = ''; await disconnectMidiInput(); } catch (e) { inputError = String(e); }
  }

  async function handleConnectOutput() {
    if (!selectedOutputId) { outputError = 'Select a device'; return; }
    try { outputError = ''; await connectMidiOutput(selectedOutputId); } catch (e) { outputError = String(e); }
  }

  async function handleDisconnectOutput() {
    try { outputError = ''; await disconnectMidiOutput(); } catch (e) { outputError = String(e); }
  }

  async function handleRefreshDevices() {
    try { await loadMidiDevices(); } catch (e) { console.error('Failed:', e); }
  }

  async function handleNoteChange(newNote: number) {
    try {
      noteConfigError = '';
      await updateMidiNoteConfig({ focusToggleNote: newNote });
      focusToggleNote = newNote;
    } catch (e) { noteConfigError = String(e); }
  }

  async function handleStartLearnFocusToggle() {
    if (!$midiInputConnected) { noteConfigError = 'Connect MIDI input first'; return; }
    try {
      noteConfigError = '';
      isLearningFocusToggle = true;
      const learnedNote = await api.startMidiLearnMode();
      await updateMidiNoteConfig({ focusToggleNote: learnedNote });
      focusToggleNote = learnedNote;
    } catch (e) { noteConfigError = String(e); } finally { isLearningFocusToggle = false; }
  }
</script>

<div class="flex flex-col gap-3">
  <div class="flex items-center justify-between">
    <span class="text-[11px] font-semibold text-foreground">MIDI Settings</span>
    <button onclick={handleRefreshDevices} disabled={$loadingMidiDevices}
      class="h-5 px-1.5 text-[9px] font-medium rounded-sm bg-secondary text-secondary-foreground hover:bg-accent disabled:opacity-40">
      {$loadingMidiDevices ? 'Refreshing...' : 'Refresh'}
    </button>
  </div>

  <!-- Input -->
  <div class="flex flex-col gap-1">
    <div class="flex items-center justify-between">
      <span class="text-[10px] font-medium text-foreground">Input (Controls)</span>
      <span class="text-[9px] {$midiInputConnected ? 'text-green-400' : 'text-muted-foreground'}">
        {$midiInputConnected ? 'Connected' : 'Disconnected'}
      </span>
    </div>
    <select bind:value={selectedInputId} disabled={$midiInputConnected || $loadingMidiDevices}
      class="h-5 text-[10px] px-1 rounded-sm bg-input border border-border text-foreground disabled:opacity-40">
      <option value="">Select device...</option>
      {#each $midiInputDevices as device}
        <option value={device.name}>{device.name}</option>
      {/each}
    </select>
    {#if inputError}<span class="text-[9px] text-red-400">{inputError}</span>{/if}
    <div class="flex gap-1">
      {#if $midiInputConnected}
        <button onclick={handleDisconnectInput} class="h-5 px-1.5 text-[9px] rounded-sm bg-secondary text-secondary-foreground hover:bg-accent">Disconnect</button>
      {:else}
        <button onclick={handleConnectInput} disabled={!selectedInputId} class="h-5 px-1.5 text-[9px] rounded-sm bg-primary text-primary-foreground hover:opacity-90 disabled:opacity-40">Connect</button>
      {/if}
    </div>
  </div>

  <!-- Output -->
  <div class="flex flex-col gap-1">
    <div class="flex items-center justify-between">
      <span class="text-[10px] font-medium text-foreground">Output (Fader Feedback)</span>
      <span class="text-[9px] {$midiOutputConnected ? 'text-green-400' : 'text-muted-foreground'}">
        {$midiOutputConnected ? 'Connected' : 'Disconnected'}
      </span>
    </div>
    <select bind:value={selectedOutputId} disabled={$midiOutputConnected || $loadingMidiDevices}
      class="h-5 text-[10px] px-1 rounded-sm bg-input border border-border text-foreground disabled:opacity-40">
      <option value="">Select device...</option>
      {#each $midiOutputDevices as device}
        <option value={device.name}>{device.name}</option>
      {/each}
    </select>
    {#if outputError}<span class="text-[9px] text-red-400">{outputError}</span>{/if}
    <div class="flex gap-1">
      {#if $midiOutputConnected}
        <button onclick={handleDisconnectOutput} class="h-5 px-1.5 text-[9px] rounded-sm bg-secondary text-secondary-foreground hover:bg-accent">Disconnect</button>
      {:else}
        <button onclick={handleConnectOutput} disabled={!selectedOutputId} class="h-5 px-1.5 text-[9px] rounded-sm bg-primary text-primary-foreground hover:opacity-90 disabled:opacity-40">Connect</button>
      {/if}
    </div>
  </div>

  <!-- Note Mapping -->
  <div class="border-t border-border pt-2 flex flex-col gap-1">
    <span class="text-[10px] font-medium text-foreground">Note Mapping</span>
    <div class="flex items-center justify-between">
      <span class="text-[10px] text-muted-foreground">Focus Toggle</span>
      <NoteSelector
        bind:value={focusToggleNote}
        onchange={handleNoteChange}
        onstartLearn={handleStartLearnFocusToggle}
        learning={isLearningFocusToggle}
      />
    </div>
    {#if noteConfigError}<span class="text-[9px] text-red-400">{noteConfigError}</span>{/if}
    {#if isLearningFocusToggle}
      <span class="text-[9px] text-blue-400">Press any MIDI key...</span>
    {/if}
  </div>
</div>
