import { writable, get } from 'svelte/store';
import type { CameraSettings } from '$lib/types/settings';

export interface CameraPreset {
  label: string;
  settings: Partial<CameraSettings>;
  builtin?: boolean;
}

const BUILTIN_PRESETS: Record<string, CameraPreset> = {
  indoor: {
    label: 'Indoor',
    builtin: true,
    settings: {
      wb_mode: 'manual',
      wb_kelvin: 3200,
      iso_mode: 'auto',
      shutter_mode: 'auto',
    },
  },
  daylight: {
    label: 'Daylight',
    builtin: true,
    settings: {
      wb_mode: 'manual',
      wb_kelvin: 5600,
      iso_mode: 'auto',
      shutter_mode: 'auto',
    },
  },
  stage: {
    label: 'Stage',
    builtin: true,
    settings: {
      wb_mode: 'manual',
      wb_kelvin: 4000,
      iso_mode: 'manual',
      iso: 800,
      shutter_mode: 'manual',
      shutter_s: 0.02,
    },
  },
  lowlight: {
    label: 'Low Light',
    builtin: true,
    settings: {
      wb_mode: 'manual',
      wb_kelvin: 4500,
      iso_mode: 'manual',
      iso: 1600,
      shutter_mode: 'auto',
    },
  },
};

const STORAGE_KEY = 'avolocam_custom_presets';

function loadCustomPresets(): Record<string, CameraPreset> {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (raw) return JSON.parse(raw);
  } catch (e) {
    console.warn('Failed to load custom presets:', e);
  }
  return {};
}

function saveCustomPresets(presets: Record<string, CameraPreset>) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(presets));
  } catch (e) {
    console.warn('Failed to save custom presets:', e);
  }
}

// Store: merged built-in + custom presets
export const allPresets = writable<Record<string, CameraPreset>>({
  ...BUILTIN_PRESETS,
  ...loadCustomPresets(),
});

function getCustomFromStore(): Record<string, CameraPreset> {
  const all = get(allPresets);
  const custom: Record<string, CameraPreset> = {};
  for (const [k, v] of Object.entries(all)) {
    if (!v.builtin) custom[k] = v;
  }
  return custom;
}

export function saveCustomPreset(key: string, preset: CameraPreset) {
  const custom = getCustomFromStore();
  custom[key] = { ...preset, builtin: false };
  saveCustomPresets(custom);
  allPresets.set({ ...BUILTIN_PRESETS, ...custom });
}

export function deleteCustomPreset(key: string) {
  const custom = getCustomFromStore();
  delete custom[key];
  saveCustomPresets(custom);
  allPresets.set({ ...BUILTIN_PRESETS, ...custom });
}

export function createPresetFromSettings(label: string, settings: CameraSettings): CameraPreset {
  return {
    label,
    builtin: false,
    settings: {
      wb_mode: settings.wb_mode,
      wb_kelvin: settings.wb_mode === 'manual' ? settings.wb_kelvin : undefined,
      wb_tint: settings.wb_mode === 'manual' ? settings.wb_tint : undefined,
      iso_mode: settings.iso_mode,
      iso: settings.iso_mode === 'manual' ? settings.iso : undefined,
      shutter_mode: settings.shutter_mode,
      shutter_s: settings.shutter_mode === 'manual' ? settings.shutter_s : undefined,
    },
  };
}

