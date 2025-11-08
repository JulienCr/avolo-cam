<script lang="ts">
  import { onMount } from 'svelte';
  import { appSettings, saveAppSettings, deleteCamerasData, savingAppSettings } from '$lib/stores/appSettings';
  import { refreshCameras } from '$lib/stores/cameras';
  import Button from '../atoms/Button.svelte';
  import Card from '../atoms/Card.svelte';
  import { invoke } from '@tauri-apps/api/core';

  export let onClose: () => void;

  let temperatureEnabled = $appSettings.alerts.temperature.enabled;
  let temperatureThreshold = $appSettings.alerts.temperature.temperatureThreshold;
  let cpuEnabled = $appSettings.alerts.cpu.enabled;
  let cpuThreshold = $appSettings.alerts.cpu.cpuThreshold;
  let batteryLowEnabled = $appSettings.alerts.batteryLow.enabled;
  let batteryLowThreshold = $appSettings.alerts.batteryLow.batteryLowThreshold;
  let batteryCriticalEnabled = $appSettings.alerts.batteryCritical.enabled;
  let batteryCriticalThreshold = $appSettings.alerts.batteryCritical.batteryCriticalThreshold;

  let notificationPermissionGranted = false;
  let checkingPermission = true;
  let requestingPermission = false;

  const testMessages = [
    { title: 'Test Notification', body: 'Notifications are working!' },
    { title: 'Alert Test', body: 'This is a test alert from AvoCam Controller' },
    { title: 'System Check', body: 'Notification system is operational' },
    { title: 'Camera Alert', body: 'Test: Camera #1 temperature is high' },
    { title: 'Battery Warning', body: 'Test: Camera #2 battery is low' },
  ];

  onMount(async () => {
    await checkNotificationPermission();
  });

  async function checkNotificationPermission() {
    try {
      checkingPermission = true;
      notificationPermissionGranted = await invoke<boolean>('check_notification_permission');
    } catch (e) {
      console.error('Failed to check notification permission:', e);
    } finally {
      checkingPermission = false;
    }
  }

  async function requestNotificationPermission() {
    try {
      requestingPermission = true;
      notificationPermissionGranted = await invoke<boolean>('request_notification_permission');
      if (notificationPermissionGranted) {
        alert('Notification permission granted!');
      } else {
        alert('Notification permission was denied. Please enable it in your system settings.');
      }
    } catch (e) {
      alert('Failed to request notification permission: ' + e);
    } finally {
      requestingPermission = false;
    }
  }

  async function handleSave() {
    try {
      await saveAppSettings({
        alerts: {
          temperature: {
            enabled: temperatureEnabled,
            temperatureThreshold,
            cpuThreshold: 0,
            batteryLowThreshold: 0,
            batteryCriticalThreshold: 0,
          },
          cpu: {
            enabled: cpuEnabled,
            temperatureThreshold: 0,
            cpuThreshold,
            batteryLowThreshold: 0,
            batteryCriticalThreshold: 0,
          },
          batteryLow: {
            enabled: batteryLowEnabled,
            temperatureThreshold: 0,
            cpuThreshold: 0,
            batteryLowThreshold,
            batteryCriticalThreshold: 0,
          },
          batteryCritical: {
            enabled: batteryCriticalEnabled,
            temperatureThreshold: 0,
            cpuThreshold: 0,
            batteryLowThreshold: 0,
            batteryCriticalThreshold,
          },
        },
      });
      alert('Settings saved successfully!');
      onClose();
    } catch (e) {
      alert('Failed to save settings: ' + e);
    }
  }

  async function handleDeleteCameras() {
    if (confirm('Are you sure you want to delete all saved camera data? This will remove all cameras and you will need to discover them again.')) {
      try {
        await deleteCamerasData();
        await refreshCameras();
        alert('Camera data deleted successfully. The app will now rediscover cameras.');
        onClose();
      } catch (e) {
        alert('Failed to delete camera data: ' + e);
      }
    }
  }

  async function handleTestNotification() {
    try {
      console.log('Test notification clicked, permission:', notificationPermissionGranted);

      if (!notificationPermissionGranted) {
        alert('Notification permission not granted. Please enable notifications first.');
        return;
      }

      const randomMessage = testMessages[Math.floor(Math.random() * testMessages.length)];
      console.log('Sending notification:', randomMessage);

      await invoke('send_test_notification', {
        title: randomMessage.title,
        body: randomMessage.body
      });

      console.log('Notification sent successfully');
    } catch (e) {
      console.error('Notification error:', e);
      alert('Failed to send test notification: ' + e);
    }
  }
</script>

<div class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
  <Card padding="lg" class="w-full max-w-2xl max-h-[90vh] overflow-y-auto">
    <div class="mb-6 flex items-center justify-between">
      <h2 class="text-2xl font-bold text-gray-900 dark:text-gray-100">⚙️ Settings</h2>
      <button
        on:click={onClose}
        class="rounded-lg p-2 text-gray-400 hover:bg-gray-100 hover:text-gray-600 dark:hover:bg-gray-800 dark:hover:text-gray-200"
      >
        <svg class="h-6 w-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
        </svg>
      </button>
    </div>

    <!-- Alerts Section -->
    <div class="mb-6">
      <h3 class="mb-3 text-lg font-semibold text-gray-900 dark:text-gray-100">🔔 Alerts</h3>

      <!-- Permission Warning (only if not granted) -->
      {#if !checkingPermission && !notificationPermissionGranted}
        <div class="mb-3 rounded-lg border border-orange-200 bg-orange-50 p-3 dark:border-orange-800 dark:bg-orange-950">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-2">
              <span class="text-orange-600 dark:text-orange-400">⚠ Notification permission not granted</span>
            </div>
            <Button
              variant="primary"
              size="sm"
              on:click={requestNotificationPermission}
              disabled={requestingPermission}
            >
              {requestingPermission ? 'Requesting...' : 'Enable'}
            </Button>
          </div>
        </div>
      {/if}

      <!-- Compact Alert Grid -->
      <div class="space-y-2">
        <!-- Temperature Alert -->
        <div class="flex items-center gap-3 rounded-lg border border-gray-200 p-2 dark:border-gray-700">
          <label class="flex items-center gap-2 min-w-[140px]">
            <input
              type="checkbox"
              bind:checked={temperatureEnabled}
              class="h-4 w-4 rounded border-gray-300 text-blue-600 focus:ring-blue-500"
            />
            <span class="text-sm font-medium text-gray-900 dark:text-gray-100">Temperature</span>
          </label>
          <div class="flex items-center gap-2 flex-1">
            <span class="text-xs text-gray-600 dark:text-gray-400">&gt;</span>
            <input
              type="number"
              bind:value={temperatureThreshold}
              disabled={!temperatureEnabled}
              min="30"
              max="60"
              class="w-16 rounded border border-gray-300 px-2 py-1 text-sm disabled:bg-gray-100 disabled:text-gray-400 dark:border-gray-600 dark:bg-gray-800 dark:text-white dark:disabled:bg-gray-700"
            />
            <span class="text-xs text-gray-600 dark:text-gray-400">°C</span>
          </div>
        </div>

        <!-- CPU Alert -->
        <div class="flex items-center gap-3 rounded-lg border border-gray-200 p-2 dark:border-gray-700">
          <label class="flex items-center gap-2 min-w-[140px]">
            <input
              type="checkbox"
              bind:checked={cpuEnabled}
              class="h-4 w-4 rounded border-gray-300 text-blue-600 focus:ring-blue-500"
            />
            <span class="text-sm font-medium text-gray-900 dark:text-gray-100">CPU</span>
          </label>
          <div class="flex items-center gap-2 flex-1">
            <span class="text-xs text-gray-600 dark:text-gray-400">&gt;</span>
            <input
              type="number"
              bind:value={cpuThreshold}
              disabled={!cpuEnabled}
              min="50"
              max="200"
              class="w-16 rounded border border-gray-300 px-2 py-1 text-sm disabled:bg-gray-100 disabled:text-gray-400 dark:border-gray-600 dark:bg-gray-800 dark:text-white dark:disabled:bg-gray-700"
            />
            <span class="text-xs text-gray-600 dark:text-gray-400">%</span>
          </div>
        </div>

        <!-- Battery Low Alert -->
        <div class="flex items-center gap-3 rounded-lg border border-gray-200 p-2 dark:border-gray-700">
          <label class="flex items-center gap-2 min-w-[140px]">
            <input
              type="checkbox"
              bind:checked={batteryLowEnabled}
              class="h-4 w-4 rounded border-gray-300 text-blue-600 focus:ring-blue-500"
            />
            <span class="text-sm font-medium text-gray-900 dark:text-gray-100">Battery Low</span>
          </label>
          <div class="flex items-center gap-2 flex-1">
            <span class="text-xs text-gray-600 dark:text-gray-400">&lt;</span>
            <input
              type="number"
              bind:value={batteryLowThreshold}
              disabled={!batteryLowEnabled}
              min="10"
              max="50"
              class="w-16 rounded border border-gray-300 px-2 py-1 text-sm disabled:bg-gray-100 disabled:text-gray-400 dark:border-gray-600 dark:bg-gray-800 dark:text-white dark:disabled:bg-gray-700"
            />
            <span class="text-xs text-gray-600 dark:text-gray-400">%</span>
          </div>
        </div>

        <!-- Battery Critical Alert -->
        <div class="flex items-center gap-3 rounded-lg border border-gray-200 p-2 dark:border-gray-700">
          <label class="flex items-center gap-2 min-w-[140px]">
            <input
              type="checkbox"
              bind:checked={batteryCriticalEnabled}
              class="h-4 w-4 rounded border-gray-300 text-blue-600 focus:ring-blue-500"
            />
            <span class="text-sm font-medium text-gray-900 dark:text-gray-100">Battery Critical</span>
          </label>
          <div class="flex items-center gap-2 flex-1">
            <span class="text-xs text-gray-600 dark:text-gray-400">&lt;</span>
            <input
              type="number"
              bind:value={batteryCriticalThreshold}
              disabled={!batteryCriticalEnabled}
              min="5"
              max="25"
              class="w-16 rounded border border-gray-300 px-2 py-1 text-sm disabled:bg-gray-100 disabled:text-gray-400 dark:border-gray-600 dark:bg-gray-800 dark:text-white dark:disabled:bg-gray-700"
            />
            <span class="text-xs text-gray-600 dark:text-gray-400">%</span>
          </div>
        </div>
      </div>

      <!-- Test Notification -->
      <div class="flex justify-center mt-3">
        <Button
          variant="secondary"
          size="sm"
          on:click={handleTestNotification}
          disabled={!notificationPermissionGranted}
        >
          🔔 Test Notification
        </Button>
      </div>
    </div>

    <!-- Data Management Section -->
    <div class="mb-6">
      <h3 class="mb-4 text-lg font-semibold text-gray-900 dark:text-gray-100">🗄️ Data Management</h3>

      <div class="rounded-lg border border-gray-200 p-4 dark:border-gray-700">
        <div class="mb-2">
          <h4 class="text-sm font-medium text-gray-900 dark:text-gray-100">Delete Camera Data</h4>
          <p class="mt-1 text-xs text-gray-500 dark:text-gray-400">
            Remove all saved cameras from cameras.json. The app will rediscover cameras on the network.
          </p>
        </div>
        <Button
          variant="danger"
          size="sm"
          on:click={handleDeleteCameras}
          class="mt-2"
        >
          🗑️ Delete cameras.json
        </Button>
      </div>
    </div>

    <!-- Actions -->
    <div class="flex justify-end gap-2">
      <Button variant="secondary" size="md" on:click={onClose}>
        Cancel
      </Button>
      <Button
        variant="primary"
        size="md"
        on:click={handleSave}
        disabled={$savingAppSettings}
      >
        {$savingAppSettings ? 'Saving...' : 'Save Settings'}
      </Button>
    </div>
  </Card>
</div>
