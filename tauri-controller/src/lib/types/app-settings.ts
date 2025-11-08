export interface AlertSettings {
  enabled: boolean;
  temperatureThreshold: number; // Celsius
  cpuThreshold: number; // Percentage
  batteryLowThreshold: number; // Percentage
  batteryCriticalThreshold: number; // Percentage
}

export interface AppSettings {
  alerts: {
    temperature: AlertSettings;
    cpu: AlertSettings;
    batteryLow: AlertSettings;
    batteryCritical: AlertSettings;
  };
}

export const DEFAULT_APP_SETTINGS: AppSettings = {
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
