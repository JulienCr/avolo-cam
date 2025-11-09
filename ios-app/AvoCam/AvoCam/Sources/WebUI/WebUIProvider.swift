//
//  WebUIProvider.swift
//  AvoCam
//
//  Serves minimal web UI for standalone camera control
//

import Foundation

// MARK: - Web UI Provider

class WebUIProvider {
    // MARK: - HTML Content

    /// Embedded HTML for the web UI
    /// In the future, this could be moved to a bundled resource file
    private static let htmlContent = """
    <!DOCTYPE html>
    <html>
    <head>
        <title>AvoCam Control</title>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
        <meta charset="UTF-8">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                min-height: 100vh;
                padding: 20px;
                color: #333;
            }
            .container { max-width: 600px; margin: 0 auto; }
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
            h2 { font-size: 20px; margin-bottom: 16px; color: #667eea; }
            .status-grid {
                display: grid;
                grid-template-columns: repeat(2, 1fr);
                gap: 12px;
                margin-bottom: 20px;
            }
            .status-item { padding: 12px; background: #f8f9fa; border-radius: 8px; }
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
            .status-value.streaming { color: #10b981; }
            .status-value.idle { color: #6b7280; }
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
            button:active { transform: scale(0.98); }
            .btn-primary { background: #667eea; color: white; }
            .btn-primary:hover { background: #5568d3; }
            .btn-danger { background: #ef4444; color: white; }
            .btn-danger:hover { background: #dc2626; }
            .btn-secondary { background: #f3f4f6; color: #374151; }
            .btn-secondary:hover { background: #e5e7eb; }
            .settings-row { margin-bottom: 16px; }
            label { display: block; font-size: 14px; font-weight: 500; color: #374151; margin-bottom: 8px; }
            input, select {
                width: 100%;
                padding: 12px;
                border: 2px solid #e5e7eb;
                border-radius: 8px;
                font-size: 16px;
                transition: border-color 0.2s;
            }
            input:focus, select:focus { outline: none; border-color: #667eea; }
            .connection-status {
                display: inline-block;
                padding: 6px 12px;
                border-radius: 20px;
                font-size: 12px;
                font-weight: 600;
                margin-bottom: 12px;
            }
            .connection-status.connected { background: #d1fae5; color: #065f46; }
            .connection-status.disconnected { background: #fee2e2; color: #991b1b; }
            .info-text { font-size: 14px; color: #6b7280; text-align: center; margin-top: 12px; }
            .slider-group { display: flex; gap: 12px; align-items: center; }
            .slider-group input[type="range"] { flex: 1; height: 6px; padding: 0; }
            .slider-group input[type="number"] { width: 80px; padding: 8px; }
            .btn-group { display: flex; gap: 8px; }
            .btn-group button { flex: 1; }
            .lens-buttons { display: flex; gap: 8px; margin-bottom: 16px; }
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
            .lens-btn.active { background: #667eea; color: white; }
            .lens-btn:hover { transform: scale(1.02); }
        </style>
    </head>
    <body>
        <div class="container">
            <h1>🎥 AvoCam Control</h1>
            <div class="info-text" style="color: white; margin-bottom: 20px;">
                Use the Tauri Controller app for multi-camera management
            </div>
        </div>
        <script>
            // Simple UI to indicate server is running
            // Full interactive UI can be found in the original NetworkServer.swift
            console.log('AvoCam Web UI loaded');
        </script>
    </body>
    </html>
    """

    // MARK: - Serve UI

    /// Serve the web UI HTML
    func serve(request: HTTPRequest) -> HTTPResponseEncodable {
        return HTMLResponse(html: Self.htmlContent)
    }
}

// MARK: - HTML Response

private struct HTMLResponse: HTTPResponseEncodable {
    let html: String

    func toHTTPResponse(using encoder: JSONEncoder) throws -> HTTPResponse {
        guard let htmlData = html.data(using: .utf8) else {
            throw NetworkError.encodingFailed("Failed to encode HTML")
        }

        return HTTPResponse(
            status: .ok,
            headers: ["Content-Type": "text/html"],
            body: htmlData
        )
    }
}
