# AvoCam Controller - Tauri Desktop App

Multi-camera NDI controller desktop application for managing iPhone cameras running AvoCam.

## Features

- **mDNS Discovery**: Automatically discover cameras on the local network
- **Manual Addition**: Add cameras by IP address
- **Grid View**: Monitor multiple cameras simultaneously
- **Real-time Telemetry**: FPS, bitrate, battery, temperature, WiFi signal
- **Group Control**: Start/stop streams and adjust settings for multiple cameras at once
- **Bounded Concurrency**: Parallel operations with semaphore-based rate limiting
- **WebSocket**: Live telemetry updates from cameras
- **Profile Management**: (Coming in LOT B) Save and recall camera settings

## Project Status

✅ **Complete**: Core Rust backend with mDNS, HTTP client, WebSocket, group control
✅ **Complete**: Basic Svelte frontend with camera grid and group controls
📝 **Next Steps**: Testing with physical iPhones, advanced features (LOT B+)

## Prerequisites

- **Rust** 1.70+ (install from [rustup.rs](https://rustup.rs))
- **Node.js** 18+ and npm
- **Operating System**: macOS, Windows, or Linux

## Setup

### 1. Install Dependencies

```bash
# Install Rust dependencies
cd tauri-controller
cargo fetch

# Install Node dependencies
npm install
```

### 2. Development Mode

Run the app in development mode (with hot-reload):

```bash
npm run tauri:dev
```

This will:
- Start the Vite dev server (frontend)
- Compile and run the Rust backend
- Open the application window

### 3. Build for Production

Build distributable packages:

```bash
npm run tauri:build
```

This creates:
- **macOS**: `.app` bundle and `.dmg` installer in `src-tauri/target/release/bundle/`
- **Windows**: `.exe` installer in `src-tauri/target/release/bundle/`
- **Linux**: `.AppImage` and `.deb` in `src-tauri/target/release/bundle/`

## Architecture

### Backend (Rust)

```
src-tauri/src/
├── main.rs                 # Tauri commands and app setup
├── models.rs               # Data structures (matches iOS API)
├── camera_discovery.rs     # mDNS/Bonjour discovery
├── camera_client.rs        # HTTP/WebSocket client
└── camera_manager.rs       # Multi-camera coordination + group control
```

**Key Technologies:**
- **Tauri 2.0**: Cross-platform desktop framework
- **tokio**: Async runtime
- **reqwest**: HTTP client with 5s timeout
- **tokio-tungstenite**: WebSocket client with auto-reconnect
- **mdns-sd**: mDNS/Bonjour discovery (`_avolocam._tcp.local.`)
- **tokio::sync::Semaphore**: Bounded concurrency (max 10 parallel operations)

### Frontend (Svelte)

```
src/
├── main.js                 # App entry point
├── App.svelte              # Main UI component
└── app.css                 # Global styles
```

**Key Features:**
- Real-time camera status (2s polling)
- Grid layout with telemetry cards
- Multi-select checkboxes for group control
- Manual camera addition dialog
- Responsive design

## Usage

### Discovering Cameras

1. Ensure iPhones running AvoCam are on the same WiFi network
2. Launch the controller
3. Cameras should appear automatically via mDNS
4. If not appearing: click "+ Add Camera" to add manually

### Adding Cameras Manually

1. Click "+ Add Camera"
2. Enter:
   - IP address (find in iPhone WiFi settings)
   - Port (default: 8888)
   - Bearer token (displayed in iPhone app console or UI)
3. Click "Add"

### Controlling Cameras

**Single Camera:**
- Click "▶️ Start" to begin streaming
- Click "⏹ Stop" to end streaming
- View real-time telemetry (FPS, bitrate, battery, temp)

**Group Control:**
- Check boxes next to cameras to select
- Click "▶️ Start All" or "⏹ Stop All" in the Group Control section
- Operations run in parallel with bounded concurrency (max 10 simultaneous)

### Removing Cameras

- Click "✕" button in camera card header
- Confirm removal

## API Commands

The Tauri backend exposes these commands to the frontend:

```rust
// Discovery
discover_cameras() -> Vec<DiscoveredCamera>

// Camera management
add_camera_manual(ip, port, token) -> String (camera_id)
remove_camera(camera_id) -> ()
get_cameras() -> Vec<CameraInfo>
get_camera_status(camera_id) -> StatusResponse

// Single camera control
start_stream(camera_id, resolution, framerate, bitrate, codec) -> ()
stop_stream(camera_id) -> ()
update_camera_settings(camera_id, settings) -> ()
force_keyframe(camera_id) -> ()

// Group control (returns per-camera results)
group_start_stream(camera_ids, resolution, framerate, bitrate, codec) -> Vec<GroupCommandResult>
group_stop_stream(camera_ids) -> Vec<GroupCommandResult>
group_update_settings(camera_ids, settings) -> Vec<GroupCommandResult>

// Aliases
update_camera_alias(camera_id, alias) -> ()
```

## Configuration

### Network Requirements

- **Same Subnet**: Controller and iPhones must be on the same network segment
- **Multicast**: Network must allow multicast packets (required for mDNS)
- **Ports**:
  - HTTP: 8888 (default, configurable per camera)
  - WebSocket: same port as HTTP (`/ws` endpoint)

### Troubleshooting mDNS

If cameras don't appear automatically:

1. **Check multicast support**: Some networks block multicast (guest networks, VLANs with IGMP snooping)
2. **Firewall**: Ensure firewall allows mDNS (port 5353 UDP)
3. **Fallback**: Use manual camera addition

**Test mDNS from terminal:**

```bash
# macOS/Linux
dns-sd -B _avolocam._tcp.

# Should show discovered cameras
```

## Development

### Hot Reload

Changes to Svelte files trigger instant hot-reload.
Changes to Rust files require recompilation (handled automatically by `tauri dev`).

### Logging

Set log level:

```bash
RUST_LOG=debug npm run tauri:dev
```

Logs show:
- mDNS discovery events
- HTTP requests/responses
- WebSocket connections/disconnections
- Group operation results

### Adding New Features

1. **Add Tauri command** in `src-tauri/src/main.rs`:
   ```rust
   #[tauri::command]
   async fn my_command(state: State<'_, AppState>) -> Result<T, String> {
       // Implementation
   }
   ```

2. **Register command** in `invoke_handler!`:
   ```rust
   .invoke_handler(tauri::generate_handler![
       // ... existing commands
       my_command,
   ])
   ```

3. **Call from frontend** in Svelte:
   ```javascript
   import { invoke } from '@tauri-apps/api/core';

   const result = await invoke('my_command', { arg1, arg2 });
   ```

## Implementation Status

### ✅ Completed (LOT A - MCP)

- [x] Rust backend structure
- [x] mDNS camera discovery
- [x] HTTP client with Bearer token auth
- [x] WebSocket client with auto-reconnect (exponential backoff)
- [x] Camera manager with group control
- [x] Bounded concurrency (Semaphore-based)
- [x] Svelte frontend with grid view
- [x] Manual camera addition
- [x] Real-time telemetry display
- [x] Group start/stop controls

### 🚧 TODO (LOT B+)

- [ ] **Profile management**: Save/recall/copy camera settings
- [ ] **Resolution/FPS selector** in UI
- [ ] **Camera settings panel**: WB, ISO, shutter controls
- [ ] **Readonly mode**: Monitor-only toggle
- [ ] **Per-camera result chips**: Show individual success/failure for group ops
- [ ] **Telemetry charts**: Sparklines for FPS/bitrate/temp history
- [ ] **Network quality indicators**: Visual RSSI strength, warnings
- [ ] **Thermal warnings**: Alert when cameras overheat
- [ ] **Config backup/restore**: Export/import full fleet configuration
- [ ] **Orientation lock**: UI control
- [ ] **Lens selector**: Ultra-wide/wide/tele
- [ ] **WB presets**: 3200K/4300K/5600K quick buttons

## Testing

### Local Testing

1. Start mock camera server (or use actual iPhone)
2. Run controller: `npm run tauri:dev`
3. Add camera manually
4. Verify connection and telemetry

### Integration Testing

1. Deploy AvoCam to ≥3 iPhones
2. Connect all to same WiFi
3. Launch controller
4. Verify automatic discovery
5. Test group operations:
   - Start all streams
   - Check OBS for NDI sources
   - Stop all streams

### Performance Testing

- **Group operation latency**: Should complete in <250ms for 3 cameras
- **Telemetry update rate**: 1Hz (2s polling + 1Hz WebSocket)
- **Memory usage**: Monitor over 2h period with 6 cameras

## Known Issues

- **WebSocket reconnection**: Current implementation uses simple exponential backoff; may need improvement for flaky networks
- **Telemetry callback**: Currently just logs; needs proper state management for UI updates
- **mDNS on Windows**: May require additional firewall rules

## Roadmap

### LOT B (Stability & Multi-Cam Hardening)

- Settings profiles (save/recall/copy)
- Network quality indicators
- Error model improvements
- Per-cam rename
- Read-only mode

### LOT C (Image Quality & Ops)

- Full camera controls (orientation, lens, anti-banding)
- IDR on demand
- Test pattern generation

### LOT D (Diagnostics & Admin)

- Diagnostics endpoint integration
- Log download
- Telemetry charts (sparklines)
- Config backup/restore

## Resources

- [Tauri Documentation](https://tauri.app/v1/guides/)
- [Svelte Tutorial](https://svelte.dev/tutorial)
- [Tokio Async Runtime](https://tokio.rs/)
- [mdns-sd Crate](https://docs.rs/mdns-sd/)
- [reqwest HTTP Client](https://docs.rs/reqwest/)
- [LOT A Checklist](../LOT-A-CHECKLIST.md)
- [CLAUDE.md](../CLAUDE.md)

## Support

For issues and questions:
- Check logs: `RUST_LOG=debug npm run tauri:dev`
- Review inline code comments
- See architecture docs in [CLAUDE.md](../CLAUDE.md)

