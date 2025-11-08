<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import StatusBar from '$lib/components/organisms/StatusBar.svelte';
  import GroupControlBar from '$lib/components/organisms/GroupControlBar.svelte';
  import CameraCard from '$lib/components/organisms/CameraCard.svelte';
  import AddCameraDialog from '$lib/components/organisms/AddCameraDialog.svelte';
  import ProfileDialog from '$lib/components/organisms/ProfileDialog.svelte';
  import CameraSettingsDialog from '$lib/components/organisms/CameraSettingsDialog.svelte';
  import StreamSettingsDialog from '$lib/components/organisms/StreamSettingsDialog.svelte';
  import Card from '$lib/components/atoms/Card.svelte';
  import Button from '$lib/components/atoms/Button.svelte';

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
    addDiscoveredCameraAction,
    removeCameraAction,
    discoverCamerasAction,
  } from '$lib/stores/cameras';

  import {
    showAddDialog,
    showProfileDialog,
    showSettingsDialog,
    showStreamSettingsDialog,
    settingsCameraId,
    streamSettingsCameraId,
    selectedCameraIds,
    selectionCount,
    toggleCameraSelection,
    openSettingsDialog,
    closeSettingsDialog,
    openStreamSettingsDialog,
    closeStreamSettingsDialog,
  } from '$lib/stores/ui';

  import {
    cameraStreamSettings,
    currentCameraSettings,
    savingSettings,
    measuringWB,
    getStreamSettings,
    updateStreamSettings,
  } from '$lib/stores/settings';

  import {
    profiles,
    profileName,
    savingProfile,
    loadProfiles,
    saveProfileAction,
    applyProfileAction,
    deleteProfileAction,
  } from '$lib/stores/profiles';

  import * as api from '$lib/utils/api';
  import { debounce } from '$lib/utils/debounce';
  import { DEFAULT_CAMERA_SETTINGS } from '$lib/types/settings';

  // Lifecycle
  onMount(async () => {
    await loadProfiles();
    startAutoRefresh(2000);
    // Auto-discover and add cameras on startup after a short delay
    // to allow mDNS discovery to complete
    setTimeout(async () => {
      await discoverCamerasAction();
    }, 2000);
  });

  onDestroy(() => {
    stopAutoRefresh();
  });

  // Camera Actions
  async function handleStartStream(cameraId: string) {
    try {
      const settings = getStreamSettings(cameraId);
      await api.startStream(cameraId, settings);
      await refreshCameras();
    } catch (e) {
      alert(`Failed to start stream: ${e}`);
    }
  }

  async function handleStopStream(cameraId: string) {
    try {
      await api.stopStream(cameraId);
      await refreshCameras();
    } catch (e) {
      alert(`Failed to stop stream: ${e}`);
    }
  }

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

  // Group Actions
  async function handleGroupStartStream() {
    const ids = Array.from($selectedCameraIds);
    if (ids.length === 0) {
      alert('No cameras selected');
      return;
    }

    try {
      const firstId = ids[0];
      const settings = getStreamSettings(firstId);
      const results = await api.groupStartStream(ids, settings);

      const failures = results.filter((r) => !r.success);
      if (failures.length > 0) {
        alert(`Failed for ${failures.length} cameras:\n${failures.map((f) => f.error).join('\n')}`);
      }

      await refreshCameras();
    } catch (e) {
      alert(`Group start failed: ${e}`);
    }
  }

  async function handleGroupStopStream() {
    const ids = Array.from($selectedCameraIds);
    if (ids.length === 0) {
      alert('No cameras selected');
      return;
    }

    try {
      await api.groupStopStream(ids);
      await refreshCameras();
    } catch (e) {
      alert(`Group stop failed: ${e}`);
    }
  }

  // Camera Settings Dialog
  function handleOpenCameraSettings(cameraId: string) {
    // Load current settings from camera
    const camera = $cameras.find((c) => c.id === cameraId);
    if (camera?.status?.current) {
      const current = camera.status.current;
      $currentCameraSettings = {
        wb_mode: current.wb_mode || 'auto',
        wb_kelvin: current.wb_kelvin || 5000,
        wb_tint: current.wb_tint || 0,
        iso_mode: current.iso_mode || 'auto',
        iso: current.iso || 400,
        shutter_mode: current.shutter_mode || 'auto',
        shutter_s: current.shutter_s || 0.01,
        zoom_factor: current.zoom_factor || 2.0,
        lens: current.lens || 'wide',
        camera_position: current.camera_position || 'back',
      };
    } else {
      $currentCameraSettings = { ...DEFAULT_CAMERA_SETTINGS };
    }

    openSettingsDialog(cameraId);
  }

  // Stream Settings Dialog
  function handleOpenStreamSettings(cameraId: string) {
    // Ensure stream settings exist
    getStreamSettings(cameraId);
    openStreamSettingsDialog(cameraId);
  }

  // Debounced settings update
  const debouncedUpdateSettings = debounce(async () => {
    if (!$settingsCameraId) return;

    try {
      savingSettings.set(true);

      const settings: any = {
        wb_mode: $currentCameraSettings.wb_mode,
        iso_mode: $currentCameraSettings.iso_mode,
        shutter_mode: $currentCameraSettings.shutter_mode,
        zoom_factor: $currentCameraSettings.zoom_factor,
        lens: $currentCameraSettings.lens,
        camera_position: $currentCameraSettings.camera_position,
      };

      if ($currentCameraSettings.wb_mode === 'manual') {
        settings.wb_kelvin = $currentCameraSettings.wb_kelvin;
        settings.wb_tint = $currentCameraSettings.wb_tint;
      }
      if ($currentCameraSettings.iso_mode === 'manual') {
        settings.iso = $currentCameraSettings.iso;
      }
      if ($currentCameraSettings.shutter_mode === 'manual') {
        settings.shutter_s = $currentCameraSettings.shutter_s;
      }

      await api.updateCameraSettings($settingsCameraId, settings);
      await refreshCameras();
    } catch (e) {
      console.error('Failed to update settings:', e);
    } finally {
      savingSettings.set(false);
    }
  }, 300);

  // Watch for settings changes and auto-save with debounce
  $: if ($settingsCameraId && $showSettingsDialog) {
    // Access all settings properties to create reactive dependencies
    const _ = [
      $currentCameraSettings.wb_mode,
      $currentCameraSettings.wb_kelvin,
      $currentCameraSettings.wb_tint,
      $currentCameraSettings.iso_mode,
      $currentCameraSettings.iso,
      $currentCameraSettings.shutter_mode,
      $currentCameraSettings.shutter_s,
      $currentCameraSettings.zoom_factor,
      $currentCameraSettings.lens,
      $currentCameraSettings.camera_position,
    ];
    debouncedUpdateSettings();
  }

  // White Balance Measurement
  async function handleMeasureWB() {
    if (!$settingsCameraId) return;

    try {
      measuringWB.set(true);
      const result = await api.measureWhiteBalance($settingsCameraId);

      $currentCameraSettings.wb_kelvin = result.scene_cct_k;
      $currentCameraSettings.wb_tint = Math.round(result.tint);
      $currentCameraSettings.wb_mode = 'manual';

      console.log('WB Measured:', result);
    } catch (e) {
      alert(`Failed to measure white balance: ${e}`);
    } finally {
      measuringWB.set(false);
    }
  }

  // Profile Actions
  async function handleSaveProfile(name: string) {
    const profile = {
      name,
      settings: {
        wb_mode: $currentCameraSettings.wb_mode,
        wb_kelvin: $currentCameraSettings.wb_mode === 'manual' ? $currentCameraSettings.wb_kelvin : null,
        wb_tint: $currentCameraSettings.wb_mode === 'manual' ? $currentCameraSettings.wb_tint : null,
        iso_mode: $currentCameraSettings.iso_mode,
        iso: $currentCameraSettings.iso_mode === 'manual' ? $currentCameraSettings.iso : null,
        shutter_mode: $currentCameraSettings.shutter_mode,
        shutter_s: $currentCameraSettings.shutter_mode === 'manual' ? $currentCameraSettings.shutter_s : null,
        zoom_factor: $currentCameraSettings.zoom_factor,
        lens: $currentCameraSettings.lens,
      },
    };

    await saveProfileAction(profile);
    alert('Profile saved successfully!');
  }

  async function handleApplyProfile(profileName: string) {
    const ids = Array.from($selectedCameraIds);
    if (ids.length === 0) {
      alert('No cameras selected');
      return;
    }

    await applyProfileAction(profileName, ids);
    alert(`Profile "${profileName}" applied to ${ids.length} camera(s)`);
    await refreshCameras();
  }

  // Discovered Camera
  async function handleAddDiscoveredCamera(discovered: any) {
    const token = prompt(`Enter bearer token for ${discovered.alias}:`, '');
    if (!token) return;

    try {
      await addDiscoveredCameraAction(discovered, token);
    } catch (e) {
      alert(`Failed to add camera: ${e}`);
    }
  }
</script>

<main class="container mx-auto max-w-7xl px-4 py-6 dark:bg-gray-900">
  <StatusBar
    cameras={$cameras}
    onAddCamera={() => ($showAddDialog = true)}
    onProfiles={() => ($showProfileDialog = true)}
    onRefresh={refreshCameras}
    onDiscover={discoverCamerasAction}
    discovering={$discovering}
  />

  {#if $error}
    <div class="mb-4 rounded-lg bg-red-50 p-4 text-red-700 dark:bg-red-900/20 dark:text-red-400">
      Error: {$error}
    </div>
  {/if}

  {#if $loading}
    <div class="py-20 text-center text-gray-500 dark:text-gray-400">Loading cameras...</div>
  {:else if $cameras.length === 0}
    <div class="py-20 text-center">
      <p class="text-lg text-gray-600 dark:text-gray-300">No cameras found</p>
      <p class="mt-2 text-sm text-gray-500 dark:text-gray-400">Add a camera manually or ensure cameras are on the same network</p>
    </div>
  {:else}
    <!-- Group Controls -->
    {#if $selectionCount > 0}
      <div class="mb-6">
        <GroupControlBar
          count={$selectionCount}
          onStartAll={handleGroupStartStream}
          onStopAll={handleGroupStopStream}
        />
      </div>
    {/if}

    <!-- Discovery Status -->
    {#if $discovering}
      <div class="mb-6 rounded-lg bg-blue-50 p-4 text-center text-blue-800 dark:bg-blue-900/20 dark:text-blue-400">
        🔍 Discovering and adding cameras...
      </div>
    {/if}

    <!-- Camera Grid -->
    <div class="grid gap-5 md:grid-cols-2 lg:grid-cols-3">
      {#each $cameras as camera (camera.id)}
        <CameraCard
          {camera}
          selected={$selectedCameraIds.has(camera.id)}
          onToggleSelection={() => toggleCameraSelection(camera.id)}
          onStart={() => handleStartStream(camera.id)}
          onStop={() => handleStopStream(camera.id)}
          onCameraSettings={() => handleOpenCameraSettings(camera.id)}
          onStreamSettings={() => handleOpenStreamSettings(camera.id)}
        />
      {/each}
    </div>
  {/if}
</main>

<!-- Dialogs -->
<AddCameraDialog open={showAddDialog} onAdd={addCameraManualAction} />

<ProfileDialog
  open={showProfileDialog}
  profiles={$profiles}
  onSave={handleSaveProfile}
  onApply={handleApplyProfile}
  onDelete={deleteProfileAction}
  canSave={$showSettingsDialog && !!$settingsCameraId}
/>

{#if $settingsCameraId}
  <CameraSettingsDialog
    open={showSettingsDialog}
    bind:cameraSettings={$currentCameraSettings}
    onMeasureWB={handleMeasureWB}
    measuring={$measuringWB}
    saving={$savingSettings}
  />
{/if}

{#if $streamSettingsCameraId}
  <StreamSettingsDialog
    open={showStreamSettingsDialog}
    cameraId={$streamSettingsCameraId}
    bind:settings={$cameraStreamSettings[$streamSettingsCameraId]}
  />
{/if}
