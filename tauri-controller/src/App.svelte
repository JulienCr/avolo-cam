<script lang="ts">
  import { onMount } from 'svelte';
  import AppHeader from '$lib/components/layout/AppHeader.svelte';
  import CameraColumn from '$lib/components/layout/CameraColumn.svelte';
  import AddCameraDialog from '$lib/components/organisms/AddCameraDialog.svelte';
  import ProfileDialog from '$lib/components/organisms/ProfileDialog.svelte';
  import SettingsDialog from '$lib/components/organisms/SettingsDialog.svelte';

  // Stores
  import {
    cameras,
    discoveredCameras,
    discovering,
    loading,
    error,
    refreshCameras,
    startAutoRefresh,
    stopAutoRefresh,
    addCameraManualAction,
    removeCameraAction,
    discoverCamerasAction,
  } from '$lib/stores/cameras';

  import {
    showAddDialog,
    showProfileDialog,
    showAppSettingsDialog,
    selectedCameraIds,
    selectionCount,
    toggleCameraSelection,
  } from '$lib/stores/ui';

  import {
    currentCameraSettings,
    initFlashDefaults,
  } from '$lib/stores/settings';

  import {
    profiles,
    loadProfiles,
    saveProfileAction,
    applyProfileAction,
    deleteProfileAction,
  } from '$lib/stores/profiles';

  import { loadAppSettings } from '$lib/stores/appSettings';
  import { loadMidiConnectionStatus, loadMidiNotesConfig } from '$lib/stores/midi';

  import * as api from '$lib/utils/api';
  import { get } from 'svelte/store';

  // Lifecycle
  onMount(() => {
    (async () => {
      await loadAppSettings();
      await loadProfiles();
      await loadMidiConnectionStatus();
      await loadMidiNotesConfig();
      await initFlashDefaults();
      startAutoRefresh(2000);
      setTimeout(async () => {
        await discoverCamerasAction();
      }, 2000);
    })();

    return () => {
      stopAutoRefresh();
    };
  });

  // Camera removal
  async function handleRemoveCamera(cameraId: string) {
    if (!confirm('Remove this camera?')) return;
    try {
      await removeCameraAction(cameraId);
      selectedCameraIds.update((set) => {
        set.delete(cameraId);
        return set;
      });
    } catch (e) {
      alert(`Failed to remove camera: ${e}`);
    }
  }

  // Start/Stop All
  async function handleStartAllCameras() {
    const cams = get(cameras);
    if (cams.length === 0) return;
    try {
      const results = await api.startAllCameras();
      const failures = results.filter((r: any) => !r.success);
      if (failures.length > 0) {
        alert(`Failed for ${failures.length} camera(s):\n${failures.map((f: any) => f.error).join('\n')}`);
      }
      await refreshCameras();
    } catch (e) {
      alert(`Start all failed: ${e}`);
    }
  }

  async function handleStopAllCameras() {
    const cams = get(cameras);
    if (cams.length === 0) return;
    try {
      const results = await api.stopAllCameras();
      const failures = results.filter((r: any) => !r.success);
      if (failures.length > 0) {
        alert(`Failed for ${failures.length} camera(s):\n${failures.map((f: any) => f.error).join('\n')}`);
      }
      await refreshCameras();
    } catch (e) {
      alert(`Stop all failed: ${e}`);
    }
  }

  // Profile Actions
  async function handleSaveProfile(name: string) {
    const cs = get(currentCameraSettings);
    const profile = {
      name,
      settings: {
        wb_mode: cs.wb_mode,
        wb_kelvin: cs.wb_mode === 'manual' ? cs.wb_kelvin : null,
        wb_tint: cs.wb_mode === 'manual' ? cs.wb_tint : null,
        iso_mode: cs.iso_mode,
        iso: cs.iso_mode === 'manual' ? cs.iso : null,
        shutter_mode: cs.shutter_mode,
        shutter_s: cs.shutter_mode === 'manual' ? cs.shutter_s : null,
        zoom_factor: cs.zoom_factor,
        lens: cs.lens,
      },
    };
    await saveProfileAction(profile);
    alert('Profile saved!');
  }

  async function handleApplyProfile(profileName: string) {
    const ids = Array.from(get(selectedCameraIds));
    if (ids.length === 0) {
      alert('No cameras selected');
      return;
    }
    await applyProfileAction(profileName, ids);
    alert(`Profile applied to ${ids.length} camera(s)`);
    await refreshCameras();
  }

  // Alias Update
  async function handleAliasUpdated(_cameraId: string, _newAlias: string) {
    await refreshCameras();
  }
</script>

<div class="flex flex-col h-screen bg-background">
  <AppHeader
    cameras={$cameras}
    discovering={$discovering}
    onAddCamera={() => ($showAddDialog = true)}
    onProfiles={() => ($showProfileDialog = true)}
    onRefresh={refreshCameras}
    onDiscover={discoverCamerasAction}
    onSettings={() => ($showAppSettingsDialog = true)}
    onStartAll={handleStartAllCameras}
    onStopAll={handleStopAllCameras}
  />

  {#if $error}
    <div class="px-2 py-1 text-[10px] text-red-400 bg-red-900/20 border-b border-border">
      Error: {$error}
    </div>
  {/if}

  {#if $discovering}
    <div class="px-2 py-1 text-[10px] text-blue-400 bg-blue-900/20 border-b border-border text-center">
      Discovering cameras...
    </div>
  {/if}

  {#if $loading}
    <div class="flex-1 flex items-center justify-center text-xs text-muted-foreground">
      Loading cameras...
    </div>
  {:else if $cameras.length === 0}
    <div class="flex-1 flex flex-col items-center justify-center gap-2">
      <span class="text-xs text-muted-foreground">No cameras found</span>
      <span class="text-[10px] text-muted-foreground">Add a camera or discover on the network</span>
    </div>
  {:else}
    <!-- Camera columns -->
    <div class="flex-1 overflow-x-auto overflow-y-hidden">
      <div class="flex h-full">
        {#each $cameras as camera (camera.id)}
          <CameraColumn
            {camera}
            selected={$selectedCameraIds.has(camera.id)}
            onToggleSelection={() => toggleCameraSelection(camera.id)}
            onRemove={() => handleRemoveCamera(camera.id)}
            onAliasUpdated={(alias) => handleAliasUpdated(camera.id, alias)}
          />
        {/each}
      </div>
    </div>
  {/if}
</div>

<!-- Dialogs -->
<AddCameraDialog open={showAddDialog} onAdd={addCameraManualAction} />

<ProfileDialog
  open={showProfileDialog}
  profiles={$profiles}
  onSave={handleSaveProfile}
  onApply={handleApplyProfile}
  onDelete={deleteProfileAction}
  canSave={false}
/>

{#if $showAppSettingsDialog}
  <SettingsDialog onClose={() => ($showAppSettingsDialog = false)} />
{/if}
