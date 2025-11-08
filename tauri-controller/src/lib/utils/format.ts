/**
 * Format bitrate from bps to human-readable Mbps
 */
export function formatBitrate(bitrate: number): string {
  return (bitrate / 1000000).toFixed(1);
}

/**
 * Format shutter speed in seconds to readable format (e.g., "1/100")
 */
export function formatShutterSpeed(seconds: number): string {
  if (seconds >= 1) {
    return seconds.toFixed(1) + 's';
  } else {
    return '1/' + Math.round(1.0 / seconds);
  }
}

/**
 * Format battery percentage
 */
export function formatBattery(battery: number): string {
  return (battery * 100).toFixed(0) + '%';
}

/**
 * Format temperature in Celsius
 */
export function formatTemperature(tempC: number): string {
  return tempC.toFixed(1) + '°C';
}
