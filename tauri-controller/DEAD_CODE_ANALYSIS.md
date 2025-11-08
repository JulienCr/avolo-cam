# Dead Code Analysis and Recommendations

This document analyzes all unused code in the Tauri controller application and provides recommendations for each item.

Generated: 2025-11-08

---

## 1. `WebSocketCommandMessage` ([models.rs:144](src-tauri/src/models.rs#L144))

### Current State
```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
#[allow(dead_code)]
pub struct WebSocketCommandMessage {
    pub op: String,
    pub camera: Option<CameraSettingsRequest>,
}
```

### Analysis
**Purpose:** This struct is designed to send camera control commands from the controller to the iOS app via WebSocket (bidirectional communication).

**Current Usage:** ❌ Not used anywhere in the codebase

**Why It Exists:** According to the CLAUDE.md spec, the WebSocket protocol should support:
- **Server→Client (1Hz)**: Telemetry updates (currently implemented via `WebSocketTelemetryMessage`)
- **Client→Server**: Camera control commands (this struct - NOT YET IMPLEMENTED)

### Recommendation: **KEEP - Future Enhancement**

**Rationale:**
1. This is part of the official API contract from [CLAUDE.md](../CLAUDE.md#websocket)
2. Currently, all camera control uses HTTP POST to `/api/v1/camera`, but WebSocket commands would provide:
   - Lower latency for rapid setting changes
   - Reduced overhead (persistent connection vs new HTTP request per change)
   - Better support for real-time adjustments (e.g., manual focus/zoom during streaming)

**How to Make It Useful:**

#### On iOS App Side (Swift):
```swift
// In WebSocketHandler, add command handling
func handleIncomingMessage(_ text: String) {
    if let commandMsg = try? JSONDecoder().decode(WebSocketCommandMessage.self, from: Data(text.utf8)) {
        switch commandMsg.op {
        case "set":
            if let settings = commandMsg.camera {
                // Apply camera settings
                cameraController.applySettings(settings)
            }
        default:
            logger.warning("Unknown WebSocket command: \(commandMsg.op)")
        }
    }
}
```

#### On Tauri Controller Side (Rust):
```rust
// In camera_client.rs, add method to send commands via WebSocket
impl CameraClient {
    pub async fn send_websocket_command(&self, command: WebSocketCommandMessage) -> Result<()> {
        if let Some(tx) = &self.ws_tx {
            let json = serde_json::to_string(&command)?;
            tx.send(Message::Text(json))?;
        }
        Ok(())
    }
}

// Add Tauri command in main.rs
#[tauri::command]
async fn send_camera_command_ws(
    state: State<'_, AppState>,
    camera_id: String,
    settings: CameraSettingsRequest,
) -> Result<(), String> {
    let manager = state.camera_manager.read().await;
    let command = WebSocketCommandMessage {
        op: "set".to_string(),
        camera: Some(settings),
    };
    manager.send_websocket_command(&camera_id, command).await
        .map_err(|e| e.to_string())
}
```

**Priority:** LOT C (Image Quality & Ops) - Useful for real-time controls like manual focus/zoom

---

## 2. `scan_once()` Method ([camera_discovery.rs:116](src-tauri/src/camera_discovery.rs#L116))

### Current State
```rust
#[allow(dead_code)]
pub async fn scan_once(&self) -> Result<Vec<DiscoveredCamera>> {
    // Performs a 5-second timed mDNS scan and returns results
}
```

### Analysis
**Purpose:** One-time mDNS discovery scan with timeout (vs continuous browsing in `start_browsing()`)

**Current Usage:** ❌ Not used - app uses `start_browsing()` for continuous discovery

**Why It Exists:** Initial implementation approach that was superseded by continuous discovery.

### Recommendation: **REMOVE**

**Rationale:**
1. The application already uses continuous discovery via `start_browsing()` (see [main.rs:269](src-tauri/src/main.rs#L269))
2. One-time scans are problematic in a multi-camera workflow:
   - Cameras may boot at different times
   - Network interruptions would require manual re-scans
   - mDNS responses can be delayed beyond the 5-second timeout
3. No foreseeable use case where one-time scan is better than continuous discovery
4. Duplicates code from `start_browsing()` (maintenance burden)

**How to Remove:**

```rust
// In camera_discovery.rs, delete lines 114-184
// Remove the entire scan_once method and its documentation
```

Verify no references exist:
```bash
cd tauri-controller/src-tauri
grep -r "scan_once" src/
```

**Impact:** None - method is completely unused

---

## 3. `is_connected()` Method ([camera_client.rs:204](src-tauri/src/camera_client.rs#L204))

### Current State
```rust
#[allow(dead_code)]
pub async fn is_connected(&self) -> bool {
    *self.connected.read().await
}
```

### Analysis
**Purpose:** Query WebSocket connection state for a specific camera client

**Current Usage:** ❌ Not used anywhere

**Why It Exists:** Reasonable utility method that was implemented but never integrated into UI

### Recommendation: **KEEP - Make Useful**

**Rationale:**
1. **Connection state is critical UX information** that the UI should display
2. Currently, connection state is tracked internally but not exposed to frontend
3. Users need to know if WebSocket telemetry is active (especially after network issues)
4. Required for LOT B (Stability & Multi-Cam Hardening) - "Network quality indicators"

**How to Make It Useful:**

#### Step 1: Expose in CameraManager
```rust
// In camera_manager.rs
impl CameraManager {
    pub async fn get_camera_connection_state(&self, camera_id: &str) -> Result<bool> {
        let cameras = self.cameras.read().await;
        let camera = cameras.get(camera_id)
            .ok_or_else(|| anyhow::anyhow!("Camera not found"))?;
        Ok(camera.client.is_connected().await)
    }
}
```

#### Step 2: Add Tauri Command
```rust
// In main.rs
#[tauri::command]
async fn get_camera_connection_state(
    state: State<'_, AppState>,
    camera_id: String,
) -> Result<bool, String> {
    let manager = state.camera_manager.read().await;
    manager.get_camera_connection_state(&camera_id).await
        .map_err(|e| e.to_string())
}
```

#### Step 3: Update Frontend (Svelte)
```svelte
<!-- In CameraCard.svelte or equivalent -->
<script>
  import { invoke } from '@tauri-apps/api/core';

  let isWebSocketConnected = false;

  async function checkConnection() {
    isWebSocketConnected = await invoke('get_camera_connection_state', {
      cameraId: camera.id
    });
  }

  // Poll connection state every 5 seconds
  onMount(() => {
    const interval = setInterval(checkConnection, 5000);
    return () => clearInterval(interval);
  });
</script>

<!-- Show connection indicator -->
<div class="connection-status">
  <span class:connected={isWebSocketConnected}>
    {isWebSocketConnected ? '🟢 Live' : '🔴 Disconnected'}
  </span>
</div>
```

#### Step 4: Enhance CameraInfo Model
```rust
// In models.rs, update CameraInfo
pub struct CameraInfo {
    pub id: String,
    pub alias: String,
    pub ip: String,
    pub port: u16,
    pub token: String,
    pub status: Option<StatusResponse>,
    pub connection_state: ConnectionState,
    pub websocket_connected: bool,  // ADD THIS FIELD
}
```

**Priority:** LOT B (Stability & Multi-Cam Hardening) - Essential for network quality indicators

---

## Summary of Recommendations

| Item | Location | Action | Priority | Reason |
|------|----------|--------|----------|--------|
| `WebSocketCommandMessage` | [models.rs:144](src-tauri/src/models.rs#L144) | **KEEP** | LOT C | Part of official API spec, enables low-latency bidirectional control |
| `scan_once()` | [camera_discovery.rs:116](src-tauri/src/camera_discovery.rs#L116) | **REMOVE** | Immediate | Obsolete, duplicates continuous discovery, no use case |
| `is_connected()` | [camera_client.rs:204](src-tauri/src/camera_client.rs#L204) | **MAKE USEFUL** | LOT B | Critical for UX - users need connection status visibility |

---

## Implementation Checklist

### Immediate Actions (Technical Debt Cleanup)
- [ ] Remove `scan_once()` method from `camera_discovery.rs`
- [ ] Remove `#[allow(dead_code)]` from `is_connected()`
- [ ] Add inline documentation for `WebSocketCommandMessage` explaining future use

### LOT B: Implement `is_connected()` Integration
- [ ] Add `get_camera_connection_state()` to `CameraManager`
- [ ] Add `get_camera_connection_state` Tauri command
- [ ] Add `websocket_connected` field to `CameraInfo` struct
- [ ] Update frontend to display WebSocket connection status
- [ ] Add connection status to camera grid cards
- [ ] Add reconnection indicator (show reconnect attempts)

### LOT C: Implement WebSocket Commands
- [ ] Remove `#[allow(dead_code)]` from `WebSocketCommandMessage`
- [ ] Modify `CameraClient` to support sending WebSocket messages (currently read-only)
- [ ] Implement WebSocket command handler on iOS app
- [ ] Add Tauri command for WebSocket-based camera control
- [ ] Add frontend toggle: "Use WebSocket for controls" (vs HTTP)
- [ ] Add latency comparison telemetry (HTTP vs WS command latency)
- [ ] Document performance benefits in user guide

---

## Notes

- All dead code was added with good intentions - nothing here is "bad code"
- `WebSocketCommandMessage` represents forward-thinking API design
- The main issue is incomplete integration between layers (Rust ↔ Frontend)
- Removing `scan_once()` will improve maintainability with zero functional impact
- Making `is_connected()` useful is high ROI - small effort, big UX improvement
