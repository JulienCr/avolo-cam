<script lang="ts">
  import { appSettings, saveAppSettings, deleteCamerasData, savingAppSettings } from '$lib/stores/appSettings';
  import { refreshCameras } from '$lib/stores/cameras';
  import Button from '../atoms/Button.svelte';
  import Card from '../atoms/Card.svelte';

  export let onClose: () => void;

  let temperatureEnabled = $appSettings.alerts.temperature.enabled;
  let temperatureThreshold = $appSettings.alerts.temperature.temperatureThreshold;
  let cpuEnabled = $appSettings.alerts.cpu.enabled;
  let cpuThreshold = $appSettings.alerts.cpu.cpuThreshold;

  async function handleSave() {
    try {
      await saveAppSettings({
        alerts: {
          temperature: {
            enabled: temperatureEnabled,
            temperatureThreshold,
          },
          cpu: {
            enabled: cpuEnabled,
            cpuThreshold,
          },
        },
      });
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
      } catch (e) {
        alert('Failed to delete camera data: ' + e);
      }
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
      <h3 class="mb-4 text-lg font-semibold text-gray-900 dark:text-gray-100">🔔 Alerts</h3>

      <!-- Temperature Alert -->
      <div class="mb-4 rounded-lg border border-gray-200 p-4 dark:border-gray-700">
        <div class="mb-3 flex items-center justify-between">
          <label class="flex items-center gap-2">
            <input
              type="checkbox"
              bind:checked={temperatureEnabled}
              class="h-4 w-4 rounded border-gray-300 text-blue-600 focus:ring-blue-500"
            />
            <span class="text-sm font-medium text-gray-900 dark:text-gray-100">
              Temperature Alert
            </span>
          </label>
        </div>
        <div class="flex items-center gap-3">
          <label class="text-sm text-gray-600 dark:text-gray-400">Threshold:</label>
          <input
            type="number"
            bind:value={temperatureThreshold}
            disabled={!temperatureEnabled}
            min="30"
            max="60"
            class="w-20 rounded-lg border border-gray-300 px-3 py-2 text-sm disabled:bg-gray-100 disabled:text-gray-400 dark:border-gray-600 dark:bg-gray-800 dark:text-white dark:disabled:bg-gray-700"
          />
          <span class="text-sm text-gray-600 dark:text-gray-400">°C</span>
        </div>
        <p class="mt-2 text-xs text-gray-500 dark:text-gray-400">
          Get notified when camera temperature exceeds this value
        </p>
      </div>

      <!-- CPU Alert -->
      <div class="mb-4 rounded-lg border border-gray-200 p-4 dark:border-gray-700">
        <div class="mb-3 flex items-center justify-between">
          <label class="flex items-center gap-2">
            <input
              type="checkbox"
              bind:checked={cpuEnabled}
              class="h-4 w-4 rounded border-gray-300 text-blue-600 focus:ring-blue-500"
            />
            <span class="text-sm font-medium text-gray-900 dark:text-gray-100">
              CPU Alert
            </span>
          </label>
        </div>
        <div class="flex items-center gap-3">
          <label class="text-sm text-gray-600 dark:text-gray-400">Threshold:</label>
          <input
            type="number"
            bind:value={cpuThreshold}
            disabled={!cpuEnabled}
            min="50"
            max="200"
            class="w-20 rounded-lg border border-gray-300 px-3 py-2 text-sm disabled:bg-gray-100 disabled:text-gray-400 dark:border-gray-600 dark:bg-gray-800 dark:text-white dark:disabled:bg-gray-700"
          />
          <span class="text-sm text-gray-600 dark:text-gray-400">%</span>
        </div>
        <p class="mt-2 text-xs text-gray-500 dark:text-gray-400">
          Get notified when camera CPU usage exceeds this value
        </p>
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
