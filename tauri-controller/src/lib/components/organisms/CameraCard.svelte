<script lang="ts">
  import type { Camera } from "$lib/types/camera";
  import Card from "../atoms/Card.svelte";
  import Button from "../atoms/Button.svelte";
  import Checkbox from "../atoms/Checkbox.svelte";
  import TelemetryBadge from "../molecules/TelemetryBadge.svelte";
  import {
    formatBattery,
    formatTemperature,
    formatBitrate,
  } from "$lib/utils/format";

  export let camera: Camera;
  export let selected = false;
  export let onToggleSelection: () => void;
  export let onStart: () => void;
  export let onStop: () => void;
  export let onCameraSettings: () => void;
  export let onStreamSettings: () => void;
  export let onAliasUpdated: (newAlias: string) => void;

  $: isStreaming = camera.status?.ndi_state === "streaming";
  $: telemetry = camera.status?.telemetry;
  $: streamDetails = camera.status?.current;
  $: droppedFrames = telemetry?.dropped_frames || 0;
  $: hasDroppedFrames = droppedFrames > 0;

  // Check if WiFi RSSI is real data (not the default -50 placeholder)
  $: hasRealWifiData =
    telemetry?.wifi_rssi !== undefined && telemetry.wifi_rssi !== -50;

  function getWifiIcon(rssi: number): string {
    if (rssi >= -50) return "📶"; // Excellent
    if (rssi >= -60) return "📶"; // Good
    if (rssi >= -70) return "📶"; // Fair
    return "📶"; // Poor
  }

  function getWifiStrength(rssi: number): string {
    if (rssi >= -50) return "Excellent";
    if (rssi >= -60) return "Good";
    if (rssi >= -70) return "Fair";
    return "Poor";
  }

  // CPU color coding
  function getCpuColor(cpuUsage: number): string {
    if (cpuUsage >= 100) return "text-red-600 dark:text-red-400 font-bold";
    if (cpuUsage > 85) return "text-orange-600 dark:text-orange-400 font-bold";
    return "";
  }

  // Temperature color coding
  function getTempColor(temp: number): string {
    if (temp > 40) return "text-red-600 dark:text-red-400 font-bold";
    return "";
  }

  function formatCpu(cpu: number): string {
    return cpu.toFixed(0) + "%";
  }

  // Alias editing
  let isEditingAlias = false;
  let editedAlias = camera.alias;
  let aliasSaving = false;
  let aliasError = "";

  function startEditingAlias() {
    isEditingAlias = true;
    editedAlias = camera.alias;
    aliasError = "";
  }

  function cancelEditingAlias() {
    isEditingAlias = false;
    editedAlias = camera.alias;
    aliasError = "";
  }

  async function saveAlias() {
    const trimmed = editedAlias.trim();
    if (!trimmed || trimmed.length > 64) {
      aliasError = "Alias must be 1-64 characters";
      return;
    }

    aliasSaving = true;
    aliasError = "";

    try {
      // Step 1: Update alias on iOS device via API
      const response = await fetch(`http://${camera.ip}:${camera.port}/api/v1/settings/alias`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ alias: trimmed })
      });

      if (!response.ok) {
        const error = await response.json();
        throw new Error(error.message || 'Failed to update alias');
      }

      const result = await response.json();

      // Step 2: Update alias in Tauri backend (updates cameras.json)
      const { invoke } = await import('@tauri-apps/api/core');
      await invoke('update_camera_alias', {
        cameraId: camera.id,
        alias: result.alias
      });

      // Step 3: Notify parent to refresh UI
      onAliasUpdated(result.alias);
      isEditingAlias = false;
    } catch (e) {
      aliasError = e instanceof Error ? e.message : 'Failed to update alias';
    } finally {
      aliasSaving = false;
    }
  }
</script>

<Card padding="md" interactive>
  <div class="flex flex-col gap-4">
    <!-- Header -->
    <div class="flex items-center gap-3">
      <Checkbox
        bind:checked={selected}
        on:change={onToggleSelection}
        label="Select camera"
      />
      {#if isEditingAlias}
        <div class="flex-1 flex flex-col gap-2">
          <div class="flex gap-2">
            <input
              type="text"
              bind:value={editedAlias}
              class="flex-1 px-3 py-1.5 text-sm border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-800 text-gray-900 dark:text-gray-100"
              placeholder="Camera name"
              maxlength="64"
              disabled={aliasSaving}
            />
            <button
              on:click={saveAlias}
              disabled={aliasSaving}
              class="px-3 py-1.5 text-sm font-medium text-white bg-blue-600 hover:bg-blue-700 disabled:bg-blue-400 rounded-md"
            >
              {aliasSaving ? '⏳' : '✓'}
            </button>
            <button
              on:click={cancelEditingAlias}
              disabled={aliasSaving}
              class="px-3 py-1.5 text-sm font-medium text-gray-700 dark:text-gray-300 bg-gray-200 dark:bg-gray-700 hover:bg-gray-300 dark:hover:bg-gray-600 disabled:opacity-50 rounded-md"
            >
              ✕
            </button>
          </div>
          {#if aliasError}
            <span class="text-xs text-red-600 dark:text-red-400">{aliasError}</span>
          {/if}
        </div>
      {:else}
        <h3
          class="flex-1 text-base font-semibold text-gray-900 dark:text-gray-100 group cursor-pointer"
          on:click={startEditingAlias}
          title="Click to edit camera name"
        >
          {camera.alias}
          <span class="ml-2 text-gray-400 opacity-0 group-hover:opacity-100 transition-opacity">✏️</span>
        </h3>
      {/if}
    </div>

    <!-- Info -->
    <div class="flex items-center justify-between text-sm">
      <span class="text-gray-600 dark:text-gray-400"
        >{camera.ip}:{camera.port}</span
      >
      <span
        class="inline-flex items-center gap-1.5 rounded-full px-2.5 py-0.5 text-xs font-medium {isStreaming
          ? 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400'
          : 'bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-400'}"
      >
        {#if isStreaming}
          <span
            class="h-1.5 w-1.5 rounded-full bg-green-500 dark:bg-green-400"
          />
        {/if}
        {camera.status?.ndi_state || "unknown"}
      </span>
    </div>

    <!-- Telemetry -->
    {#if telemetry}
      <div class="flex items-center gap-3">
        <div
          class="flex-1 grid grid-cols-4 gap-3 rounded-lg bg-gray-50 p-3 dark:bg-gray-800/50"
        >
          <div class="flex flex-col gap-1">
            <span class="text-xs font-medium text-gray-500 dark:text-gray-400">Battery</span>
            <span class="text-sm font-semibold text-gray-900 dark:text-white">
              {#if telemetry.charging_state === 'charging' || telemetry.charging_state === 'full'}⚡{/if}{formatBattery(telemetry.battery)}
            </span>
          </div>
          <div class="flex flex-col gap-1">
            <span class="text-xs font-medium text-gray-500 dark:text-gray-400">Temp</span>
            <span class="text-sm font-semibold text-gray-900 dark:text-white {getTempColor(telemetry.temp_c)}">
              {#if telemetry.temp_c > 40}🔥{/if}
              {formatTemperature(telemetry.temp_c)}
            </span>
          </div>
          <div class="flex flex-col gap-1">
            <span class="text-xs font-medium text-gray-500 dark:text-gray-400">CPU</span>
            <span class="text-sm font-semibold text-gray-900 dark:text-white {getCpuColor(telemetry.cpu_usage)}">
              {formatCpu(telemetry.cpu_usage)}
            </span>
          </div>
          <TelemetryBadge
            label="Bitrate"
            unity="Mbps"
            value={formatBitrate(telemetry.bitrate)}
          />
        </div>
        {#if hasDroppedFrames}
          <div
            class="flex items-center gap-2 rounded-lg bg-yellow-50 px-3 py-2 dark:bg-yellow-900/20"
            title="{droppedFrames} frames dropped"
          >
            <svg
              class="h-4 w-4 text-yellow-600 dark:text-yellow-400"
              fill="currentColor"
              viewBox="0 0 20 20"
            >
              <path
                fill-rule="evenodd"
                d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z"
                clip-rule="evenodd"
              />
            </svg>
            <span
              class="text-sm font-medium text-yellow-700 dark:text-yellow-300"
              >{droppedFrames} dropped</span
            >
          </div>
        {/if}
      </div>
    {/if}

    <!-- Stream Details -->
    {#if streamDetails && isStreaming}
      <div
        class="rounded-lg border border-gray-200 bg-white p-3 dark:border-gray-700 dark:bg-gray-900"
      >
        <div class="flex items-center justify-between text-sm">
          <span class="font-medium text-gray-700 dark:text-gray-300"
            >Stream:</span
          >
          <span class="font-mono text-gray-900 dark:text-gray-100">
            {streamDetails.resolution || "N/A"} @ {streamDetails.fps ||
              "N/A"}fps ({streamDetails.codec?.toUpperCase() || "N/A"})
          </span>
        </div>
      </div>
    {/if}

    <!-- WiFi Strength (only show if we have real data, not default -50) -->
    {#if hasRealWifiData && telemetry?.wifi_rssi}
      <div
        class="rounded-lg border border-gray-200 bg-white p-2 dark:border-gray-700 dark:bg-gray-900"
      >
        <div class="flex items-center justify-between text-sm">
          <span class="text-gray-700 dark:text-gray-300">WiFi:</span>
          <div class="flex items-center gap-2">
            <span class="text-lg">{getWifiIcon(telemetry.wifi_rssi)}</span>
            <span class="font-medium text-gray-900 dark:text-gray-100">
              {getWifiStrength(telemetry.wifi_rssi)} ({telemetry.wifi_rssi} dBm)
            </span>
          </div>
        </div>
      </div>
    {/if}

    <!-- Controls -->
    {#if camera.status}
      <div class="flex flex-col gap-2">
        <!-- Streaming Controls -->
        <div class="flex gap-2">
          {#if isStreaming}
            <Button
              variant="secondary"
              size="sm"
              on:click={onStop}
              class="flex-1"
            >
              <svg class="h-3.5 w-3.5" fill="currentColor" viewBox="0 0 24 24">
                <rect x="6" y="6" width="12" height="12" />
              </svg>
              Stop
            </Button>
          {:else}
            <Button
              variant="primary"
              size="sm"
              on:click={onStart}
              class="flex-1"
            >
              <svg class="h-3.5 w-3.5" fill="currentColor" viewBox="0 0 24 24">
                <path d="M8 5v14l11-7z" />
              </svg>
              Start
            </Button>
          {/if}
        </div>

        <!-- Settings Controls -->
        <div class="flex gap-2">
          <Button
            variant="secondary"
            size="sm"
            on:click={onCameraSettings}
            class="flex-1"
          >
            <svg
              class="h-3.5 w-3.5"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M3 9a2 2 0 012-2h.93a2 2 0 001.664-.89l.812-1.22A2 2 0 0110.07 4h3.86a2 2 0 011.664.89l.812 1.22A2 2 0 0018.07 7H19a2 2 0 012 2v9a2 2 0 01-2 2H5a2 2 0 01-2-2V9z"
              />
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M15 13a3 3 0 11-6 0 3 3 0 016 0z"
              />
            </svg>
            Camera
          </Button>
          <Button
            variant="secondary"
            size="sm"
            on:click={onStreamSettings}
            class="flex-1"
          >
            <svg
              class="h-3.5 w-3.5"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z"
              />
            </svg>
            Stream
          </Button>
        </div>
      </div>
    {:else}
      <p
        class="py-2 text-center text-sm font-medium italic text-red-600 dark:text-red-400"
      >
        Disconnected
      </p>
    {/if}
  </div>
</Card>
