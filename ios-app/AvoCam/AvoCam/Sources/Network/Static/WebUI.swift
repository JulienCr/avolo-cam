//
//  WebUI.swift
//  AvoCam
//
//  Static web UI HTML for standalone camera control
//

import Foundation

/// Provides the embedded web UI for standalone camera control
struct WebUI {
    /// Returns the complete HTML page as Data for HTTP response
    static func getHTML() -> Data {
        return html.data(using: .utf8) ?? Data()
    }

    /// The complete HTML for the web control interface
    private static let html: String = """
    <!DOCTYPE html>
    <html>
    <head>
        <title>AvoCam Control</title>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
        <meta charset="UTF-8">
        <style>
            * {
                margin: 0;
                padding: 0;
                box-sizing: border-box;
            }
            body {
                font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                min-height: 100vh;
                padding: 20px;
                color: #333;
            }
            .container {
                max-width: 600px;
                margin: 0 auto;
            }
            .card {
                background: white;
                border-radius: 16px;
                padding: 24px;
                margin-bottom: 16px;
                box-shadow: 0 8px 32px rgba(0,0,0,0.1);
            }
            h1 {
                font-size: 28px;
                color: white;
                margin-bottom: 20px;
                text-align: center;
                text-shadow: 0 2px 4px rgba(0,0,0,0.2);
            }
            h2 {
                font-size: 20px;
                margin-bottom: 16px;
                color: #667eea;
            }
            .status-grid {
                display: grid;
                grid-template-columns: repeat(2, 1fr);
                gap: 12px;
                margin-bottom: 20px;
            }
            .status-item {
                padding: 12px;
                background: #f8f9fa;
                border-radius: 8px;
            }
            .status-label {
                font-size: 12px;
                color: #666;
                text-transform: uppercase;
                letter-spacing: 0.5px;
                margin-bottom: 4px;
            }
            .status-value {
                font-size: 24px;
                font-weight: 600;
                color: #333;
                font-family: 'SF Mono', Monaco, monospace;
            }
            .status-value.streaming {
                color: #10b981;
            }
            .status-value.idle {
                color: #6b7280;
            }
            button {
                width: 100%;
                padding: 16px;
                border: none;
                border-radius: 12px;
                font-size: 16px;
                font-weight: 600;
                cursor: pointer;
                transition: all 0.2s;
                margin-bottom: 12px;
            }
            button:active {
                transform: scale(0.98);
            }
            .btn-primary {
                background: #667eea;
                color: white;
            }
            .btn-primary:hover {
                background: #5568d3;
            }
            .btn-danger {
                background: #ef4444;
                color: white;
            }
            .btn-danger:hover {
                background: #dc2626;
            }
            .btn-secondary {
                background: #f3f4f6;
                color: #374151;
            }
            .btn-secondary:hover {
                background: #e5e7eb;
            }
            .settings-row {
                margin-bottom: 16px;
            }
            label {
                display: block;
                font-size: 14px;
                font-weight: 500;
                color: #374151;
                margin-bottom: 8px;
            }
            input, select {
                width: 100%;
                padding: 12px;
                border: 2px solid #e5e7eb;
                border-radius: 8px;
                font-size: 16px;
                transition: border-color 0.2s;
            }
            input:focus, select:focus {
                outline: none;
                border-color: #667eea;
            }
            .connection-status {
                display: inline-block;
                padding: 6px 12px;
                border-radius: 20px;
                font-size: 12px;
                font-weight: 600;
                margin-bottom: 12px;
            }
            .connection-status.connected {
                background: #d1fae5;
                color: #065f46;
            }
            .connection-status.disconnected {
                background: #fee2e2;
                color: #991b1b;
            }
            .info-text {
                font-size: 14px;
                color: #6b7280;
                text-align: center;
                margin-top: 12px;
            }
            .slider-group {
                display: flex;
                gap: 12px;
                align-items: center;
            }
            .slider-group input[type="range"] {
                flex: 1;
                height: 6px;
                padding: 0;
            }
            .slider-group input[type="number"] {
                width: 80px;
                padding: 8px;
            }
            .btn-group {
                display: flex;
                gap: 8px;
            }
            .btn-group button {
                flex: 1;
            }
            .lens-buttons {
                display: flex;
                gap: 8px;
                margin-bottom: 16px;
            }
            .lens-btn {
                flex: 1;
                padding: 12px;
                border: none;
                border-radius: 8px;
                font-size: 16px;
                font-weight: 600;
                cursor: pointer;
                background: #f3f4f6;
                color: #374151;
                transition: all 0.2s;
                margin-bottom: 0;
            }
            .lens-btn.active {
                background: #667eea;
                color: white;
            }
            .lens-btn:hover {
                transform: scale(1.02);
            }
        </style>
    </head>
    <body>
        <div class="container">
            <h1>🎥 AvoCam Control</h1>

            <div class="card">
                <h2>Status</h2>
                <div id="connection-indicator" class="connection-status disconnected">Disconnected</div>

                <!-- Camera Alias -->
                <div class="settings-row" style="margin-bottom: 16px;">
                    <label for="camera-alias">Camera Name (NDI Stream Name)</label>
                    <div style="display: flex; gap: 8px;">
                        <input
                            type="text"
                            id="camera-alias"
                            placeholder="AVOLO-CAM-01"
                            maxlength="64"
                            style="flex: 1;"
                        >
                        <button id="btn-update-alias" class="btn-secondary" style="width: auto; padding: 12px 20px; margin-bottom: 0;">
                            💾 Save
                        </button>
                    </div>
                    <div id="alias-feedback" style="margin-top: 8px; font-size: 12px; display: none;"></div>
                </div>

                <div class="status-grid">
                    <div class="status-item">
                        <div class="status-label">State</div>
                        <div id="ndi-state" class="status-value idle">Idle</div>
                    </div>
                    <div class="status-item">
                        <div class="status-label">FPS</div>
                        <div id="fps" class="status-value">0.0</div>
                    </div>
                    <div class="status-item">
                        <div class="status-label">Bitrate</div>
                        <div id="bitrate" class="status-value">0.0 Mbps</div>
                    </div>
                    <div class="status-item">
                        <div class="status-label">Battery</div>
                        <div id="battery" class="status-value">--</div>
                    </div>
                    <div class="status-item">
                        <div class="status-label">Temperature</div>
                        <div id="temp" class="status-value">--</div>
                    </div>
                    <div class="status-item">
                        <div class="status-label">WiFi RSSI</div>
                        <div id="wifi" class="status-value">--</div>
                    </div>
                </div>
            </div>

            <div class="card">
                <h2>Stream Control</h2>
                <button id="btn-start" class="btn-primary">▶️ Start Stream</button>
                <button id="btn-stop" class="btn-danger">⏹ Stop Stream</button>
                <button id="btn-keyframe" class="btn-secondary">🔑 Force Keyframe</button>
            </div>

            <div class="card">
                <h2>Camera Settings</h2>
                <div class="settings-row">
                    <label for="wb-mode">White Balance</label>
                    <select id="wb-mode">
                        <option value="auto">Auto</option>
                        <option value="manual">Manual</option>
                    </select>
                </div>
                <div id="wb-manual-controls" style="display: none;">
                    <div class="settings-row">
                        <label for="wb-kelvin">Temperature (Scene CCT): <span id="wb-kelvin-value">5000</span>K</label>
                        <div class="slider-group">
                            <input type="range" id="wb-kelvin-slider" value="5000" min="2000" max="10000" step="100">
                            <input type="number" id="wb-kelvin" value="5000" min="2000" max="10000" step="100">
                        </div>
                    </div>
                    <div class="settings-row">
                        <label for="wb-tint">Tint: <span id="wb-tint-value">0</span> (Green ← → Magenta)</label>
                        <div class="slider-group">
                            <input type="range" id="wb-tint-slider" value="0" min="-100" max="100" step="1">
                            <input type="number" id="wb-tint" value="0" min="-100" max="100" step="1">
                        </div>
                    </div>
                    <div class="btn-group">
                        <button id="btn-wb-measure" class="btn-secondary">📸 Auto Measure</button>
                    </div>
                </div>
                <div class="settings-row">
                    <label for="iso-mode">ISO</label>
                    <select id="iso-mode">
                        <option value="auto">Auto</option>
                        <option value="manual">Manual</option>
                    </select>
                </div>
                <div id="iso-manual-controls" style="display: none;">
                    <div class="settings-row">
                        <label for="iso">Sensitivity: <span id="iso-value">160</span></label>
                        <div class="slider-group">
                            <input type="range" id="iso-slider" value="160" min="50" max="3200" step="50">
                            <input type="number" id="iso" value="160" min="50" max="3200" step="50">
                        </div>
                    </div>
                </div>
                <div class="settings-row">
                    <label for="shutter-mode">Shutter Speed</label>
                    <select id="shutter-mode">
                        <option value="auto">Auto</option>
                        <option value="manual">Manual</option>
                    </select>
                </div>
                <div id="shutter-manual-controls" style="display: none;">
                    <div class="settings-row">
                        <label for="shutter">Exposure Time: <span id="shutter-value">1/100</span></label>
                        <div class="slider-group">
                            <input type="range" id="shutter-slider" value="0.01" min="0.001" max="0.1" step="0.001">
                            <input type="number" id="shutter" value="0.01" min="0.001" max="0.1" step="0.001">
                        </div>
                    </div>
                </div>
                <div class="settings-row">
                    <label for="camera-position">Camera Position</label>
                    <select id="camera-position">
                        <option value="back">Back</option>
                        <option value="front">Front</option>
                    </select>
                </div>
                <div class="settings-row">
                    <label>Lens</label>
                    <div class="lens-buttons">
                        <button class="lens-btn" data-lens="ultra_wide" data-zoom="1.0">.5</button>
                        <button class="lens-btn active" data-lens="wide" data-zoom="2.0">1</button>
                        <button class="lens-btn" data-lens="telephoto" data-zoom="10.0">5</button>
                    </div>
                </div>
                <div class="settings-row">
                    <label for="zoom">Fine Zoom: <span id="zoom-value">1.0</span>×</label>
                    <div class="slider-group">
                        <input type="range" id="zoom-slider" value="2.0" min="1.0" max="20.0" step="0.1">
                        <input type="number" id="zoom" value="2.0" min="1.0" max="20.0" step="0.1">
                    </div>
                </div>
                <div id="saving-indicator" style="text-align: center; padding: 12px; color: #667eea; font-weight: 500; display: none;">
                    ⏳ Saving...
                </div>
            </div>

            <div class="card">
                <h2>Tally Torch Settings</h2>
                <div class="status-grid" style="grid-template-columns: 1fr;">
                    <div class="status-item">
                        <div class="status-label">Device Model</div>
                        <div id="device-model" class="status-value" style="font-size: 14px;">--</div>
                    </div>
                    <div class="status-item">
                        <div class="status-label">Current Level</div>
                        <div id="current-torch-level" class="status-value">--</div>
                    </div>
                    <div class="status-item">
                        <div class="status-label">Default Level</div>
                        <div id="default-torch-level" class="status-value">--</div>
                    </div>
                </div>
                <div class="settings-row">
                    <label for="torch-level">Torch Brightness: <span id="torch-level-value">0.03</span></label>
                    <div class="slider-group">
                        <input type="range" id="torch-level-slider" value="0.03" min="0.01" max="1.0" step="0.01">
                        <input type="number" id="torch-level" value="0.03" min="0.01" max="1.0" step="0.01">
                    </div>
                </div>
                <button id="btn-reset-torch" class="btn-secondary">🔄 Reset to Default</button>
                <div id="torch-feedback" style="margin-top: 12px; font-size: 12px; display: none;"></div>
            </div>

            <div class="info-text">
                Use the Tauri Controller app for multi-camera management
            </div>
        </div>

        <script>
            let ws = null;
            const wsUrl = `ws://${window.location.host}/ws`;

            // Connect to WebSocket
            function connectWebSocket() {
                try {
                    ws = new WebSocket(wsUrl);

                    ws.onopen = () => {
                        console.log('Connected to WebSocket');
                        document.getElementById('connection-indicator').textContent = 'Connected';
                        document.getElementById('connection-indicator').className = 'connection-status connected';
                    };

                    ws.onmessage = (event) => {
                        try {
                            const telemetry = JSON.parse(event.data);
                            updateTelemetry(telemetry);
                        } catch (e) {
                            console.error('Failed to parse telemetry:', e);
                        }
                    };

                    ws.onerror = (error) => {
                        console.error('WebSocket error:', error);
                    };

                    ws.onclose = () => {
                        console.log('WebSocket closed, reconnecting...');
                        document.getElementById('connection-indicator').textContent = 'Disconnected';
                        document.getElementById('connection-indicator').className = 'connection-status disconnected';
                        setTimeout(connectWebSocket, 2000);
                    };
                } catch (e) {
                    console.error('Failed to connect:', e);
                    setTimeout(connectWebSocket, 2000);
                }
            }

            // Load torch settings and populate form
            async function loadTorchSettings() {
                try {
                    const torchData = await apiCall('/api/v1/torch/level');
                    console.log('Torch settings loaded:', torchData);

                    // Update display values
                    document.getElementById('device-model').textContent = torchData.device_model || 'Unknown';
                    document.getElementById('current-torch-level').textContent = torchData.current_level.toFixed(2);
                    document.getElementById('default-torch-level').textContent = torchData.default_level.toFixed(2);

                    // Update controls
                    document.getElementById('torch-level').value = torchData.current_level;
                    document.getElementById('torch-level-slider').value = torchData.current_level;
                    document.getElementById('torch-level-value').textContent = torchData.current_level.toFixed(2);
                } catch (e) {
                    console.error('Failed to load torch settings:', e);
                }
            }

            // Load camera status and populate form
            async function loadCameraStatus() {
                try {
                    const status = await apiCall('/api/v1/status');
                    console.log('Camera status loaded:', status);

                    // Load alias
                    if (status.alias) {
                        document.getElementById('camera-alias').value = status.alias;
                    }

                    // Populate camera settings form
                    if (status.current) {
                        const current = status.current;

                        // White balance - work directly with physical values
                        document.getElementById('wb-mode').value = current.wb_mode;
                        if (current.wb_mode === 'manual') {
                            document.getElementById('wb-manual-controls').style.display = 'block';
                            if (current.wb_kelvin) {
                                const sceneCCT_K = current.wb_kelvin;  // Physical value
                                document.getElementById('wb-kelvin').value = sceneCCT_K;
                                document.getElementById('wb-kelvin-slider').value = sceneCCT_K;
                                document.getElementById('wb-kelvin-value').textContent = sceneCCT_K;
                            }
                            if (current.wb_tint !== null && current.wb_tint !== undefined) {
                                const tint = Math.round(current.wb_tint);
                                document.getElementById('wb-tint').value = tint;
                                document.getElementById('wb-tint-slider').value = tint;
                                document.getElementById('wb-tint-value').textContent = tint;
                            }
                        }

                        // ISO
                        if (current.iso_mode) {
                            document.getElementById('iso-mode').value = current.iso_mode;
                            document.getElementById('iso-manual-controls').style.display =
                                current.iso_mode === 'manual' ? 'block' : 'none';
                        }
                        if (current.iso !== null && current.iso !== undefined) {
                            document.getElementById('iso').value = current.iso;
                            document.getElementById('iso-slider').value = current.iso;
                            document.getElementById('iso-value').textContent = current.iso;
                        }

                        // Shutter speed
                        if (current.shutter_mode) {
                            document.getElementById('shutter-mode').value = current.shutter_mode;
                            document.getElementById('shutter-manual-controls').style.display =
                                current.shutter_mode === 'manual' ? 'block' : 'none';
                        }
                        if (current.shutter_s !== null && current.shutter_s !== undefined) {
                            document.getElementById('shutter').value = current.shutter_s;
                            document.getElementById('shutter-slider').value = current.shutter_s;
                            document.getElementById('shutter-value').textContent = formatShutterSpeed(current.shutter_s);
                        }

                        // Zoom
                        if (current.zoom_factor) {
                            document.getElementById('zoom').value = current.zoom_factor;
                            document.getElementById('zoom-slider').value = current.zoom_factor;
                            // Display UI zoom (device zoom / 2)
                            document.getElementById('zoom-value').textContent = (current.zoom_factor / 2.0).toFixed(1);
                            updateLensButtonsFromZoom(current.zoom_factor);
                        }

                        // Camera position
                        if (current.camera_position) {
                            document.getElementById('camera-position').value = current.camera_position;
                        }
                    }
                } catch (e) {
                    console.error('Failed to load camera status:', e);
                }
            }

            // Update telemetry display
            function updateTelemetry(telemetry) {
                document.getElementById('fps').textContent = telemetry.fps.toFixed(1);
                document.getElementById('bitrate').textContent = (telemetry.bitrate / 1000000).toFixed(1) + ' Mbps';
                document.getElementById('battery').textContent = (telemetry.battery * 100).toFixed(0) + '%';
                document.getElementById('temp').textContent = telemetry.temp_c.toFixed(1) + '°C';
                document.getElementById('wifi').textContent = telemetry.wifi_rssi + ' dBm';

                const stateEl = document.getElementById('ndi-state');
                stateEl.textContent = telemetry.ndi_state.charAt(0).toUpperCase() + telemetry.ndi_state.slice(1);
                stateEl.className = 'status-value ' + telemetry.ndi_state;
            }

            // API calls
            async function apiCall(endpoint, method = 'GET', body = null) {
                try {
                    const options = {
                        method,
                        headers: {}
                    };
                    if (body) {
                        options.headers['Content-Type'] = 'application/json';
                        options.body = JSON.stringify(body);
                    }
                    const response = await fetch(endpoint, options);
                    if (!response.ok) {
                        const error = await response.json();
                        throw new Error(error.message || 'Request failed');
                    }
                    return await response.json();
                } catch (e) {
                    alert('Error: ' + e.message);
                    throw e;
                }
            }

            // Format shutter speed for display
            function formatShutterSpeed(seconds) {
                if (seconds >= 1) {
                    return seconds.toFixed(1) + 's';
                } else {
                    return '1/' + Math.round(1.0 / seconds);
                }
            }

            // Slider sync functions - work directly with physical SceneCCT_K
            function syncSlider(sliderId, inputId, valueId, formatter = null) {
                const slider = document.getElementById(sliderId);
                const input = document.getElementById(inputId);
                const valueLabel = document.getElementById(valueId);

                slider.addEventListener('input', (e) => {
                    const val = e.target.value;
                    input.value = val;
                    valueLabel.textContent = formatter ? formatter(val) : val;
                });

                input.addEventListener('input', (e) => {
                    const val = e.target.value;
                    slider.value = val;
                    valueLabel.textContent = formatter ? formatter(val) : val;
                });
            }

            // Initialize slider sync - all work with physical values
            syncSlider('wb-kelvin-slider', 'wb-kelvin', 'wb-kelvin-value');
            syncSlider('wb-tint-slider', 'wb-tint', 'wb-tint-value');
            syncSlider('iso-slider', 'iso', 'iso-value');
            syncSlider('shutter-slider', 'shutter', 'shutter-value', formatShutterSpeed);
            syncSlider('zoom-slider', 'zoom', 'zoom-value');
            syncSlider('torch-level-slider', 'torch-level', 'torch-level-value', (v) => parseFloat(v).toFixed(2));

            // Event handlers
            document.getElementById('btn-start').addEventListener('click', async () => {
                await apiCall('/api/v1/stream/start', 'POST', {
                    resolution: '1920x1080',
                    framerate: 30,
                    bitrate: 10000000,
                    codec: 'h264'
                });
            });

            document.getElementById('btn-stop').addEventListener('click', async () => {
                await apiCall('/api/v1/stream/stop', 'POST');
            });

            document.getElementById('btn-keyframe').addEventListener('click', async () => {
                await apiCall('/api/v1/encoder/force_keyframe', 'POST');
            });

            document.getElementById('btn-update-alias').addEventListener('click', async () => {
                const aliasInput = document.getElementById('camera-alias');
                const newAlias = aliasInput.value.trim();
                const feedbackEl = document.getElementById('alias-feedback');
                const btn = document.getElementById('btn-update-alias');

                if (!newAlias || newAlias.length > 64) {
                    feedbackEl.textContent = '⚠️ Alias must be 1-64 characters';
                    feedbackEl.style.color = '#ef4444';
                    feedbackEl.style.display = 'block';
                    return;
                }

                try {
                    btn.disabled = true;
                    btn.textContent = '⏳ Saving...';
                    feedbackEl.style.display = 'none';

                    const result = await apiCall('/api/v1/settings/alias', 'PUT', { alias: newAlias });

                    feedbackEl.textContent = result.requires_restart
                        ? '✅ Alias updated! Stream was restarted with new name.'
                        : '✅ Alias updated successfully!';
                    feedbackEl.style.color = '#10b981';
                    feedbackEl.style.display = 'block';

                    btn.disabled = false;
                    btn.textContent = '💾 Save';

                    // Hide feedback after 5 seconds
                    setTimeout(() => {
                        feedbackEl.style.display = 'none';
                    }, 5000);
                } catch (e) {
                    feedbackEl.textContent = '❌ Failed to update alias: ' + e.message;
                    feedbackEl.style.color = '#ef4444';
                    feedbackEl.style.display = 'block';
                    btn.disabled = false;
                    btn.textContent = '💾 Save';
                }
            });

            // Torch level update handler (debounced)
            let torchUpdateTimeout = null;
            async function updateTorchLevel() {
                const level = parseFloat(document.getElementById('torch-level').value);
                const feedbackEl = document.getElementById('torch-feedback');

                try {
                    feedbackEl.style.display = 'none';
                    const result = await apiCall('/api/v1/torch/level', 'PUT', { level });

                    // Update display values
                    document.getElementById('current-torch-level').textContent = result.current_level.toFixed(2);
                    document.getElementById('default-torch-level').textContent = result.default_level.toFixed(2);

                    feedbackEl.textContent = '✅ Torch level updated!';
                    feedbackEl.style.color = '#10b981';
                    feedbackEl.style.display = 'block';

                    setTimeout(() => {
                        feedbackEl.style.display = 'none';
                    }, 3000);
                } catch (e) {
                    feedbackEl.textContent = '❌ Failed to update: ' + e.message;
                    feedbackEl.style.color = '#ef4444';
                    feedbackEl.style.display = 'block';
                }
            }

            const debouncedTorchUpdate = debounce(updateTorchLevel, 500);

            document.getElementById('torch-level').addEventListener('input', debouncedTorchUpdate);
            document.getElementById('torch-level-slider').addEventListener('input', debouncedTorchUpdate);

            document.getElementById('btn-reset-torch').addEventListener('click', async () => {
                const feedbackEl = document.getElementById('torch-feedback');
                const btn = document.getElementById('btn-reset-torch');

                try {
                    btn.disabled = true;
                    btn.textContent = '⏳ Resetting...';
                    feedbackEl.style.display = 'none';

                    const result = await apiCall('/api/v1/torch/level', 'PUT', { level: null });

                    // Update display values
                    document.getElementById('device-model').textContent = result.device_model || 'Unknown';
                    document.getElementById('current-torch-level').textContent = result.current_level.toFixed(2);
                    document.getElementById('default-torch-level').textContent = result.default_level.toFixed(2);

                    // Update controls
                    document.getElementById('torch-level').value = result.current_level;
                    document.getElementById('torch-level-slider').value = result.current_level;
                    document.getElementById('torch-level-value').textContent = result.current_level.toFixed(2);

                    feedbackEl.textContent = '✅ Reset to default level!';
                    feedbackEl.style.color = '#10b981';
                    feedbackEl.style.display = 'block';

                    btn.disabled = false;
                    btn.textContent = '🔄 Reset to Default';

                    setTimeout(() => {
                        feedbackEl.style.display = 'none';
                    }, 3000);
                } catch (e) {
                    feedbackEl.textContent = '❌ Failed to reset: ' + e.message;
                    feedbackEl.style.color = '#ef4444';
                    feedbackEl.style.display = 'block';
                    btn.disabled = false;
                    btn.textContent = '🔄 Reset to Default';
                }
            });

            document.getElementById('btn-wb-measure').addEventListener('click', async () => {
                try {
                    const btn = document.getElementById('btn-wb-measure');
                    btn.disabled = true;
                    btn.textContent = '⏳ Measuring...';

                    const result = await apiCall('/api/v1/camera/wb/measure', 'POST');

                    // Result contains physical SceneCCT_K - use it directly!
                    const sceneCCT_K = result.scene_cct_k;
                    const tint = result.tint;

                    // Log for diagnostics
                    console.log('📊 WB Measured: SceneCCT_K =', sceneCCT_K, 'K, Tint =', tint);

                    // Update controls with physical values (no conversion!)
                    document.getElementById('wb-kelvin').value = sceneCCT_K;
                    document.getElementById('wb-kelvin-slider').value = sceneCCT_K;
                    document.getElementById('wb-kelvin-value').textContent = sceneCCT_K;

                    document.getElementById('wb-tint').value = Math.round(tint);
                    document.getElementById('wb-tint-slider').value = Math.round(tint);
                    document.getElementById('wb-tint-value').textContent = Math.round(tint);

                    // Auto-apply: send physical SceneCCT_K directly
                    const applySettings = {
                        wb_mode: 'manual',
                        wb_kelvin: sceneCCT_K,  // Send physical value
                        wb_tint: tint,
                        iso_mode: document.getElementById('iso-mode').value,
                        shutter_mode: document.getElementById('shutter-mode').value,
                        zoom_factor: parseFloat(document.getElementById('zoom').value)
                    };
                    if (applySettings.iso_mode === 'manual') {
                        applySettings.iso = parseInt(document.getElementById('iso').value);
                    }
                    if (applySettings.shutter_mode === 'manual') {
                        applySettings.shutter_s = parseFloat(document.getElementById('shutter').value);
                    }
                    await apiCall('/api/v1/camera', 'POST', applySettings);

                    btn.disabled = false;
                    btn.textContent = '📸 Auto Measure';
                } catch (e) {
                    console.error('Auto measure failed:', e);
                    document.getElementById('btn-wb-measure').disabled = false;
                    document.getElementById('btn-wb-measure').textContent = '📸 Auto Measure';
                }
            });

            // Debouncing function for live settings updates
            let saveTimeout = null;
            let isSaving = false;

            function debounce(func, delay) {
                return function(...args) {
                    clearTimeout(saveTimeout);
                    saveTimeout = setTimeout(() => func(...args), delay);
                };
            }

            async function updateCameraSettings() {
                if (isSaving) return;

                try {
                    isSaving = true;
                    document.getElementById('saving-indicator').style.display = 'block';

                    // Get selected lens from active button
                    const activeLensBtn = document.querySelector('.lens-btn.active');
                    const selectedLens = activeLensBtn ? activeLensBtn.dataset.lens : 'wide';

                    const settings = {
                        wb_mode: document.getElementById('wb-mode').value,
                        iso_mode: document.getElementById('iso-mode').value,
                        shutter_mode: document.getElementById('shutter-mode').value,
                        zoom_factor: parseFloat(document.getElementById('zoom').value),
                        lens: selectedLens,  // Send lens parameter for physical camera switching
                        camera_position: document.getElementById('camera-position').value
                    };
                    if (settings.wb_mode === 'manual') {
                        settings.wb_kelvin = parseInt(document.getElementById('wb-kelvin').value);
                        settings.wb_tint = parseFloat(document.getElementById('wb-tint').value);
                    }
                    if (settings.iso_mode === 'manual') {
                        settings.iso = parseInt(document.getElementById('iso').value);
                    }
                    if (settings.shutter_mode === 'manual') {
                        settings.shutter_s = parseFloat(document.getElementById('shutter').value);
                    }
                    await apiCall('/api/v1/camera', 'POST', settings);

                    setTimeout(() => {
                        document.getElementById('saving-indicator').style.display = 'none';
                    }, 500);
                } catch (e) {
                    console.error('Failed to update settings:', e);
                    document.getElementById('saving-indicator').style.display = 'none';
                } finally {
                    isSaving = false;
                }
            }

            const debouncedUpdateSettings = debounce(updateCameraSettings, 300);

            // Show/hide WB manual controls based on mode
            document.getElementById('wb-mode').addEventListener('change', (e) => {
                const isManual = e.target.value === 'manual';
                document.getElementById('wb-manual-controls').style.display = isManual ? 'block' : 'none';
                debouncedUpdateSettings();
            });

            // Show/hide ISO manual controls based on mode
            document.getElementById('iso-mode').addEventListener('change', (e) => {
                const isManual = e.target.value === 'manual';
                document.getElementById('iso-manual-controls').style.display = isManual ? 'block' : 'none';
                debouncedUpdateSettings();
            });

            // Show/hide shutter manual controls based on mode
            document.getElementById('shutter-mode').addEventListener('change', (e) => {
                const isManual = e.target.value === 'manual';
                document.getElementById('shutter-manual-controls').style.display = isManual ? 'block' : 'none';
                debouncedUpdateSettings();
            });

            // Camera position change
            document.getElementById('camera-position').addEventListener('change', () => {
                debouncedUpdateSettings();
            });

            // Helper functions for lens/zoom sync
            function updateLensButtonsFromZoom(deviceZoom) {
                const buttons = document.querySelectorAll('.lens-btn');
                buttons.forEach(btn => {
                    btn.classList.remove('active');
                });

                // Detect which lens based on device zoom
                // Device zoom: ultra-wide=1.0, wide=2.0, telephoto=10.0
                // Thresholds: 1.5 (between 1.0 and 2.0), 6.0 (between 2.0 and 10.0)
                let activeLens = 'wide';
                if (deviceZoom < 1.5) {
                    activeLens = 'ultra_wide';  // < 1.5x device zoom
                } else if (deviceZoom >= 6.0) {
                    activeLens = 'telephoto';   // >= 6.0x device zoom
                }

                // Activate the corresponding button
                buttons.forEach(btn => {
                    if (btn.dataset.lens === activeLens) {
                        btn.classList.add('active');
                    }
                });
            }

            function setZoomFromLens(deviceZoom) {
                document.getElementById('zoom').value = deviceZoom;
                document.getElementById('zoom-slider').value = deviceZoom;
                // Display UI zoom (device / 2)
                document.getElementById('zoom-value').textContent = (parseFloat(deviceZoom) / 2.0).toFixed(1);
                updateLensButtonsFromZoom(deviceZoom);
                debouncedUpdateSettings();
            }

            // Lens button click handlers
            document.querySelectorAll('.lens-btn').forEach(btn => {
                btn.addEventListener('click', () => {
                    const zoom = btn.dataset.zoom;
                    setZoomFromLens(zoom);
                });
            });

            // Auto-update on slider/input changes
            ['wb-kelvin', 'wb-tint', 'iso', 'shutter'].forEach(id => {
                document.getElementById(id).addEventListener('input', debouncedUpdateSettings);
                document.getElementById(id + '-slider').addEventListener('input', debouncedUpdateSettings);
            });

            // Zoom slider with lens sync
            document.getElementById('zoom').addEventListener('input', (e) => {
                const deviceZoom = parseFloat(e.target.value);
                document.getElementById('zoom-slider').value = deviceZoom;
                // Display UI zoom (device / 2)
                document.getElementById('zoom-value').textContent = (deviceZoom / 2.0).toFixed(1);
                updateLensButtonsFromZoom(deviceZoom);
                debouncedUpdateSettings();
            });

            document.getElementById('zoom-slider').addEventListener('input', (e) => {
                const deviceZoom = parseFloat(e.target.value);
                document.getElementById('zoom').value = deviceZoom;
                // Display UI zoom (device / 2)
                document.getElementById('zoom-value').textContent = (deviceZoom / 2.0).toFixed(1);
                updateLensButtonsFromZoom(deviceZoom);
                debouncedUpdateSettings();
            });

            // Initialize
            loadCameraStatus();
            loadTorchSettings();
            connectWebSocket();
        </script>
    </body>
    </html>
    """
}
