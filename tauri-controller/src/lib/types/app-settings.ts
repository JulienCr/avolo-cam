export interface AlertSettings {
  enabled: boolean;
  temperatureThreshold: number; // Celsius
  cpuThreshold: number; // Percentage
  batteryLowThreshold: number; // Percentage
  batteryCriticalThreshold: number; // Percentage
}

export interface MidiNoteConfig {
  focusToggleNote: number; // 0-127, default 60 (C3)
  // Future notes can be added here
}

export interface MidiSettings {
  inputDeviceName?: string;
  outputDeviceName?: string;
  notes: MidiNoteConfig;
}

export interface AppSettings {
  alerts: {
    temperature: AlertSettings;
    cpu: AlertSettings;
    batteryLow: AlertSettings;
    batteryCritical: AlertSettings;
  };
  midi?: MidiSettings;
  ui_scale: number;
}

export const UI_SCALE_OPTIONS = [
  { value: 100, label: '100%' },
  { value: 110, label: '110%' },
  { value: 125, label: '125%' },
  { value: 150, label: '150%' },
];

export const DEFAULT_MIDI_NOTE_CONFIG: MidiNoteConfig = {
  focusToggleNote: 60, // C3
};

export const DEFAULT_APP_SETTINGS: AppSettings = {
  ui_scale: 100,
  alerts: {
    temperature: {
      enabled: true,
      temperatureThreshold: 40,
      cpuThreshold: 0,
      batteryLowThreshold: 0,
      batteryCriticalThreshold: 0,
    },
    cpu: {
      enabled: true,
      temperatureThreshold: 0,
      cpuThreshold: 100,
      batteryLowThreshold: 0,
      batteryCriticalThreshold: 0,
    },
    batteryLow: {
      enabled: true,
      temperatureThreshold: 0,
      cpuThreshold: 0,
      batteryLowThreshold: 25,
      batteryCriticalThreshold: 0,
    },
    batteryCritical: {
      enabled: true,
      temperatureThreshold: 0,
      cpuThreshold: 0,
      batteryLowThreshold: 0,
      batteryCriticalThreshold: 10,
    },
  },
};
