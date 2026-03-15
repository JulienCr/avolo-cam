<script lang="ts">
  import { onMount } from 'svelte';
  import AppHeader from '$lib/components/layout/AppHeader.svelte';
  import OverviewGrid from '$lib/components/views/OverviewGrid.svelte';
  import DetailView from '$lib/components/views/DetailView.svelte';
  import AddCameraDialog from '$lib/components/organisms/AddCameraDialog.svelte';
  import ProfileDialog from '$lib/components/organisms/ProfileDialog.svelte';
  import SettingsDialog from '$lib/components/organisms/SettingsDialog.svelte';
  import ToastContainer from '$lib/components/layout/ToastContainer.svelte';
  import { toastSuccess, toastError } from '$lib/stores/toast';

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
    viewMode,
    detailCameraId,
    backToOverview,
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

  import { appSettings, loadAppSettings } from '$lib/stores/appSettings';
  import { loadMidiConnectionStatus, loadMidiNotesConfig } from '$lib/stores/midi';

  import * as api from '$lib/utils/api';
  import { get } from 'svelte/store';

  // Apply UI scale as CSS zoom
  $effect(() => {
    const scale = $appSettings.ui_scale ?? 100;
    document.documentElement.style.zoom = `${scale}%`;
  });

  // Lifecycle
  onMount(() => {
    (async () => {
      await loadAppSettings();
      await Promise.all([
        loadProfiles(),
        loadMidiConnectionStatus(),
        loadMidiNotesConfig(),
        initFlashDefaults(),
      ]);
      startAutoRefresh(2000);
      discoverCamerasAction();
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
      // If we're viewing this camera in detail, go back
      if ($detailCameraId === cameraId) {
        backToOverview();
      }
    } catch (e) {
      toastError(`Failed to remove camera: ${e}`);
    }
  }

  // Start/Stop All
  async function handleGroupAction(action: () => Promise<any[]>, label: string) {
    const cams = get(cameras);
    if (cams.length === 0) return;
    try {
      const results = await action();
      const failures = results.filter((r: any) => !r.success);
      if (failures.length > 0) {
        toastError(`${label} failed for ${failures.length} camera(s)`);
      }
      await refreshCameras();
    } catch (e) {
      toastError(`${label} all failed: ${e}`);
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
    toastSuccess('Profile saved');
  }

  async function handleApplyProfile(profileName: string) {
    const ids = Array.from(get(selectedCameraIds));
    if (ids.length === 0) {
      toastError('No cameras selected');
      return;
    }
    await applyProfileAction(profileName, ids);
    toastSuccess(`Profile applied to ${ids.length} camera(s)`);
    await refreshCameras();
  }

  // Alias Update
  async function handleAliasUpdated(_cameraId: string, _newAlias: string) {
    await refreshCameras();
  }

  // Detail view camera
  let detailCamera = $derived($cameras.find(c => c.id === $detailCameraId));

  // If detail camera disappears, go back to overview
  $effect(() => {
    if ($viewMode === 'detail' && $detailCameraId && !detailCamera) {
      backToOverview();
    }
  });
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
    onStartAll={() => handleGroupAction(api.startAllCameras, 'Start')}
    onStopAll={() => handleGroupAction(api.stopAllCameras, 'Stop')}
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

  <div class="flex-1 overflow-auto p-3">
    <main>
      {#if $loading}
        <div class="flex-1 flex items-center justify-center text-xs text-muted-foreground h-full">
          Loading cameras...
        </div>
      {:else if $viewMode === 'overview'}
        <OverviewGrid
          cameras={$cameras}
          onRemoveCamera={handleRemoveCamera}
          onAliasUpdated={handleAliasUpdated}
        />
      {:else if $viewMode === 'detail' && detailCamera}
        <DetailView
          camera={detailCamera}
          onRemove={() => handleRemoveCamera(detailCamera!.id)}
          onAliasUpdated={(alias) => handleAliasUpdated(detailCamera!.id, alias)}
        />
      {/if}
    </main>
  </div>
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

<ToastContainer />
