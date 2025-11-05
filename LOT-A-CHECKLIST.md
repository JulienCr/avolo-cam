# LOT A - MCP Core Implementation Checklist

## Phase 1: Project Setup & Foundation

### 1.1 iOS App Setup
- [ ] Create new Xcode project (Swift, iOS 15+ target)
- [ ] Integrate NDI|HX SDK framework
- [ ] Add SwiftNIO dependencies (HTTP/WebSocket)
- [ ] Configure Info.plist:
  - [ ] `NSCameraUsageDescription`
  - [ ] `NSLocalNetworkUsageDescription`
  - [ ] `NSBonjourServices = ["_avolocam._tcp"]`
  - [ ] `NSAppTransportSecurity → NSAllowsArbitraryLoadsInLocalNetworks = YES`
- [ ] Configure entitlements:
  - [ ] `com.apple.developer.networking.multicast`
- [ ] Implement idle timer disable during streaming
- [ ] Create project structure (Capture/, Encode/, Network/, NDI/, UI/)

### 1.2 Tauri Controller Setup
- [ ] Initialize Tauri project (Rust + Svelte/React)
- [ ] Add Rust dependencies:
  - [ ] mdns-sd or zeroconf
  - [ ] tokio
  - [ ] reqwest
  - [ ] tokio-tungstenite
  - [ ] tower (rate limiting)
- [ ] Setup project structure (src-tauri/, src/)
- [ ] Configure Tauri network permissions

## Phase 2: iOS Core Video Pipeline

### 2.1 Video Capture Module
- [ ] Implement AVCaptureSession setup
- [ ] Configure baseline 1920x1080@30fps capture
- [ ] Implement device discovery and format enumeration
- [ ] Set pixel format: `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`
- [ ] Attach color metadata to sample buffers:
  - [ ] Primaries: `kCVImageBufferColorPrimaries_ITU_R_709_2`
  - [ ] Matrix: `kCVImageBufferYCbCrMatrix_ITU_R_709_2`
  - [ ] Transfer: `kCVImageBufferTransferFunction_ITU_R_709_2`
- [ ] Implement camera controls (exposure, ISO, WB, focus, zoom)
- [ ] Build capabilities list (validate both capture AND encoder support)
- [ ] Generate per-lens capability variants (ultra-wide/wide/tele)
- [ ] Include max zoom per lens in capabilities

### 2.2 VideoToolbox Encoder
- [ ] Setup VTCompressionSession for H.264
- [ ] Configure low-latency properties:
  - [ ] `kVTCompressionPropertyKey_RealTime = true`
  - [ ] `kVTCompressionPropertyKey_ProfileLevel = H264_High_4_2`
  - [ ] `kVTCompressionPropertyKey_AllowFrameReordering = false`
  - [ ] `kVTCompressionPropertyKey_MaxKeyFrameInterval = fps`
  - [ ] `kVTCompressionPropertyKey_AverageBitRate = 10000000`
  - [ ] `kVTCompressionPropertyKey_DataRateLimits = [bitrate, 1]`
  - [ ] `kVTCompressionPropertyKey_ExpectedFrameRate = fps`
- [ ] Implement encoder callback for compressed frames
- [ ] Implement thermal guard (monitor `ProcessInfo.thermalState`)
- [ ] Auto step-down bitrate/fps on serious/critical thermal state
- [ ] Feed CMSampleBuffers from capture to encoder

### 2.3 NDI Integration
- [ ] Initialize NDI|HX SDK
- [ ] Create NDI sender with name: `AVOLO-CAM-<alias>`
- [ ] Convert H.264 elementary stream to NDI compressed format
- [ ] Attach NDI metadata (alias, WB, ISO, shutter)
- [ ] Handle NDI connection state changes
- [ ] Implement clean start/stop with resource cleanup
- [ ] Test NDI stream reception in OBS

## Phase 3: iOS Control API

### 3.1 HTTP REST Server (SwiftNIO)
- [ ] Setup SwiftNIO HTTP server on port 8888
- [ ] Implement Bearer token middleware
- [ ] Implement optional controller IP allow-list
- [ ] Disable CORS by default
- [ ] Implement rate-limiting middleware (50-100ms debounce for camera ops)
- [ ] Implement endpoints:
  - [ ] `GET /api/v1/status`
  - [ ] `GET /api/v1/capabilities`
  - [ ] `POST /api/v1/stream/start`
  - [ ] `POST /api/v1/stream/stop`
  - [ ] `POST /api/v1/camera`
  - [ ] `POST /api/v1/encoder/force_keyframe`
  - [ ] `GET /api/v1/logs.zip`
- [ ] Implement uniform error format `{code, message}`
- [ ] Handle 408/502 timeouts properly
- [ ] Setup JSON encoding/decoding with Codable

### 3.2 WebSocket Server
- [ ] Setup WebSocket endpoint at `/ws`
- [ ] Implement token authentication on connection
- [ ] Implement 1Hz telemetry broadcast (server→client):
  - [ ] fps, bitrate, battery, temp, wifi_rssi, ndi_state
  - [ ] queue_ms (encoder queue depth)
  - [ ] dropped_frames count
  - [ ] charging_state
- [ ] Implement command handling (client→server): `{"op": "set", "camera": {...}}`
- [ ] Implement telemetry collection:
  - [ ] Battery level from `UIDevice`
  - [ ] Thermal state from `ProcessInfo`
  - [ ] WiFi RSSI from network info
  - [ ] Charging state
  - [ ] Encoder queue metrics
  - [ ] Frame drop counter

### 3.3 mDNS Service Advertisement
- [ ] Setup Bonjour/NetService for `_avolocam._tcp.local`
- [ ] Populate TXT record (port, version, alias)
- [ ] Handle service registration
- [ ] Handle service deregistration
- [ ] Test discovery from macOS/other devices

## Phase 4: iOS Web UI

### 4.1 Minimal HTML Interface
- [ ] Create single-page HTML/CSS/JS UI
- [ ] Serve UI at `/` from HTTP server
- [ ] Implement stream controls (Start/Stop buttons)
- [ ] Implement resolution/FPS dropdown (populate from `/api/v1/capabilities`)
- [ ] Implement orientation lock toggle
- [ ] Implement lens selector (ultra-wide/wide/tele)
- [ ] Implement white balance controls:
  - [ ] Mode selector (auto/manual)
  - [ ] Presets (3200K/4300K/5600K)
  - [ ] Kelvin input field
- [ ] Implement ISO control slider
- [ ] Implement shutter speed control
- [ ] Implement real-time telemetry display:
  - [ ] FPS, bitrate, battery, temp, queue_ms, dropped frames
- [ ] Test UI on iPhone Safari

## Phase 5: Tauri Controller Backend

### 5.1 Camera Discovery Service
- [ ] Implement mDNS browser for `_avolocam._tcp.local`
- [ ] Implement manual camera addition by IP:port
- [ ] Maintain active camera list with connection status
- [ ] Implement periodic reachability checks for manual entries
- [ ] Handle mDNS service updates (camera appears/disappears)

### 5.2 Camera Client Manager
- [ ] Implement HTTP client with Bearer token support
- [ ] Implement WebSocket client with auto-reconnect
- [ ] Implement exponential backoff for reconnection
- [ ] Implement per-camera connection state tracking
- [ ] Implement request timeout handling (408/502)
- [ ] Implement telemetry stream parsing
- [ ] Store recent telemetry history per camera

### 5.3 Group Control Logic
- [ ] Implement parallel fan-out with bounded concurrency (tokio semaphore)
- [ ] Implement atomic execution to selected cameras
- [ ] Collect partial failures per camera
- [ ] Aggregate results and errors
- [ ] Return per-camera success/failure status

### 5.4 Persistence Layer
- [ ] Design JSON schema for camera profiles
- [ ] Implement local JSON storage:
  - [ ] Per-camera: alias, IP, port, token
  - [ ] Last profile: resolution, fps, bitrate, camera settings
- [ ] Implement load on startup
- [ ] Implement save on changes
- [ ] Implement config validation
- [ ] Handle migration/corruption gracefully

## Phase 6: Tauri Controller Frontend

### 6.1 Camera Discovery View
- [ ] Display discovered cameras from mDNS
- [ ] Implement manual add dialog (IP, port, token inputs)
- [ ] Implement camera alias editing
- [ ] Show connection status indicators
- [ ] Implement remove camera functionality

### 6.2 Grid View
- [ ] Design camera card layout
- [ ] Display camera info:
  - [ ] Alias, IP address, lens type
  - [ ] Telemetry: FPS, bitrate, battery %, temp °C, queue_ms
  - [ ] NDI state (streaming/idle), charging state
- [ ] Implement multi-select checkboxes
- [ ] Implement per-camera controls:
  - [ ] Start/Stop buttons
  - [ ] Resolution/FPS dropdown
  - [ ] Orientation lock toggle
  - [ ] Lens selector
  - [ ] White balance mode + presets + Kelvin input
  - [ ] ISO slider
  - [ ] Shutter speed control

### 6.3 Group Control Panel
- [ ] Implement "Apply to Selected" section
- [ ] Display per-cam result chips (success/failure)
- [ ] Implement batch Start/Stop
- [ ] Implement batch resolution/FPS change
- [ ] Implement batch WB/ISO/shutter change
- [ ] Implement "Copy from CAM-X → selected cams" feature
- [ ] Implement readonly mode toggle

### 6.4 Real-time Updates
- [ ] Subscribe to WebSocket telemetry per camera
- [ ] Implement 1Hz UI refresh
- [ ] Implement visual indicators for connection issues
- [ ] Implement toast notifications for errors
- [ ] Implement telemetry history sparklines (optional)

## Phase 7: Integration & Testing

### 7.1 Network Matrix Testing
- [ ] Test Wi-Fi 6 single AP configuration
- [ ] Test mesh network configuration
- [ ] Verify PC on gigabit Ethernet
- [ ] Test 1080p30 @ 8 Mbps with 3 cams
- [ ] Test 1080p30 @ 10 Mbps with 3 cams
- [ ] Test 1080p30 @ 12 Mbps with 3 cams
- [ ] Test with 6 cameras if available
- [ ] Verify mDNS discovery across WLAN↔LAN
- [ ] Document fix for AP client isolation if needed

### 7.2 OBS Validation
- [ ] Install NDI Source plugin (standard)
- [ ] Configure OBS project settings: Rec.709 / Full range
- [ ] Verify per-source rescale is disabled
- [ ] Test scene-level scaling
- [ ] Confirm NDI metadata visibility (alias, camera params)
- [ ] Verify color accuracy (Rec.709 Full end-to-end)

### 7.3 Performance Validation
- [ ] Measure glass-to-glass latency (LED clock method)
  - [ ] Target: ≤150ms median ✓/✗
- [ ] Monitor bitrate stability (8-12 Mbps)
  - [ ] Target: <1% frame drops over 2h ✓/✗
- [ ] Test resolution switch speed
  - [ ] Target: ≤3s ✓/✗
- [ ] Test group command latency (WB/ISO batch)
  - [ ] Target: ≤250ms to all targets ✓/✗

### 7.4 Stability Testing
- [ ] Run ≥2 hour continuous streaming with ≥3 iPhones
  - [ ] Configuration: 1080p30 @ 10 Mbps
  - [ ] Target: frame drop rate <1% ✓/✗
- [ ] Monitor thermal behavior throughout test
- [ ] Monitor battery drain rate
- [ ] Monitor charging state behavior
- [ ] Check for memory leaks (Instruments)
- [ ] Check for resource exhaustion
- [ ] Test reconnect after AP blip
  - [ ] Target: ≤2s reconnect ✓/✗

### 7.5 Deliverables
- [ ] Build iOS app .ipa or prepare Xcode project
- [ ] Build Tauri controller for macOS
- [ ] Build Tauri controller for Windows (optional)
- [ ] Build Tauri controller for Linux (optional)
- [ ] Write setup guide:
  - [ ] WiFi requirements
  - [ ] OBS configuration
  - [ ] iOS entitlements explanation
  - [ ] Token generation guide
  - [ ] Bonjour troubleshooting
- [ ] Create acceptance criteria verification document
- [ ] Document test results

## MCP Acceptance Criteria Summary

- [ ] **Multi-cam streaming**: ≥3 iPhones streaming 1080p30 @ 8-12 Mbps stable for ≥2 hours
- [ ] **Frame drops**: <1% over test duration
- [ ] **Latency**: Glass-to-glass ≤150ms median
- [ ] **Resolution switch**: <3 seconds
- [ ] **Group control latency**: <250ms to all targets
- [ ] **Reconnect**: <2 seconds after network blip
- [ ] **Color accuracy**: Rec.709 Full maintained end-to-end

---

## Sprint Planning Notes

**Estimated effort by phase:**
- Phase 1 (Setup): 1-2 days
- Phase 2 (Video Pipeline): 3-5 days
- Phase 3 (Control API): 3-4 days
- Phase 4 (iOS Web UI): 2-3 days
- Phase 5 (Tauri Backend): 4-5 days
- Phase 6 (Tauri Frontend): 4-5 days
- Phase 7 (Integration & Testing): 3-5 days

**Total estimated: 20-29 days (4-6 weeks)**

**Critical path:**
1. iOS video pipeline → NDI transmission (must validate in OBS early)
2. iOS API → Tauri backend integration
3. Multi-cam stability testing (allocate extra buffer time)

**High-risk areas:**
- NDI SDK integration and H.264 format compatibility
- Network performance at scale (6+ cameras)
- Thermal throttling on older iPhones
- mDNS reliability across different network configurations
