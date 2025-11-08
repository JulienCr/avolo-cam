import { writable, derived } from 'svelte/store';

// Dialog visibility
export const showAddDialog = writable(false);
export const showProfileDialog = writable(false);
export const showSettingsDialog = writable(false);
export const showStreamSettingsDialog = writable(false);

// Active camera for settings
export const settingsCameraId = writable<string | null>(null);
export const streamSettingsCameraId = writable<string | null>(null);

// Camera selection (for group operations)
export const selectedCameraIds = writable<Set<string>>(new Set());

// Derived: selection count
export const selectionCount = derived(
  selectedCameraIds,
  ($selectedCameraIds) => $selectedCameraIds.size
);

// Derived: is camera selected
export const isCameraSelected = derived(
  selectedCameraIds,
  ($selectedCameraIds) => (id: string) => $selectedCameraIds.has(id)
);

// Actions
export function toggleCameraSelection(cameraId: string): void {
  selectedCameraIds.update((set) => {
    const newSet = new Set(set);
    if (newSet.has(cameraId)) {
      newSet.delete(cameraId);
    } else {
      newSet.add(cameraId);
    }
    return newSet;
  });
}

export function clearSelection(): void {
  selectedCameraIds.set(new Set());
}

export function selectAll(cameraIds: string[]): void {
  selectedCameraIds.set(new Set(cameraIds));
}

export function openSettingsDialog(cameraId: string): void {
  console.log('[UI Store] openSettingsDialog called:', cameraId);
  settingsCameraId.set(cameraId);
  showSettingsDialog.set(true);
  console.log('[UI Store] showSettingsDialog set to true');
}

export function closeSettingsDialog(): void {
  console.log('[UI Store] closeSettingsDialog called');
  settingsCameraId.set(null);
  showSettingsDialog.set(false);
}

export function openStreamSettingsDialog(cameraId: string): void {
  console.log('[UI Store] openStreamSettingsDialog called:', cameraId);
  streamSettingsCameraId.set(cameraId);
  showStreamSettingsDialog.set(true);
}

export function closeStreamSettingsDialog(): void {
  console.log('[UI Store] closeStreamSettingsDialog called');
  streamSettingsCameraId.set(null);
  showStreamSettingsDialog.set(false);
}
