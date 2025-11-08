import { writable } from 'svelte/store';
import type { Profile } from '../types/profile';
import * as api from '../utils/api';

// Profiles state
export const profiles = writable<Profile[]>([]);
export const savingProfile = writable(false);

// Profile name input
export const profileName = writable('');

// Actions
export async function loadProfiles(): Promise<void> {
  try {
    const data = await api.getProfiles();
    profiles.set(data);
    console.log('Loaded profiles:', data);
  } catch (e) {
    console.error('Failed to load profiles:', e);
  }
}

export async function saveProfileAction(profile: Profile): Promise<void> {
  try {
    savingProfile.set(true);
    await api.saveProfile(profile);
    await loadProfiles();
    profileName.set('');
  } catch (e) {
    throw e;
  } finally {
    savingProfile.set(false);
  }
}

export async function deleteProfileAction(name: string): Promise<void> {
  await api.deleteProfile(name);
  await loadProfiles();
}

export async function applyProfileAction(
  profileName: string,
  cameraIds: string[]
): Promise<void> {
  const results = await api.applyProfile(profileName, cameraIds);

  const failures = results.filter((r) => !r.success);
  if (failures.length > 0) {
    const errorMsg = failures.map((f) => f.error).join('\n');
    throw new Error(`Failed for ${failures.length} cameras:\n${errorMsg}`);
  }
}
