<script>
  import { invoke } from '@tauri-apps/api/core';
  import { onMount, onDestroy } from 'svelte';

  // State
  let cameras = [];
  let selectedCameras = new Set();
  let loading = true;
  let error = null;

  // Manual add dialog
  let showAddDialog = false;
  let manualIp = '';
  let manualPort = 8888;
  let manualToken = '';

  // Refresh cameras periodically
  let refreshInterval;

  onMount(async () => {
    await refreshCameras();
    refreshInterval = setInterval(refreshCameras, 2000); // Refresh every 2 seconds
  });

  onDestroy(() => {
    if (refreshInterval) {
      clearInterval(refreshInterval);
    }
  });

  // MARK: - Camera Management

  async function refreshCameras() {
    try {
      cameras = await invoke('get_cameras');
      error = null;
    } catch (e) {
      error = e;
      console.error('Failed to get cameras:', e);
    } finally {
      loading = false;
    }
  }

  async function addCameraManual() {
    try {
      await invoke('add_camera_manual', {
        ip: manualIp,
        port: manualPort,
        token: manualToken
      });
      showAddDialog = false;
      manualIp = '';
      manualToken = '';
      await refreshCameras();
    } catch (e) {
      alert(`Failed to add camera: ${e}`);
    }
  }

  async function removeCamera(cameraId) {
    if (!confirm('Remove this camera?')) return;

    try {
      await invoke('remove_camera', { cameraId });
      selectedCameras.delete(cameraId);
      await refreshCameras();
    } catch (e) {
      alert(`Failed to remove camera: ${e}`);
    }
  }

  // MARK: - Single Camera Controls

  async function startStream(cameraId) {
    try {
      await invoke('start_stream', {
        cameraId,
        resolution: '1920x1080',
        framerate: 30,
        bitrate: 10000000,
        codec: 'h264'
      });
      await refreshCameras();
    } catch (e) {
      alert(`Failed to start stream: ${e}`);
    }
  }

  async function stopStream(cameraId) {
    try {
      await invoke('stop_stream', { cameraId });
      await refreshCameras();
    } catch (e) {
      alert(`Failed to stop stream: ${e}`);
    }
  }

  async function forceKeyframe(cameraId) {
    try {
      await invoke('force_keyframe', { cameraId });
    } catch (e) {
      alert(`Failed to force keyframe: ${e}`);
    }
  }

  // MARK: - Camera Settings

  let showSettingsDialog = false;
  let settingsCameraId = null;
  let cameraSettings = {
    wb_mode: 'auto',
    wb_kelvin: 5000,
    iso_mode: 'auto',
    iso: 400,
    shutter_mode: 'auto',
    shutter_s: 0.01,
    zoom_factor: 1.0
  };

  function openSettings(cameraId) {
    settingsCameraId = cameraId;
    showSettingsDialog = true;
  }

  async function updateSettings() {
    if (!settingsCameraId) return;

    try {
      // Build settings object with only non-null values
      const settings = {};
      if (cameraSettings.wb_mode) settings.wb_mode = cameraSettings.wb_mode;
      if (cameraSettings.wb_mode === 'manual' && cameraSettings.wb_kelvin) {
        settings.wb_kelvin = parseInt(cameraSettings.wb_kelvin);
      }
      if (cameraSettings.iso_mode) settings.iso_mode = cameraSettings.iso_mode;
      if (cameraSettings.iso_mode === 'manual' && cameraSettings.iso) {
        settings.iso = parseInt(cameraSettings.iso);
      }
      if (cameraSettings.shutter_mode) settings.shutter_mode = cameraSettings.shutter_mode;
      if (cameraSettings.shutter_mode === 'manual' && cameraSettings.shutter_s) {
        settings.shutter_s = parseFloat(cameraSettings.shutter_s);
      }
      if (cameraSettings.zoom_factor) settings.zoom_factor = parseFloat(cameraSettings.zoom_factor);

      await invoke('update_camera_settings', {
        cameraId: settingsCameraId,
        settings
      });
      showSettingsDialog = false;
      await refreshCameras();
    } catch (e) {
      alert(`Failed to update settings: ${e}`);
    }
  }

  // MARK: - Group Controls

  async function groupStartStream() {
    const ids = Array.from(selectedCameras);
    if (ids.length === 0) {
      alert('No cameras selected');
      return;
    }

    try {
      const results = await invoke('group_start_stream', {
        cameraIds: ids,
        resolution: '1920x1080',
        framerate: 30,
        bitrate: 10000000,
        codec: 'h264'
      });

      // Show results
      const failures = results.filter(r => !r.success);
      if (failures.length > 0) {
        alert(`Failed for ${failures.length} cameras:\n` + failures.map(f => f.error).join('\n'));
      }

      await refreshCameras();
    } catch (e) {
      alert(`Group start failed: ${e}`);
    }
  }

  async function groupStopStream() {
    const ids = Array.from(selectedCameras);
    if (ids.length === 0) {
      alert('No cameras selected');
      return;
    }

    try {
      await invoke('group_stop_stream', { cameraIds: ids });
      await refreshCameras();
    } catch (e) {
      alert(`Group stop failed: ${e}`);
    }
  }

  // MARK: - Selection

  function toggleSelection(cameraId) {
    if (selectedCameras.has(cameraId)) {
      selectedCameras.delete(cameraId);
    } else {
      selectedCameras.add(cameraId);
    }
    selectedCameras = selectedCameras; // Trigger reactivity
  }

  function formatBitrate(bitrate) {
    return (bitrate / 1000000).toFixed(1) + ' Mbps';
  }

  function formatShutterSpeed(seconds) {
    if (seconds >= 1) {
      return seconds.toFixed(1) + 's';
    } else {
      return '1/' + Math.round(1.0 / seconds);
    }
  }
</script>

<main>
  <header>
    <h1>🎥 AvoCam Controller</h1>
    <div class="header-actions">
      <button on:click={() => showAddDialog = true}>+ Add Camera</button>
      <button on:click={refreshCameras}>🔄 Refresh</button>
    </div>
  </header>

  {#if error}
    <div class="error">
      Error: {error}
    </div>
  {/if}

  {#if loading}
    <div class="loading">Loading cameras...</div>
  {:else if cameras.length === 0}
    <div class="empty">
      <p>No cameras found</p>
      <p>Add a camera manually or ensure cameras are on the same network</p>
    </div>
  {:else}
    <!-- Group Controls -->
    {#if selectedCameras.size > 0}
      <div class="group-controls">
        <h3>Group Control ({selectedCameras.size} selected)</h3>
        <div class="group-buttons">
          <button class="primary" on:click={groupStartStream}>▶️ Start All</button>
          <button on:click={groupStopStream}>⏹ Stop All</button>
        </div>
      </div>
    {/if}

    <!-- Camera Grid -->
    <div class="camera-grid">
      {#each cameras as camera (camera.id)}
        <div class="camera-card" class:selected={selectedCameras.has(camera.id)}>
          <div class="camera-header">
            <input
              type="checkbox"
              checked={selectedCameras.has(camera.id)}
              on:change={() => toggleSelection(camera.id)}
            />
            <h3>{camera.alias}</h3>
            <button class="remove" on:click={() => removeCamera(camera.id)}>✕</button>
          </div>

          <div class="camera-info">
            <p><strong>IP:</strong> {camera.ip}:{camera.port}</p>
            <p><strong>State:</strong>
              <span class:streaming={camera.status?.ndi_state === 'streaming'}>
                {camera.status?.ndi_state || 'unknown'}
              </span>
            </p>
          </div>

          {#if camera.status}
            <div class="telemetry">
              <div class="telemetry-item">
                <span>FPS</span>
                <strong>{camera.status.telemetry.fps.toFixed(1)}</strong>
              </div>
              <div class="telemetry-item">
                <span>Bitrate</span>
                <strong>{formatBitrate(camera.status.telemetry.bitrate)}</strong>
              </div>
              <div class="telemetry-item">
                <span>Battery</span>
                <strong>{(camera.status.telemetry.battery * 100).toFixed(0)}%</strong>
              </div>
              <div class="telemetry-item">
                <span>Temp</span>
                <strong>{camera.status.telemetry.temp_c.toFixed(1)}°C</strong>
              </div>
            </div>

            <div class="camera-controls">
              {#if camera.status.ndi_state === 'streaming'}
                <button on:click={() => stopStream(camera.id)}>⏹ Stop</button>
                <button on:click={() => forceKeyframe(camera.id)} title="Force IDR keyframe">🔑</button>
              {:else}
                <button class="primary" on:click={() => startStream(camera.id)}>▶️ Start</button>
              {/if}
              <button on:click={() => openSettings(camera.id)} title="Camera Settings">⚙️</button>
            </div>
          {:else}
            <p class="disconnected">Disconnected</p>
          {/if}
        </div>
      {/each}
    </div>
  {/if}

  <!-- Add Camera Dialog -->
  {#if showAddDialog}
    <div class="dialog-overlay" on:click={() => showAddDialog = false}>
      <div class="dialog" on:click|stopPropagation>
        <h2>Add Camera Manually</h2>
        <form on:submit|preventDefault={addCameraManual}>
          <label>
            IP Address:
            <input type="text" bind:value={manualIp} placeholder="192.168.1.100" required />
          </label>
          <label>
            Port:
            <input type="number" bind:value={manualPort} required />
          </label>
          <label>
            Bearer Token:
            <input type="text" bind:value={manualToken} placeholder="Token from iPhone" required />
          </label>
          <div class="dialog-buttons">
            <button type="submit" class="primary">Add</button>
            <button type="button" on:click={() => showAddDialog = false}>Cancel</button>
          </div>
        </form>
      </div>
    </div>
  {/if}

  <!-- Camera Settings Dialog -->
  {#if showSettingsDialog}
    <div class="dialog-overlay" on:click={() => showSettingsDialog = false}>
      <div class="dialog" on:click|stopPropagation>
        <h2>Camera Settings</h2>
        <form on:submit|preventDefault={updateSettings}>
          <label>
            White Balance Mode:
            <select bind:value={cameraSettings.wb_mode}>
              <option value="auto">Auto</option>
              <option value="manual">Manual</option>
            </select>
          </label>
          {#if cameraSettings.wb_mode === 'manual'}
            <label>
              White Balance (Kelvin):
              <input type="number" bind:value={cameraSettings.wb_kelvin} min="2000" max="10000" step="100" />
            </label>
          {/if}
          <label>
            ISO Mode:
            <select bind:value={cameraSettings.iso_mode}>
              <option value="auto">Auto</option>
              <option value="manual">Manual</option>
            </select>
          </label>
          {#if cameraSettings.iso_mode === 'manual'}
            <label>
              ISO Value:
              <input type="number" bind:value={cameraSettings.iso} min="50" max="3200" step="50" />
            </label>
          {/if}
          <label>
            Shutter Speed Mode:
            <select bind:value={cameraSettings.shutter_mode}>
              <option value="auto">Auto</option>
              <option value="manual">Manual</option>
            </select>
          </label>
          {#if cameraSettings.shutter_mode === 'manual'}
            <label>
              Shutter Speed:
              <input type="range" bind:value={cameraSettings.shutter_s} min="0.001" max="0.1" step="0.001" />
              <small>{formatShutterSpeed(cameraSettings.shutter_s)}</small>
            </label>
          {/if}
          <label>
            Zoom Factor:
            <input type="number" bind:value={cameraSettings.zoom_factor} min="1.0" max="10.0" step="0.1" />
          </label>
          <div class="dialog-buttons">
            <button type="submit" class="primary">Apply</button>
            <button type="button" on:click={() => showSettingsDialog = false}>Cancel</button>
          </div>
        </form>
      </div>
    </div>
  {/if}
</main>

<style>
  :global(body) {
    margin: 0;
    padding: 0;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
    background: #f5f5f5;
  }

  main {
    padding: 20px;
    max-width: 1400px;
    margin: 0 auto;
  }

  header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 30px;
  }

  h1 {
    margin: 0;
    font-size: 28px;
  }

  .header-actions {
    display: flex;
    gap: 10px;
  }

  button {
    padding: 8px 16px;
    border: 1px solid #ddd;
    border-radius: 6px;
    background: white;
    cursor: pointer;
    font-size: 14px;
  }

  button:hover {
    background: #f9f9f9;
  }

  button.primary {
    background: #007aff;
    color: white;
    border-color: #007aff;
  }

  button.primary:hover {
    background: #0056b3;
  }

  .loading, .empty, .error {
    text-align: center;
    padding: 40px;
    color: #666;
  }

  .error {
    background: #fee;
    color: #c00;
    border-radius: 8px;
  }

  .group-controls {
    background: white;
    padding: 20px;
    border-radius: 8px;
    margin-bottom: 20px;
    box-shadow: 0 2px 4px rgba(0,0,0,0.1);
  }

  .group-controls h3 {
    margin: 0 0 15px 0;
  }

  .group-buttons {
    display: flex;
    gap: 10px;
  }

  .camera-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(320px, 1fr));
    gap: 20px;
  }

  .camera-card {
    background: white;
    border-radius: 8px;
    padding: 20px;
    box-shadow: 0 2px 4px rgba(0,0,0,0.1);
    transition: box-shadow 0.2s;
  }

  .camera-card:hover {
    box-shadow: 0 4px 8px rgba(0,0,0,0.15);
  }

  .camera-card.selected {
    border: 2px solid #007aff;
  }

  .camera-header {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-bottom: 15px;
  }

  .camera-header h3 {
    flex: 1;
    margin: 0;
    font-size: 18px;
  }

  .camera-header .remove {
    padding: 4px 8px;
    background: #fee;
    color: #c00;
    border-color: #fcc;
  }

  .camera-info {
    margin-bottom: 15px;
    font-size: 14px;
  }

  .camera-info p {
    margin: 5px 0;
  }

  .streaming {
    color: #0a0;
    font-weight: bold;
  }

  .telemetry {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 10px;
    margin-bottom: 15px;
  }

  .telemetry-item {
    display: flex;
    flex-direction: column;
    font-size: 12px;
  }

  .telemetry-item span {
    color: #666;
  }

  .telemetry-item strong {
    font-size: 18px;
    font-family: monospace;
  }

  .camera-controls {
    display: flex;
    gap: 10px;
  }

  .camera-controls button {
    flex: 1;
  }

  .disconnected {
    color: #c00;
    font-style: italic;
  }

  .dialog-overlay {
    position: fixed;
    top: 0;
    left: 0;
    right: 0;
    bottom: 0;
    background: rgba(0,0,0,0.5);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 1000;
  }

  .dialog {
    background: white;
    padding: 30px;
    border-radius: 12px;
    max-width: 400px;
    width: 90%;
  }

  .dialog h2 {
    margin: 0 0 20px 0;
  }

  .dialog label {
    display: block;
    margin-bottom: 15px;
    font-size: 14px;
    font-weight: 500;
  }

  .dialog input, .dialog select {
    display: block;
    width: 100%;
    padding: 8px;
    margin-top: 5px;
    border: 1px solid #ddd;
    border-radius: 4px;
    font-size: 14px;
    box-sizing: border-box;
  }

  .dialog small {
    display: block;
    margin-top: 5px;
    color: #666;
    font-size: 12px;
  }

  .dialog-buttons {
    display: flex;
    gap: 10px;
    margin-top: 20px;
  }

  .dialog-buttons button {
    flex: 1;
  }
</style>
