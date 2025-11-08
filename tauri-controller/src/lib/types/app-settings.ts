export interface AlertSettings {
  enabled: boolean;
  temperatureThreshold: number; // Celsius
  cpuThreshold: number; // Percentage
}

export interface AppSettings {
  alerts: {
    temperature: AlertSettings;
    cpu: AlertSettings;
  };
}

export const DEFAULT_APP_SETTINGS: AppSettings = {
  alerts: {
    temperature: {
      enabled: true,
      temperatureThreshold: 40,
    },
    cpu: {
      enabled: true,
      cpuThreshold: 100,
    },
  },
};
