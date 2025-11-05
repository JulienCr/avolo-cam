# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**AVOLO-CAM** is a multi-iPhone NDI streaming system for OBS with remote control via a Tauri desktop application. The goal is to enable multiple iOS devices to stream low-latency, stable NDI|HX video to OBS while being controlled from a single desktop interface.

## Architecture

The system consists of three main components:

1. **iOS App** (Swift)
   - Captures video via AVFoundation (1080p/30fps baseline)
   - Encodes using VideoToolbox (H.264 CBR, GOP=fps, B-frames=0)
   - Transmits NDI|HX streams named `AVOLO-CAM-<alias>`
   - Advertises via mDNS (`_avolocam._tcp.local`)
   - Exposes HTTP REST API + WebSocket for control and telemetry
   - Serves minimal web UI for standalone control

2. **Tauri Controller** (Rust + Svelte/React)
   - Discovers cameras via mDNS or manual IP entry
   - Grid view of all cameras with telemetry (FPS, bitrate, temp, battery)
   - Group control: fan-out commands to multiple cameras
   - Per-camera settings: resolution/FPS, white balance, ISO, shutter
   - Persists camera aliases, tokens, and profiles (local JSON)

3. **OBS Integration**
   - Standard NDI Source plugin (no custom development required)
   - Project settings: Rec.709 color space, Full range

## Critical Technical Constraints

- **Color Pipeline**: Rec.709 Full range end-to-end (iOS → NDI → OBS)
- **H.264 Encoding**: CBR, GOP=fps, B-frames=0 for low latency
- **Security**: Bearer token authentication for all HTTP/WS endpoints
- **Latency Target**: ≤150ms glass-to-glass median
- **Stability Target**: ≥2 hours stable streaming with <1% frame drops
- **Resolution switch**: <3 seconds
- **Group control latency**: <250ms to all targets
- **Reconnect time**: <2 seconds after network interruption

## iOS Implementation Requirements

### Required Info.plist Keys
- `NSCameraUsageDescription` - Camera access for video capture
- `NSLocalNetworkUsageDescription` - Local network access for HTTP/WS server
- `NSBonjourServices` - Array containing `["_avolocam._tcp"]`
- `NSAppTransportSecurity → NSAllowsArbitraryLoadsInLocalNetworks = YES` - Allow HTTP on LAN

### Required Entitlements
- `com.apple.developer.networking.multicast` - Required for mDNS on iOS 14+

### Video Pipeline Configuration

**Pixel Format:**
- Use `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`

**Color Attachments on CMSampleBuffer:**
- Primaries: `kCVImageBufferColorPrimaries_ITU_R_709_2`
- Matrix: `kCVImageBufferYCbCrMatrix_ITU_R_709_2`
- Transfer: `kCVImageBufferTransferFunction_ITU_R_709_2`

**VTCompressionSession Low-Latency Properties:**
- `kVTCompressionPropertyKey_RealTime = true`
- `kVTCompressionPropertyKey_ProfileLevel = H264_High_4_2`
- `kVTCompressionPropertyKey_AllowFrameReordering = false` (no B-frames)
- `kVTCompressionPropertyKey_MaxKeyFrameInterval = fps` (GOP=30)
- `kVTCompressionPropertyKey_AverageBitRate = 10000000` (10 Mbps baseline)
- `kVTCompressionPropertyKey_DataRateLimits = [bitrate, 1]`
- `kVTCompressionPropertyKey_ExpectedFrameRate = fps`

**Thermal Management:**
- Monitor `ProcessInfo.thermalState`
- On `.serious` or `.critical`: step down bitrate or fps
- Surface thermal state in telemetry

**Keep Awake:**
- Disable `UIApplication.shared.isIdleTimerDisabled = true` during streaming

### API Enhancements
- Rate-limit camera setting changes (50-100ms debounce)
- Optional controller IP allow-list for added security
- CORS disabled by default
- Uniform error format: `{"code": "ERROR_CODE", "message": "Human readable"}`
- Timeout responses: 408 (request timeout) or 502 (upstream timeout)

### Additional Endpoints (Lot A)
- `POST /api/v1/encoder/force_keyframe` - Force IDR frame for clean cuts
- `GET /api/v1/logs.zip` - Download rotating logs

### WebSocket Telemetry Fields
- `fps` - Current frame rate
- `bitrate` - Current bitrate in bps
- `battery` - Battery level (0.0-1.0)
- `temp_c` - Device temperature in Celsius
- `wifi_rssi` - WiFi signal strength in dBm
- `ndi_state` - "streaming" or "idle"
- `queue_ms` - Encoder queue depth in milliseconds
- `dropped_frames` - Total dropped frame count
- `charging_state` - "charging", "full", or "unplugged"

### NDI Metadata
Attach to NDI stream:
- Camera alias
- Current white balance (mode + Kelvin)
- ISO value
- Shutter speed

## Tauri Controller Implementation Requirements

### Discovery
- Primary: mDNS browsing for `_avolocam._tcp.local`
- Fallback: Manual IP:port entry (for guest VLANs, IGMP snooping issues)
- Periodic reachability checks for manually-added cameras

### Connection Management
- HTTP client with Bearer token in Authorization header
- WebSocket client with exponential backoff reconnect
- Per-camera timeout configuration (default: 5s for HTTP, persistent WS)
- Handle 408/502 timeouts gracefully

### Group Control
- Parallel execution with bounded concurrency (use tokio Semaphore)
- Atomic fan-out: all selected cameras receive command
- Collect individual results (success/failure per camera)
- Display per-camera result chips in UI

### Features for Lot A
- **Readonly mode**: Toggle to disable control UI, monitoring only
- **Profile copy**: Copy settings from one camera to selected cameras
- **Multi-select**: Checkbox selection for batch operations

## iOS App API Contracts

All endpoints require Bearer token authentication.

### REST API (Port 8888)
- `GET /api/v1/status` - Current parameters, telemetry, and capabilities
- `GET /api/v1/capabilities` - Supported resolutions/FPS/codecs
- `POST /api/v1/stream/start` - Start NDI stream with specified parameters
- `POST /api/v1/stream/stop` - Stop NDI stream
- `POST /api/v1/camera` - Adjust camera settings (WB, ISO, shutter, focus, zoom)

### WebSocket (ws://<ip>:8888/ws)
- **Server→Client (1Hz)**: Telemetry updates (fps, bitrate, battery, temp, wifi_rssi, ndi_state, queue_ms)
- **Client→Server**: Camera control commands (`{"op": "set", "camera": {...}}`)

### Example Payloads

**Status Response:**
```json
{
  "alias": "AVOLO-CAM-01",
  "ndi_state": "streaming|idle",
  "current": {
    "resolution": "1920x1080",
    "fps": 30,
    "bitrate": 10000000,
    "codec": "h264",
    "wb_mode": "manual",
    "wb_kelvin": 5000,
    "iso": 160,
    "shutter_s": 0.01,
    "focus_mode": "manual",
    "zoom_factor": 1.0
  },
  "telemetry": {
    "fps": 29.97,
    "bitrate": 9800000,
    "battery": 0.82,
    "temp_c": 38.4,
    "wifi_rssi": -55
  }
}
```

**Stream Start Request:**
```json
{
  "resolution": "1920x1080",
  "framerate": 30,
  "bitrate": 10000000,
  "codec": "h264"
}
```

## Development Phases (Priority Order)

**Lot A - MCP Core (Highest Priority)**
- Single app build supporting multiple phones
- Basic NDI streaming to OBS (1080p30 @ 8-12 Mb/s)
- Tauri controller with discovery, grid view, and group control
- Target: ≥3 iPhones streaming stably for ≥2 hours

**Lot B - Stability & Multi-Cam Hardening**
- Reconnect logic (keep-alive, fast resume <2s)
- Thermal management (warn ≥43°C, optional bitrate step-down)
- Network quality indicators (RSSI telemetry)
- Settings profiles (save/recall/copy to cams)

**Lot C - Image Quality & Ops**
- Orientation lock, lens selection (ultra-wide/wide/tele)
- Anti-banding, WB presets, IDR on demand
- Test patterns (SMPTE bars, focus chart, 1kHz tone)

**Lot D - Diagnostics & Admin**
- Diagnostics endpoint (dropped frames, queue depth, temp timeline)
- Log download (rotating logs, `/api/v1/logs.zip`)
- Telemetry charts in controller (sparklines)
- Config backup/restore for full fleet

**Lot E - Polish & Extensions (Optional)**
- Adaptive bitrate ladder
- NTP time-stamping, tally return
- Optional TLS, controller allow-list
- Ethernet detection, LUT/HDR→SDR pipeline

## Tech Stack

- **iOS**: Swift, AVFoundation, VideoToolbox, NDI|HX SDK, SwiftNIO (HTTP/WS), Bonjour
- **Controller**: Tauri (Rust backend, Svelte/React frontend), Rust mDNS + HTTP/WS clients
- **OBS**: NDI Source plugin (standard), Rec.709/Full project settings

## Important Notes

- This is for **internal use** (no NDI branding/redistribution)
- Start with Lot A as MCP (Minimum Complete Product)
- Focus on stability and low latency over feature richness initially
- Uniform JSON error format across all APIs

## Development Resources

- **Implementation Checklist**: See [LOT-A-CHECKLIST.md](LOT-A-CHECKLIST.md) for detailed task breakdown (150+ items)
- **Specifications**: See [docs/specs.md](docs/specs.md) for complete project requirements
- **Estimated Timeline**: 4-6 weeks for LOT A MCP completion
