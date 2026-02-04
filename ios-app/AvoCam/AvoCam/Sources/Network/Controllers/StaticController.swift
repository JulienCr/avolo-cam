//
//  StaticController.swift
//  AvoCam
//
//  HTTP controller for static content (web UI, logs)
//

import Foundation

/// Controller for static content endpoints
final class StaticController: APIController {
    func registerRoutes(router: HTTPRouter) {
        router.get("/") { [weak self] _, _, _, _ in
            self?.handleWebUI() ?? HTTPResponse.internalError()
        }

        router.get("/api/v1/logs.zip") { [weak self] _, _, _, _ in
            self?.handleLogsDownload() ?? HTTPResponse.internalError()
        }
    }

    private func handleWebUI() -> HTTPResponse {
        let html = """
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
            </style>
        </head>
        <body>
            <div class="container">
                <h1>🎥 AvoCam Control</h1>

                <div class="card">
                    <h2>Status</h2>
                    <div id="connection-indicator" class="connection-status disconnected">Disconnected</div>

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
                </div>

                <div class="info-text">
                    Use the Tauri Controller app for full camera control and multi-camera management
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

                // Event handlers
                document.getElementById('btn-start').addEventListener('click', async () => {
                    await apiCall('/api/v1/stream/start', 'POST', {
                        resolution: '1920x1080',
                        framerate: 25,
                        bitrate: 10000000,
                        codec: 'h264'
                    });
                });

                document.getElementById('btn-stop').addEventListener('click', async () => {
                    await apiCall('/api/v1/stream/stop', 'POST');
                });

                // Initialize
                connectWebSocket();
            </script>
        </body>
        </html>
        """
        return HTTPResponse.html(html.data(using: .utf8) ?? Data())
    }

    private func handleLogsDownload() -> HTTPResponse {
        // TODO: Implement rotating logs and zip creation
        return HTTPResponse.error(status: 501, code: "NOT_IMPLEMENTED", message: "Logs download not yet implemented")
    }
}
