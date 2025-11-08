<script>
  import { invoke } from '@tauri-apps/api/core';
  import { onMount, onDestroy } from 'svelte';

  // Utility: Debounce function
  function debounce(func, wait) {
    let timeout;
    return function executedFunction(...args) {
      const later = () => {
        clearTimeout(timeout);
        func(...args);
      };
      clearTimeout(timeout);
      timeout = setTimeout(later, wait);
    };
  }

  // State
  let cameras = [];
  let discoveredCameras = [];
  let selectedCameras = new Set();
  let loading = true;
  let discovering = false;
  let error = null;

  // Stream settings
  let streamResolution = '1920x1080';
  let streamFramerate = 30;
  let streamBitrate = 10000000;
  let streamCodec = 'h264';

  // Manual add dialog
  let showAddDialog = false;
  let manualIp = '';
  let manualPort = 8888;
  let manualToken = '';

  // Profile management
  let profiles = [];
  let showProfileDialog = false;
  let profileName = '';
  let savingProfile = false;

  // Refresh cameras periodically
  let refreshInterval;
  let discoveryInterval;

  onMount(async () => {
    await refreshCameras();
    await discoverCameras(); // Initial discovery
    await loadProfiles(); // Load saved profiles

    refreshInterval = setInterval(refreshCameras, 2000); // Refresh every 2 seconds
    discoveryInterval = setInterval(discoverCameras, 10000); // Re-discover every 10 seconds
  });

  onDestroy(() => {
    if (refreshInterval) {
      clearInterval(refreshInterval);
    }
    if (discoveryInterval) {
      clearInterval(discoveryInterval);
    }
  });

  // MARK: - Camera Management

  async function discoverCameras() {
    try {
      discovering = true;
      discoveredCameras = await invoke('discover_cameras');
      console.log('Discovered cameras:', discoveredCameras);
    } catch (e) {
      console.error('Failed to discover cameras:', e);
    } finally {
      discovering = false;
    }
  }

  async function addDiscoveredCamera(discovered) {
    // For now, we need a token. In the future, we could prompt for it or use a default
    // For testing, let's prompt the user
    const token = prompt(`Enter bearer token for ${discovered.alias}:`, '');
    if (!token) return;

    try {
      await invoke('add_camera_manual', {
        ip: discovered.ip,
        port: discovered.port,
        token: token
      });
      await refreshCameras();
      // Remove from discovered list
      discoveredCameras = discoveredCameras.filter(c => c.alias !== discovered.alias);
    } catch (e) {
      alert(`Failed to add camera: ${e}`);
    }
  }

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
        resolution: streamResolution,
        framerate: streamFramerate,
        bitrate: streamBitrate,
        codec: streamCodec
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
  let savingSettings = false;
  let cameraSettings = {
    wb_mode: 'auto',
    wb_kelvin: 5000,
    iso_mode: 'auto',
    iso: 400,
    shutter_mode: 'auto',
    shutter_s: 0.01,
    zoom_factor: 2.0,  // Device zoom (wide = 2.0)
    camera_position: 'back'
  };

  // Auto-detect lens from device zoom factor
  // Device zoom: ultra-wide=1.0, wide=2.0, telephoto=10.0
  // Thresholds: 1.5 (between 1.0 and 2.0), 6.0 (between 2.0 and 10.0)
  let selectedLens = 'wide';
  $: {
    if (cameraSettings.zoom_factor < 1.5) {
      selectedLens = 'ultra_wide';  // < 1.5x device zoom
    } else if (cameraSettings.zoom_factor >= 6.0) {
      selectedLens = 'telephoto';   // >= 6.0x device zoom
    } else {
      selectedLens = 'wide';        // 1.5x - 6.0x device zoom
    }
  }

  // Debounced settings update (300ms delay)
  const debouncedUpdateSettings = debounce(async () => {
    if (!settingsCameraId) return;

    try {
      savingSettings = true;

      // Build settings object
      const settings = {
        wb_mode: cameraSettings.wb_mode,
        iso_mode: cameraSettings.iso_mode,
        shutter_mode: cameraSettings.shutter_mode,
        zoom_factor: parseFloat(cameraSettings.zoom_factor),
        lens: selectedLens,  // Send lens parameter for physical camera switching
        camera_position: cameraSettings.camera_position
      };

      // Add manual values only when in manual mode
      if (cameraSettings.wb_mode === 'manual') {
        settings.wb_kelvin = parseInt(cameraSettings.wb_kelvin);
      }
      if (cameraSettings.iso_mode === 'manual') {
        settings.iso = parseInt(cameraSettings.iso);
      }
      if (cameraSettings.shutter_mode === 'manual') {
        settings.shutter_s = parseFloat(cameraSettings.shutter_s);
      }

      await invoke('update_camera_settings', {
        cameraId: settingsCameraId,
        settings
      });

      await refreshCameras();
      savingSettings = false;
    } catch (e) {
      console.error('Failed to update settings:', e);
      savingSettings = false;
    }
  }, 300);

  function openSettings(cameraId) {
    settingsCameraId = cameraId;

    // Load current settings from camera
    const camera = cameras.find(c => c.id === cameraId);
    if (camera && camera.status && camera.status.current) {
      const current = camera.status.current;
      cameraSettings.wb_mode = current.wb_mode || 'auto';
      cameraSettings.wb_kelvin = current.wb_kelvin || 5000;
      cameraSettings.iso_mode = current.iso_mode || 'auto';
      cameraSettings.iso = current.iso || 160;
      cameraSettings.shutter_mode = current.shutter_mode || 'auto';
      cameraSettings.shutter_s = current.shutter_s || 0.01;
      cameraSettings.zoom_factor = current.zoom_factor || 1.0;
      cameraSettings.camera_position = current.camera_position || 'back';
      cameraSettings.lens = current.lens || 'wide';
    }

    showSettingsDialog = true;
  }

  // Reactive statement: trigger debounced update when settings change
  $: if (settingsCameraId && showSettingsDialog) {
    // Watch for changes and trigger debounced update
    cameraSettings.wb_mode;
    cameraSettings.wb_kelvin;
    cameraSettings.iso_mode;
    cameraSettings.iso;
    cameraSettings.shutter_mode;
    cameraSettings.shutter_s;
    cameraSettings.zoom_factor;
    cameraSettings.camera_position;
    cameraSettings.lens;
    debouncedUpdateSettings();
  }

  // MARK: - Profile Management

  async function loadProfiles() {
    try {
      profiles = await invoke('get_profiles');
      console.log('Loaded profiles:', profiles);
    } catch (e) {
      console.error('Failed to load profiles:', e);
    }
  }

  async function saveCurrentProfile() {
    if (!profileName.trim()) {
      alert('Please enter a profile name');
      return;
    }

    try {
      savingProfile = true;
      await invoke('save_profile', {
        name: profileName.trim(),
        settings: {
          wb_mode: cameraSettings.wb_mode,
          wb_kelvin: cameraSettings.wb_mode === 'manual' ? cameraSettings.wb_kelvin : null,
          wb_tint: cameraSettings.wb_mode === 'manual' ? 0.0 : null,
          iso_mode: cameraSettings.iso_mode,
          iso: cameraSettings.iso_mode === 'manual' ? cameraSettings.iso : null,
          shutter_mode: cameraSettings.shutter_mode,
          shutter_s: cameraSettings.shutter_mode === 'manual' ? cameraSettings.shutter_s : null,
          zoom_factor: cameraSettings.zoom_factor,
          lens: cameraSettings.lens,
        }
      });
      await loadProfiles();
      profileName = '';
      alert('Profile saved successfully!');
    } catch (e) {
      alert(`Failed to save profile: ${e}`);
    } finally {
      savingProfile = false;
    }
  }

  async function deleteProfile(name) {
    if (!confirm(`Delete profile "${name}"?`)) return;

    try {
      await invoke('delete_profile', { name });
      await loadProfiles();
    } catch (e) {
      alert(`Failed to delete profile: ${e}`);
    }
  }

  async function applyProfile(profileName) {
    const ids = Array.from(selectedCameras);
    if (ids.length === 0) {
      alert('No cameras selected');
      return;
    }

    try {
      const results = await invoke('apply_profile', {
        profileName,
        cameraIds: ids
      });

      // Show results
      const failures = results.filter(r => !r.success);
      if (failures.length > 0) {
        alert(`Failed for ${failures.length} cameras:\n` + failures.map(f => f.error).join('\n'));
      } else {
        alert(`Profile "${profileName}" applied to ${ids.length} camera(s)`);
      }

      await refreshCameras();
    } catch (e) {
      alert(`Failed to apply profile: ${e}`);
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
        resolution: streamResolution,
        framerate: streamFramerate,
        bitrate: streamBitrate,
        codec: streamCodec
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
      <button on:click={() => showProfileDialog = true}>📋 Profiles</button>
      <button on:click={refreshCameras}>🔄 Refresh</button>
    </div>
  </header>

  <!-- Stream Settings -->
  <div class="stream-settings">
    <h3>Stream Settings</h3>
    <div class="settings-grid">
      <label>
        Resolution:
        <select bind:value={streamResolution}>
          <option value="1280x720">1280×720 (720p)</option>
          <option value="1920x1080">1920×1080 (1080p)</option>
          <option value="2560x1440">2560×1440 (1440p)</option>
          <option value="3840x2160">3840×2160 (4K)</option>
        </select>
      </label>
      <label>
        Framerate:
        <select bind:value={streamFramerate}>
          <option value={24}>24 fps</option>
          <option value={25}>25 fps</option>
          <option value={30}>30 fps</option>
          <option value={60}>60 fps</option>
        </select>
      </label>
      <label>
        Bitrate:
        <select bind:value={streamBitrate}>
          <option value={5000000}>5 Mbps</option>
          <option value={8000000}>8 Mbps</option>
          <option value={10000000}>10 Mbps</option>
          <option value={15000000}>15 Mbps</option>
          <option value={20000000}>20 Mbps</option>
          <option value={30000000}>30 Mbps</option>
          <option value={50000000}>50 Mbps</option>
        </select>
      </label>
      <label>
        Codec:
        <select bind:value={streamCodec}>
          <option value="h264">H.264</option>
          <option value="hevc">H.265/HEVC</option>
        </select>
      </label>
    </div>
  </div>

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

    <!-- Discovered Cameras -->
    {#if discoveredCameras.length > 0}
      <div class="discovered-section">
        <h2>📡 Discovered Cameras ({discoveredCameras.length})</h2>
        <div class="discovered-grid">
          {#each discoveredCameras as discovered (discovered.alias)}
            <div class="discovered-card">
              <div class="discovered-info">
                <strong>{discovered.alias}</strong>
                <small>{discovered.ip}:{discovered.port}</small>
              </div>
              <button on:click={() => addDiscoveredCamera(discovered)} class="btn-add">+ Add</button>
            </div>
          {/each}
        </div>
      </div>
    {:else if discovering}
      <div class="discovering-message">
        <p>🔍 Discovering cameras on the network...</p>
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

  <!-- Profile Management Dialog -->
  {#if showProfileDialog}
    <div class="dialog-overlay" on:click={() => showProfileDialog = false}>
      <div class="dialog dialog-large" on:click|stopPropagation>
        <h2>Profile Management</h2>

        <!-- Save Current Settings as Profile -->
        {#if showSettingsDialog && settingsCameraId}
          <div class="profile-save-section">
            <h3>Save Current Settings</h3>
            <div class="profile-save-form">
              <input
                type="text"
                bind:value={profileName}
                placeholder="Profile name"
                disabled={savingProfile}
              />
              <button
                on:click={saveCurrentProfile}
                disabled={savingProfile || !profileName.trim()}
                class="primary"
              >
                {savingProfile ? 'Saving...' : 'Save Profile'}
              </button>
            </div>
          </div>
        {/if}

        <!-- Saved Profiles List -->
        <div class="profiles-section">
          <h3>Saved Profiles ({profiles.length})</h3>
          {#if profiles.length === 0}
            <p class="empty-message">No profiles saved yet</p>
          {:else}
            <div class="profiles-list">
              {#each profiles as profile (profile.name)}
                <div class="profile-item">
                  <div class="profile-info">
                    <strong>{profile.name}</strong>
                    <div class="profile-details">
                      WB: {profile.settings.wb_mode || 'auto'}
                      {#if profile.settings.wb_mode === 'manual' && profile.settings.wb_kelvin}
                        ({profile.settings.wb_kelvin}K)
                      {/if}
                      | ISO: {profile.settings.iso_mode || 'auto'}
                      {#if profile.settings.iso_mode === 'manual' && profile.settings.iso}
                        ({profile.settings.iso})
                      {/if}
                      | Lens: {profile.settings.lens || 'wide'}
                    </div>
                  </div>
                  <div class="profile-actions">
                    <button
                      on:click={() => applyProfile(profile.name)}
                      class="btn-apply"
                    >
                      Apply to Selected
                    </button>
                    <button
                      on:click={() => deleteProfile(profile.name)}
                      class="btn-delete"
                    >
                      Delete
                    </button>
                  </div>
                </div>
              {/each}
            </div>
          {/if}
        </div>

        <div class="dialog-buttons">
          <button on:click={() => showProfileDialog = false}>Close</button>
        </div>
      </div>
    </div>
  {/if}

  <!-- Camera Settings Dialog -->
  {#if showSettingsDialog}
    <div class="dialog-overlay" on:click={() => showSettingsDialog = false}>
      <div class="dialog" on:click|stopPropagation>
        <h2>
          Camera Settings
          {#if savingSettings}
            <span style="color: #4CAF50; font-size: 0.9em; margin-left: 10px;">● Saving...</span>
          {/if}
        </h2>
        <div class="settings-form">
          <label>
            White Balance Mode:
            <select bind:value={cameraSettings.wb_mode}>
              <option value="auto">Auto</option>
              <option value="manual">Manual</option>
            </select>
          </label>
          {#if cameraSettings.wb_mode === 'manual'}
            <label>
              Temperature: <strong>{cameraSettings.wb_kelvin}K</strong>
              <div style="display: flex; gap: 8px; align-items: center; margin-top: 5px;">
                <input type="range" bind:value={cameraSettings.wb_kelvin} min="2000" max="10000" step="100" style="flex: 1;" />
                <input type="number" bind:value={cameraSettings.wb_kelvin} min="2000" max="10000" step="100" style="width: 80px;" />
              </div>
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
              ISO: <strong>{cameraSettings.iso}</strong>
              <div style="display: flex; gap: 8px; align-items: center; margin-top: 5px;">
                <input type="range" bind:value={cameraSettings.iso} min="50" max="3200" step="50" style="flex: 1;" />
                <input type="number" bind:value={cameraSettings.iso} min="50" max="3200" step="50" style="width: 80px;" />
              </div>
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
              Shutter Speed: <strong>{formatShutterSpeed(cameraSettings.shutter_s)}</strong>
              <div style="display: flex; gap: 8px; align-items: center; margin-top: 5px;">
                <input type="range" bind:value={cameraSettings.shutter_s} min="0.001" max="0.1" step="0.001" style="flex: 1;" />
                <input type="number" bind:value={cameraSettings.shutter_s} min="0.001" max="0.1" step="0.001" style="width: 80px;" />
              </div>
            </label>
          {/if}
          <label>
            Camera Position:
            <select bind:value={cameraSettings.camera_position}>
              <option value="back">Back</option>
              <option value="front">Front</option>
            </select>
          </label>
          <div class="lens-zoom-control">
            <label>Lens:</label>
            <div class="lens-buttons">
              <button
                type="button"
                class:active={selectedLens === 'ultra_wide'}
                on:click={() => cameraSettings.zoom_factor = 1.0}>
                .5
              </button>
              <button
                type="button"
                class:active={selectedLens === 'wide'}
                on:click={() => cameraSettings.zoom_factor = 2.0}>
                1
              </button>
              <button
                type="button"
                class:active={selectedLens === 'telephoto'}
                on:click={() => cameraSettings.zoom_factor = 10.0}>
                5
              </button>
            </div>
            <label>
              Fine Zoom: {(cameraSettings.zoom_factor / 2.0).toFixed(1)}×
              <input
                type="range"
                bind:value={cameraSettings.zoom_factor}
                min="1.0"
                max="20.0"
                step="0.1"
                style="width: 100%;" />
            </label>
          </div>
          <div class="dialog-buttons">
            <button type="button" on:click={() => showSettingsDialog = false}>Close</button>
          </div>
        </div>
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

  /* Discovered Cameras */
  .discovered-section {
    margin-bottom: 30px;
  }

  .discovered-section h2 {
    font-size: 18px;
    margin-bottom: 15px;
    color: #667eea;
  }

  .discovered-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(250px, 1fr));
    gap: 10px;
  }

  .discovered-card {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    background: #f8f9fa;
    border: 2px dashed #ddd;
    border-radius: 8px;
    transition: all 0.2s;
  }

  .discovered-card:hover {
    background: #e9ecef;
    border-color: #667eea;
  }

  .discovered-info {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .discovered-info strong {
    color: #333;
    font-size: 14px;
  }

  .discovered-info small {
    color: #666;
    font-size: 12px;
  }

  .lens-zoom-control {
    margin: 16px 0;
  }

  .lens-buttons {
    display: flex;
    gap: 8px;
    margin: 8px 0 16px 0;
  }

  .lens-buttons button {
    flex: 1;
    padding: 10px;
    border: none;
    border-radius: 8px;
    font-size: 14px;
    font-weight: 600;
    cursor: pointer;
    background: #f3f4f6;
    color: #374151;
    transition: all 0.2s;
  }

  .lens-buttons button.active {
    background: #667eea;
    color: white;
  }

  .lens-buttons button:hover {
    transform: scale(1.02);
  }

  .btn-add {
    padding: 6px 12px;
    background: #667eea;
    color: white;
    border: none;
    border-radius: 6px;
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
    transition: background 0.2s;
  }

  .btn-add:hover {
    background: #5568d3;
  }

  .discovering-message {
    padding: 20px;
    background: #fff3cd;
    border: 1px solid #ffc107;
    border-radius: 8px;
    margin-bottom: 20px;
    text-align: center;
  }

  .discovering-message p {
    margin: 0;
    color: #856404;
  }

  /* Profile Management Styles */
  .dialog-large {
    max-width: 600px;
  }

  .profile-save-section {
    background: #f8f9fa;
    padding: 20px;
    border-radius: 8px;
    margin-bottom: 20px;
  }

  .profile-save-section h3 {
    margin: 0 0 12px 0;
    font-size: 16px;
    color: #495057;
  }

  .profile-save-form {
    display: flex;
    gap: 10px;
    align-items: center;
  }

  .profile-save-form input {
    flex: 1;
    margin: 0;
  }

  .profiles-section h3 {
    margin: 0 0 15px 0;
    font-size: 16px;
    color: #495057;
  }

  .empty-message {
    text-align: center;
    color: #6c757d;
    padding: 20px;
    font-style: italic;
  }

  .profiles-list {
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .profile-item {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 16px;
    background: #f8f9fa;
    border: 1px solid #dee2e6;
    border-radius: 8px;
    transition: all 0.2s;
  }

  .profile-item:hover {
    background: #e9ecef;
    border-color: #adb5bd;
  }

  .profile-info {
    flex: 1;
  }

  .profile-info strong {
    display: block;
    margin-bottom: 4px;
    color: #212529;
    font-size: 15px;
  }

  .profile-details {
    font-size: 13px;
    color: #6c757d;
  }

  .profile-actions {
    display: flex;
    gap: 8px;
  }

  .btn-apply {
    padding: 8px 16px;
    background: #667eea;
    color: white;
    border: none;
    border-radius: 6px;
    font-size: 13px;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.2s;
  }

  .btn-apply:hover {
    background: #5568d3;
  }

  .btn-apply:active {
    transform: scale(0.98);
  }

  .btn-delete {
    padding: 8px 16px;
    background: #dc3545;
    color: white;
    border: none;
    border-radius: 6px;
    font-size: 13px;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.2s;
  }

  .btn-delete:hover {
    background: #c82333;
  }

  .btn-delete:active {
    transform: scale(0.98);
  }

  /* Stream Settings */
  .stream-settings {
    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
    padding: 20px;
    margin: 20px 0;
    border-radius: 12px;
    box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
  }

  .stream-settings h3 {
    margin: 0 0 15px 0;
    color: white;
    font-size: 18px;
    font-weight: 600;
  }

  .settings-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 15px;
  }

  .settings-grid label {
    display: flex;
    flex-direction: column;
    gap: 6px;
    color: white;
    font-size: 14px;
    font-weight: 500;
  }

  .settings-grid select {
    padding: 10px;
    border: 2px solid rgba(255, 255, 255, 0.3);
    border-radius: 8px;
    background: rgba(255, 255, 255, 0.95);
    color: #333;
    font-size: 14px;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.2s;
  }

  .settings-grid select:hover {
    border-color: rgba(255, 255, 255, 0.6);
    background: white;
  }

  .settings-grid select:focus {
    outline: none;
    border-color: white;
    box-shadow: 0 0 0 3px rgba(255, 255, 255, 0.2);
  }
</style>
