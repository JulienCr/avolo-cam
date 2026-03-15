<script lang="ts">
  import { onMount } from 'svelte';
  import { appSettings, saveAppSettings, deleteCamerasData, savingAppSettings } from '$lib/stores/appSettings';
  import { refreshCameras } from '$lib/stores/cameras';
  import MidiSettingsPanel from './MidiSettingsPanel.svelte';
  import { invoke } from '@tauri-apps/api/core';
  import { UI_SCALE_OPTIONS } from '$lib/types/app-settings';
  import { toastSuccess, toastError } from '$lib/stores/toast';

  let { onClose }: { onClose: () => void } = $props();

  let activeTab = $state('display');

  let temperatureEnabled = $state($appSettings.alerts.temperature.enabled);
  let temperatureThreshold = $state($appSettings.alerts.temperature.temperatureThreshold);
  let cpuEnabled = $state($appSettings.alerts.cpu.enabled);
  let cpuThreshold = $state($appSettings.alerts.cpu.cpuThreshold);
  let batteryLowEnabled = $state($appSettings.alerts.batteryLow.enabled);
  let batteryLowThreshold = $state($appSettings.alerts.batteryLow.batteryLowThreshold);
  let batteryCriticalEnabled = $state($appSettings.alerts.batteryCritical.enabled);
  let batteryCriticalThreshold = $state($appSettings.alerts.batteryCritical.batteryCriticalThreshold);
  let uiScale = $state($appSettings.ui_scale ?? 100);

  let notificationPermissionGranted = $state(false);
  let checkingPermission = $state(true);
  let requestingPermission = $state(false);
  let dataDirectory = $state('');

  const tabs = [
    { id: 'display', label: 'Display' },
    { id: 'alerts', label: 'Alerts' },
    { id: 'midi', label: 'MIDI' },
    { id: 'data', label: 'Data' },
  ];

  onMount(async () => {
    try {
      checkingPermission = true;
      notificationPermissionGranted = await invoke<boolean>('check_notification_permission');
      dataDirectory = await invoke<string>('get_data_directory');
    } catch { /* ignore */ } finally {
      checkingPermission = false;
    }
  });

  async function requestNotificationPermission() {
    try {
      requestingPermission = true;
      notificationPermissionGranted = await invoke<boolean>('request_notification_permission');
    } catch (e) { toastError('Failed: ' + e); } finally { requestingPermission = false; }
  }

  async function handleSave() {
    try {
      await saveAppSettings({
        ui_scale: uiScale,
        alerts: {
          temperature: { enabled: temperatureEnabled, temperatureThreshold, cpuThreshold: 0, batteryLowThreshold: 0, batteryCriticalThreshold: 0 },
          cpu: { enabled: cpuEnabled, temperatureThreshold: 0, cpuThreshold, batteryLowThreshold: 0, batteryCriticalThreshold: 0 },
          batteryLow: { enabled: batteryLowEnabled, temperatureThreshold: 0, cpuThreshold: 0, batteryLowThreshold, batteryCriticalThreshold: 0 },
          batteryCritical: { enabled: batteryCriticalEnabled, temperatureThreshold: 0, cpuThreshold: 0, batteryLowThreshold: 0, batteryCriticalThreshold },
        },
      });
      toastSuccess('Settings saved');
      onClose();
    } catch (e) { toastError('Failed to save settings: ' + e); }
  }

  async function handleDeleteCameras() {
    if (!confirm('Delete all saved camera data?')) return;
    try {
      await deleteCamerasData();
      await refreshCameras();
      toastSuccess('Camera data deleted');
      onClose();
    } catch (e) { toastError('Failed: ' + e); }
  }

  async function handleTestNotification() {
    if (!notificationPermissionGranted) { toastError('Enable notifications first'); return; }
    try {
      await invoke('send_test_notification', { title: 'Test', body: 'Notifications working!' });
    } catch (e) { toastError('Failed: ' + e); }
  }
</script>

<!-- svelte-ignore a11y_click_events_have_key_events -->
<!-- svelte-ignore a11y_no_static_element_interactions -->
<div class="fixed inset-0 z-50 flex items-center justify-center bg-black/60" onclick={onClose}>
  <div class="w-[480px] max-h-[80vh] bg-card border border-border rounded-sm shadow-lg flex flex-col" onclick={(e) => e.stopPropagation()}>
    <!-- Header -->
    <div class="flex items-center justify-between px-3 py-2 border-b border-border">
      <h2 class="text-xs font-semibold text-foreground">Settings</h2>
      <button onclick={onClose} class="text-muted-foreground hover:text-foreground text-sm">X</button>
    </div>

    <!-- Tabs -->
    <div class="flex border-b border-border px-3">
      {#each tabs as tab}
        <button
          onclick={() => activeTab = tab.id}
          class="px-2 py-1.5 text-[10px] font-medium border-b-2 transition-colors
            {activeTab === tab.id ? 'border-primary text-primary' : 'border-transparent text-muted-foreground hover:text-foreground'}"
        >{tab.label}</button>
      {/each}
    </div>

    <!-- Content -->
    <div class="flex-1 overflow-y-auto px-3 py-3">
      {#if activeTab === 'display'}
        <div class="flex flex-col gap-2">
          <span class="text-[10px] font-medium text-foreground">UI Scale</span>
          <div class="flex gap-1">
            {#each UI_SCALE_OPTIONS as option}
              <button
                onclick={() => uiScale = option.value}
                class="px-2 py-1 text-[10px] font-medium rounded-sm border transition-colors
                  {uiScale === option.value
                    ? 'bg-primary text-primary-foreground border-primary'
                    : 'bg-secondary text-secondary-foreground border-border hover:bg-accent'}"
              >{option.label}</button>
            {/each}
          </div>
          <span class="text-[9px] text-muted-foreground">Scale the entire interface. Useful for large screens.</span>
        </div>
      {:else if activeTab === 'alerts'}
        {#if !checkingPermission && !notificationPermissionGranted}
          <div class="flex items-center justify-between mb-2 p-1.5 border border-orange-800 bg-orange-950 rounded-sm">
            <span class="text-[10px] text-orange-400">Notifications not enabled</span>
            <button onclick={requestNotificationPermission} disabled={requestingPermission}
              class="h-5 px-1.5 text-[9px] rounded-sm bg-primary text-primary-foreground hover:opacity-90 disabled:opacity-40">
              {requestingPermission ? 'Requesting...' : 'Enable'}
            </button>
          </div>
        {/if}

        <div class="flex flex-col gap-1">
          <!-- Temperature -->
          <div class="flex items-center gap-2 p-1.5 border border-border rounded-sm">
            <label class="flex items-center gap-1.5 min-w-[100px]">
              <input type="checkbox" bind:checked={temperatureEnabled} class="h-3 w-3 accent-primary" />
              <span class="text-[10px] text-foreground">Temperature</span>
            </label>
            <span class="text-[9px] text-muted-foreground">&gt;</span>
            <input type="number" bind:value={temperatureThreshold} disabled={!temperatureEnabled} min="30" max="60"
              class="w-12 h-5 px-1 text-[10px] bg-input border border-border rounded-sm text-foreground disabled:opacity-40" />
            <span class="text-[9px] text-muted-foreground">C</span>
          </div>

          <!-- CPU -->
          <div class="flex items-center gap-2 p-1.5 border border-border rounded-sm">
            <label class="flex items-center gap-1.5 min-w-[100px]">
              <input type="checkbox" bind:checked={cpuEnabled} class="h-3 w-3 accent-primary" />
              <span class="text-[10px] text-foreground">CPU</span>
            </label>
            <span class="text-[9px] text-muted-foreground">&gt;</span>
            <input type="number" bind:value={cpuThreshold} disabled={!cpuEnabled} min="50" max="200"
              class="w-12 h-5 px-1 text-[10px] bg-input border border-border rounded-sm text-foreground disabled:opacity-40" />
            <span class="text-[9px] text-muted-foreground">%</span>
          </div>

          <!-- Battery Low -->
          <div class="flex items-center gap-2 p-1.5 border border-border rounded-sm">
            <label class="flex items-center gap-1.5 min-w-[100px]">
              <input type="checkbox" bind:checked={batteryLowEnabled} class="h-3 w-3 accent-primary" />
              <span class="text-[10px] text-foreground">Battery Low</span>
            </label>
            <span class="text-[9px] text-muted-foreground">&lt;</span>
            <input type="number" bind:value={batteryLowThreshold} disabled={!batteryLowEnabled} min="10" max="50"
              class="w-12 h-5 px-1 text-[10px] bg-input border border-border rounded-sm text-foreground disabled:opacity-40" />
            <span class="text-[9px] text-muted-foreground">%</span>
          </div>

          <!-- Battery Critical -->
          <div class="flex items-center gap-2 p-1.5 border border-border rounded-sm">
            <label class="flex items-center gap-1.5 min-w-[100px]">
              <input type="checkbox" bind:checked={batteryCriticalEnabled} class="h-3 w-3 accent-primary" />
              <span class="text-[10px] text-foreground">Battery Crit</span>
            </label>
            <span class="text-[9px] text-muted-foreground">&lt;</span>
            <input type="number" bind:value={batteryCriticalThreshold} disabled={!batteryCriticalEnabled} min="5" max="25"
              class="w-12 h-5 px-1 text-[10px] bg-input border border-border rounded-sm text-foreground disabled:opacity-40" />
            <span class="text-[9px] text-muted-foreground">%</span>
          </div>
        </div>

        <div class="flex justify-center mt-2">
          <button onclick={handleTestNotification} disabled={!notificationPermissionGranted}
            class="h-5 px-2 text-[9px] rounded-sm bg-secondary text-secondary-foreground hover:bg-accent disabled:opacity-40">
            Test Notification
          </button>
        </div>
      {/if}

      {#if activeTab === 'midi'}
        <MidiSettingsPanel />
      {/if}

      {#if activeTab === 'data'}
        <div class="flex flex-col gap-3">
          {#if dataDirectory}
            <div class="flex flex-col gap-1">
              <span class="text-[10px] font-medium text-foreground">Data Location</span>
              <code class="text-[9px] text-muted-foreground bg-secondary px-1.5 py-1 rounded-sm break-all select-all">{dataDirectory}</code>
            </div>
          {/if}
          <div class="flex flex-col gap-1">
            <span class="text-[10px] font-medium text-foreground">Delete Camera Data</span>
            <span class="text-[9px] text-muted-foreground">Remove all saved cameras. App will rediscover on network.</span>
            <button onclick={handleDeleteCameras}
              class="h-6 px-2 text-[10px] font-medium rounded-sm bg-destructive text-destructive-foreground hover:opacity-90 w-fit">
              Delete cameras.json
            </button>
          </div>
        </div>
      {/if}
    </div>

    <!-- Footer -->
    <div class="flex justify-end gap-1.5 px-3 py-2 border-t border-border">
      <button onclick={onClose}
        class="h-6 px-3 text-[10px] font-medium rounded-sm bg-secondary text-secondary-foreground hover:bg-accent">Cancel</button>
      <button onclick={handleSave} disabled={$savingAppSettings}
        class="h-6 px-3 text-[10px] font-medium rounded-sm bg-primary text-primary-foreground hover:opacity-90 disabled:opacity-40">
        {$savingAppSettings ? 'Saving...' : 'Save'}
      </button>
    </div>
  </div>
</div>
