import { writable } from 'svelte/store';
import { invoke } from '@tauri-apps/api/core';
import type { AppSettings } from '../types/app-settings';
import { DEFAULT_APP_SETTINGS } from '../types/app-settings';

// App settings store
export const appSettings = writable<AppSettings>(DEFAULT_APP_SETTINGS);
export const loadingSettings = writable(false);
export const savingAppSettings = writable(false);

// Load settings from backend
export async function loadAppSettings(): Promise<void> {
  try {
    loadingSettings.set(true);
    const loadedSettings = await invoke<AppSettings>('get_app_settings');
    appSettings.set(loadedSettings);
  } catch (e) {
    console.error('Failed to load settings:', e);
    // Use defaults if loading fails
    appSettings.set(DEFAULT_APP_SETTINGS);
  } finally {
    loadingSettings.set(false);
  }
}

// Save settings to backend
export async function saveAppSettings(newSettings: AppSettings): Promise<void> {
  try {
    savingAppSettings.set(true);
    await invoke('save_app_settings', { settings: newSettings });
    appSettings.set(newSettings);
  } catch (e) {
    console.error('Failed to save settings:', e);
    throw e;
  } finally {
    savingAppSettings.set(false);
  }
}

// Delete cameras.json file
export async function deleteCamerasData(): Promise<void> {
  try {
    await invoke('delete_cameras_data');
  } catch (e) {
    console.error('Failed to delete cameras data:', e);
    throw e;
  }
}
