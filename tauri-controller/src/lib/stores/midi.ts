import { writable } from 'svelte/store';
import type { MidiDevice } from '../types/camera';
import * as api from '../utils/api';

// MIDI Input devices
export const midiInputDevices = writable<MidiDevice[]>([]);
export const selectedMidiInput = writable<string | null>(null);
export const midiInputConnected = writable(false);

// MIDI Output devices
export const midiOutputDevices = writable<MidiDevice[]>([]);
export const selectedMidiOutput = writable<string | null>(null);
export const midiOutputConnected = writable(false);

// Loading state
export const loadingMidiDevices = writable(false);

/**
 * Load available MIDI input and output devices
 */
export async function loadMidiDevices() {
  loadingMidiDevices.set(true);
  try {
    const [inputs, outputs] = await Promise.all([
      api.listMidiInputDevices(),
      api.listMidiOutputDevices(),
    ]);

    midiInputDevices.set(inputs.map((name, i) => ({ id: i.toString(), name })));
    midiOutputDevices.set(outputs.map((name, i) => ({ id: i.toString(), name })));

    console.log(`Loaded ${inputs.length} MIDI input devices, ${outputs.length} output devices`);
  } catch (error) {
    console.error('Failed to load MIDI devices:', error);
    throw error;
  } finally {
    loadingMidiDevices.set(false);
  }
}

/**
 * Connect to MIDI input device
 */
export async function connectMidiInput(deviceName: string) {
  try {
    await api.connectMidiInput(deviceName);
    midiInputConnected.set(true);
    selectedMidiInput.set(deviceName);
    console.log('Connected to MIDI input:', deviceName);
  } catch (error) {
    console.error('Failed to connect MIDI input:', error);
    midiInputConnected.set(false);
    throw error;
  }
}

/**
 * Connect to MIDI output device
 */
export async function connectMidiOutput(deviceName: string) {
  try {
    await api.connectMidiOutput(deviceName);
    midiOutputConnected.set(true);
    selectedMidiOutput.set(deviceName);
    console.log('Connected to MIDI output:', deviceName);
  } catch (error) {
    console.error('Failed to connect MIDI output:', error);
    midiOutputConnected.set(false);
    throw error;
  }
}

/**
 * Disconnect MIDI input
 */
export async function disconnectMidiInput() {
  try {
    await api.disconnectMidiInput();
    midiInputConnected.set(false);
    console.log('Disconnected MIDI input');
  } catch (error) {
    console.error('Failed to disconnect MIDI input:', error);
    throw error;
  }
}

/**
 * Disconnect MIDI output
 */
export async function disconnectMidiOutput() {
  try {
    await api.disconnectMidiOutput();
    midiOutputConnected.set(false);
    console.log('Disconnected MIDI output');
  } catch (error) {
    console.error('Failed to disconnect MIDI output:', error);
    throw error;
  }
}

/**
 * Load MIDI connection status from backend
 */
export async function loadMidiConnectionStatus() {
  try {
    const [inputConnected, outputConnected, inputName, outputName] = await api.getMidiConnectionStatus();

    midiInputConnected.set(inputConnected);
    midiOutputConnected.set(outputConnected);

    if (inputName) {
      selectedMidiInput.set(inputName);
    }
    if (outputName) {
      selectedMidiOutput.set(outputName);
    }

    console.log('MIDI status loaded:', { inputConnected, outputConnected, inputName, outputName });
  } catch (error) {
    console.error('Failed to load MIDI connection status:', error);
  }
}


