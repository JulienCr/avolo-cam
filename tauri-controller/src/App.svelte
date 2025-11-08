<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import StatusBar from '$lib/components/organisms/StatusBar.svelte';
  import GroupControlBar from '$lib/components/organisms/GroupControlBar.svelte';
  import CameraCard from '$lib/components/organisms/CameraCard.svelte';
  import AddCameraDialog from '$lib/components/organisms/AddCameraDialog.svelte';
  import ProfileDialog from '$lib/components/organisms/ProfileDialog.svelte';
  import CameraSettingsDialog from '$lib/components/organisms/CameraSettingsDialog.svelte';
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
  } from '$lib/stores/cameras';

  import {
    showAddDialog,
    showProfileDialog,
    showSettingsDialog,
    settingsCameraId,
    selectedCameraIds,
    selectionCount,
    toggleCameraSelection,
    openSettingsDialog,
    closeSettingsDialog,
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
    startAutoRefresh(2000, 10000);
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

  async function handleForceKeyframe(cameraId: string) {
    try {
      await api.forceKeyframe(cameraId);
    } catch (e) {
      alert(`Failed to force keyframe: ${e}`);
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

  // Settings Dialog
  function handleOpenSettings(cameraId: string) {
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

    // Ensure stream settings exist
    getStreamSettings(cameraId);

    openSettingsDialog(cameraId);
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

  // Watch for settings changes
  $: if ($settingsCameraId && $showSettingsDialog) {
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

  // Reactive stream settings for current camera
  $: currentStreamSettings = $settingsCameraId
    ? getStreamSettings($settingsCameraId)
    : { resolution: '1920x1080', framerate: 30, bitrate: 10000000, codec: 'h264' };
</script>

<main class="container mx-auto max-w-7xl px-4 py-6">
  <StatusBar
    onAddCamera={() => ($showAddDialog = true)}
    onProfiles={() => ($showProfileDialog = true)}
    onRefresh={refreshCameras}
  />

  {#if $error}
    <div class="mb-4 rounded-lg bg-red-50 p-4 text-red-700">
      Error: {$error}
    </div>
  {/if}

  {#if $loading}
    <div class="py-20 text-center text-gray-500">Loading cameras...</div>
  {:else if $cameras.length === 0}
    <div class="py-20 text-center">
      <p class="text-lg text-gray-600">No cameras found</p>
      <p class="mt-2 text-sm text-gray-500">Add a camera manually or ensure cameras are on the same network</p>
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

    <!-- Discovered Cameras -->
    {#if $discoveredCameras.length > 0}
      <div class="mb-6">
        <h2 class="mb-3 text-lg font-semibold text-primary-600">
          📡 Discovered Cameras ({$discoveredCameras.length})
        </h2>
        <div class="grid gap-3 md:grid-cols-2 lg:grid-cols-3">
          {#each $discoveredCameras as discovered (discovered.alias)}
            <Card padding="sm">
              <div class="flex items-center justify-between">
                <div class="flex flex-col">
                  <strong class="text-sm text-gray-900">{discovered.alias}</strong>
                  <small class="text-xs text-gray-500">{discovered.ip}:{discovered.port}</small>
                </div>
                <Button
                  variant="primary"
                  size="sm"
                  on:click={() => handleAddDiscoveredCamera(discovered)}
                >
                  + Add
                </Button>
              </div>
            </Card>
          {/each}
        </div>
      </div>
    {:else if $discovering}
      <div class="mb-6 rounded-lg bg-yellow-50 p-4 text-center text-yellow-800">
        🔍 Discovering cameras on the network...
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
          onSettings={() => handleOpenSettings(camera.id)}
          onRemove={() => handleRemoveCamera(camera.id)}
          onForceKeyframe={() => handleForceKeyframe(camera.id)}
        />
      {/each}
    </div>
  {/if}
</main>

<!-- Dialogs -->
<AddCameraDialog bind:open={$showAddDialog} onAdd={addCameraManualAction} />

<ProfileDialog
  bind:open={$showProfileDialog}
  profiles={$profiles}
  onSave={handleSaveProfile}
  onApply={handleApplyProfile}
  onDelete={deleteProfileAction}
  canSave={$showSettingsDialog && !!$settingsCameraId}
/>

{#if $settingsCameraId}
  <CameraSettingsDialog
    bind:open={$showSettingsDialog}
    cameraId={$settingsCameraId}
    bind:streamSettings={$cameraStreamSettings[$settingsCameraId]}
    bind:cameraSettings={$currentCameraSettings}
    onMeasureWB={handleMeasureWB}
    measuring={$measuringWB}
    saving={$savingSettings}
  />
{/if}
