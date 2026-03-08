# iOS App Code Audit - AVOLO-CAM

**Date:** 2026-03-07
**Scope:** All 50 Swift source files in `ios-app/AvoCam/AvoCam/Sources/`
**Total lines:** ~9,508

---

## 1. File Inventory

### App Entry & Coordination (905 lines)
| File | Lines | Purpose |
|------|-------|---------|
| `AvoCamApp.swift` | 26 | SwiftUI @main entry point |
| `AppCoordinator.swift` | 679 | **GOD OBJECT** - UI coordinator, service wiring, request handling, settings persistence, network detection |

### Capture (1,295 lines)
| File | Lines | Purpose |
|------|-------|---------|
| `CaptureManager.swift` | 1,097 | **MONOLITH** - AVFoundation capture, camera switching, lens selection, exposure/WB/focus control, format negotiation |
| `TorchController.swift` | 198 | Torch/flashlight for NDI tally indication, device-specific levels |

### NDI (541 lines)
| File | Lines | Purpose |
|------|-------|---------|
| `NDIManager.swift` | 347 | NDI SDK wrapper - send video frames, metadata, backpressure, stats |
| `NDITallyPoller.swift` | 194 | Polls NDI tally state at 20Hz, controls torch |

### SRT (1,329 lines)
| File | Lines | Purpose |
|------|-------|---------|
| `H264Encoder.swift` | 224 | VideoToolbox H.264 encoder (shared by SRT + Flash) |
| `SRTManager.swift` | 367 | SRT streaming via Eyevinn/swift-srt, listener mode |
| `TSMuxer.swift` | 624 | MPEG-TS muxer for H.264 NAL units (SRT only) |
| `SRTConfiguration.swift` | 114 | SRT config model and conversion |

### RTP / Flash (935 lines)
| File | Lines | Purpose |
|------|-------|---------|
| `FlashManager.swift` | 307 | Flash streaming manager - H.264/RTP over UDP |
| `RTPPacketizer.swift` | 396 | RFC 6184 H.264/RTP packetizer |
| `UDPTransmitter.swift` | 232 | Network.framework UDP sender |

### Streaming Orchestration (485 lines)
| File | Lines | Purpose |
|------|-------|---------|
| `StreamingCoordinator.swift` | 210 | Routes frames to NDI, SRT, or Flash backends |
| `TelemetryAggregator.swift` | 131 | Aggregates telemetry from system + streaming stats |
| `ThermalManager.swift` | 144 | Thermal state monitoring and protective actions |

### Network / HTTP Server (1,356 lines)
| File | Lines | Purpose |
|------|-------|---------|
| `NetworkServer.swift` | 885 | **MONOLITH** - HTTP server, WebSocket, NIO pipeline, route handlers, inline endpoint logic |
| `BonjourService.swift` | 157 | mDNS advertisement via NetService |
| `HTTPRouter.swift` | 65 | Simple path/method router |
| `HTTPResponse+Convenience.swift` | 39 | HTTPResponse factory methods |

### Network Controllers (628 lines)
| File | Lines | Purpose |
|------|-------|---------|
| `CameraController.swift` | 102 | Camera settings endpoints (unused - routes registered inline in NetworkServer) |
| `SettingsController.swift` | 102 | Video settings, alias, brightness endpoints (unused) |
| `StaticController.swift` | 305 | Web UI HTML + logs endpoint (duplicate of WebUI.swift) |
| `StatusController.swift` | 47 | Status/capabilities endpoints (unused) |
| `StreamController.swift` | 72 | Stream start/stop endpoints (unused) |

### Network Middleware (128 lines)
| File | Lines | Purpose |
|------|-------|---------|
| `HTTPMiddleware.swift` | 14 | Middleware protocol |
| `AuthMiddleware.swift` | 48 | Bearer token validation |
| `CORSMiddleware.swift` | 27 | CORS preflight handling |
| `RateLimitMiddleware.swift` | 39 | Camera endpoint rate limiting |

### Models (917 lines)
| File | Lines | Purpose |
|------|-------|---------|
| `APIModels.swift` | 403 | All API request/response Codable types |
| `VideoSettings.swift` | 252 | Video presets, settings persistence, StreamConfiguration |
| `TelemetryCollector.swift` | 262 | System telemetry (battery, temp, WiFi, CPU, network) |

### Shared / DI / Protocols (422 lines)
| File | Lines | Purpose |
|------|-------|---------|
| `ServiceContainer.swift` | 173 | DI container singleton (unused - AppCoordinator does its own wiring) |
| `AVOCamError.swift` | 129 | Unified error enum |
| `AppConfiguration.swift` | 123 | Config load/save from UserDefaults |
| `UserDefaults+Keys.swift` | 55 | Type-safe UserDefaults keys (partially unused) |
| `APIController.swift` | 12 | Protocol for route registration (unused) |
| `CameraControlService.swift` | 15 | Protocol (unused) |
| `StatusProvider.swift` | 12 | Protocol (unused) |
| `StreamingService.swift` | 14 | Protocol (used by StreamingCoordinator) |
| `TelemetryProvider.swift` | 12 | Protocol (used by TelemetryAggregator) |

### Static Content (945 lines)
| File | Lines | Purpose |
|------|-------|---------|
| `WebUI.swift` | 945 | Embedded HTML/CSS/JS for standalone web control UI |

### UI Views (1,581 lines)
| File | Lines | Purpose |
|------|-------|---------|
| `ContentView.swift` | 161 | Main SwiftUI view with camera preview and overlays |
| `StreamControlOverlay.swift` | 255 | Start/stop buttons, mode badge, SRT URL display |
| `CameraSettingsPanel.swift` | 339 | Slide-out panel for WB, ISO, shutter, zoom |
| `TelemetryMenuView.swift` | 292 | Telemetry popup with grid cards |
| `CameraPreviewView.swift` | 120 | UIViewRepresentable for AVCaptureVideoPreviewLayer |
| `ScreenDimManager.swift` | 79 | Screen brightness control during streaming |
| `VideoSettingsView.swift` | 335 | Video preset/mode selection with ViewModel |

### Utils (148 lines)
| File | Lines | Purpose |
|------|-------|---------|
| `SRTHelpers.swift` | 62 | SRT port computation and URL builder |
| `ThermalMonitor.swift` | 86 | NotificationCenter-based thermal observer |

---

## 2. Monolith Detection

### Critical Monoliths

**`AppCoordinator.swift` (679 lines) - GOD OBJECT**
This class has at least 8 distinct responsibilities:
1. UI state management (@Published properties for SwiftUI)
2. Service creation and wiring (init creates ~10 objects)
3. Streaming lifecycle (start/stop)
4. Camera settings management (updateCameraSettings, 20+ fields)
5. Settings persistence (load/save to UserDefaults)
6. Network detection (detectLocalIPAddress - raw socket code)
7. Preview session management (initialize/stop/pause/resume)
8. Full NetworkRequestHandler implementation (12 handler methods)

The NetworkRequestHandler extension alone is 100 lines of boilerplate delegation.

**`NetworkServer.swift` (885 lines) - MONOLITH**
Contains:
1. Server lifecycle (start/stop)
2. WebSocket client management
3. Telemetry broadcasting
4. Route registration (inline, duplicating controllers)
5. All endpoint handler implementations (handleGetStatus, handleStreamStart, etc.)
6. HTTPResponse struct definition
7. WebSocketClient class definition
8. NetworkError enum
9. HTTPServerHandler (NIO channel handler, 100+ lines)
10. WebSocketServerHandler (NIO channel handler, 90+ lines)

**`CaptureManager.swift` (1,097 lines) - MONOLITH**
Handles camera selection, format negotiation, exposure, white balance, focus, zoom, lens switching, buffer pool management, and signpost profiling all in one actor.

**`WebUI.swift` (945 lines) - INLINE HTML**
Nearly 1,000 lines of embedded HTML/CSS/JavaScript as a Swift string literal. Extremely hard to maintain, test, or lint.

### Moderate Monoliths
- `TSMuxer.swift` (624 lines) - acceptable for a self-contained protocol implementation
- `APIModels.swift` (403 lines) - acceptable as a models file, but could be split

---

## 3. Dead Code

### Completely Dead: Network Controllers (5 files, ~628 lines)

The following controllers implement `APIController.registerRoutes()` but are **never instantiated or registered**. All routes are registered inline in `NetworkServer.registerRoutes()`:

- `CameraController.swift` (102 lines) - **DEAD**
- `SettingsController.swift` (102 lines) - **DEAD**
- `StatusController.swift` (47 lines) - **DEAD**
- `StreamController.swift` (72 lines) - **DEAD**
- `StaticController.swift` (305 lines) - **DEAD** and contains a duplicate web UI HTML (different from WebUI.swift)

Evidence: `NetworkServer.setupRouter()` calls `self.registerRoutes()` which registers all routes inline. No code creates any Controller instance. The `TODO` comment in NetworkServer confirms this: `// TODO: These will be removed in Phase 5 when DI is complete and controllers are used directly`.

### Completely Dead: ServiceContainer (173 lines)

`ServiceContainer.swift` is a singleton DI container that is **never used**. `AppCoordinator.init()` creates and wires all services directly. The `ServiceContainer.shared` singleton is never referenced anywhere in the codebase.

### Completely Dead: Unused Protocols (3 files, ~39 lines)

- `APIController.swift` - protocol adopted by dead controllers
- `CameraControlService.swift` - protocol never conformed to by any live code
- `StatusProvider.swift` - protocol never conformed to by any live code

### Partially Dead: UserDefaults+Keys

`UserDefaults+Keys.swift` defines typed accessors including `cameraSettingsData` and `videoSettingsData`, but `AppCoordinator.persistSettings()` uses the raw string `"camera_settings"` directly instead of the typed accessor. Similarly, `VideoSettingsManager` uses `"video_settings"` directly.

### Dead Code Within Files

- `AppConfiguration.withAlias()` creates a local `var updated = self` that is never used (line 100)
- `NDIManager.updateMetadata()` is defined but never called from any code path
- `H264Encoder.forceKeyframe()` is a stub with a TODO comment, never produces actual keyframes
- `FlashManager.forceKeyframe()` sets a flag but the flag is cleared without effect (the `if keyframeRequested` block just resets it)
- `StreamController.handleForceKeyframe()` is a dead endpoint handler (controller is dead) and even if live, it does nothing (returns success without calling any encoder)
- `TelemetryCollector.isWiFiConnected()` is never called
- `BonjourService.updateStreamInfo()` is never called

### Duplicate Web UI HTML

`StaticController.swift` contains a ~250-line inline HTML page that is a simplified version of the full HTML in `WebUI.swift`. Since `StaticController` is dead code, this is a dead duplicate. But even within live code, `NetworkServer.registerRoutes()` uses `WebUI.getHTML()` for the "/" route, so the correct one is being used.

---

## 4. Dead Transport Protocol Analysis

### Are SRT and RTP/Flash actually dead?

**No -- SRT and Flash are actively used.** They are NOT dead code. Here is the evidence:

**SRT is live:**
- `StreamingCoordinator.startStreaming()` has a `case .srt:` branch that calls `srtManager.start()` and `captureManager.startCapture()` with SRT callbacks
- `StreamingCoordinator.stopStreaming()` has a `case .srt:` that stops SRT
- `StreamingCoordinator.getTelemetryStats()` delegates to `srtManager.getStats()` in SRT mode
- `VideoSettingsView` exposes SRT configuration UI (port, latency, GOP, etc.)
- `StreamControlOverlay` shows SRT URL when streaming in SRT mode
- `AppCoordinator.getStatus()` builds SRT connection URL
- `APIModels.StreamStartRequest` has SRT-specific fields (srtPort, srtLatency, etc.)
- The app depends on `SwiftSRT` package

**Flash (RTP/UDP) is live:**
- `StreamingCoordinator.startStreaming()` has a `case .flash:` branch
- `AppCoordinator` manages Flash UDP port, Bonjour Flash port, and frame info callbacks
- `VideoSettingsView` has Flash-specific UI (destination host, port, jitter mode)
- Flash telemetry is broadcast via WebSocket
- The OBS plugin has Flash receiver support

**SRT helper files are partially dead:**
- `SRTHelpers.swift` defines `computeSRTPort()` and `buildSRTConnectionUrl()`. Neither function is ever called in the codebase. The SRT port is configured directly via VideoSettings, not computed from alias. **This file is dead.**

### Recommendation: Do NOT remove SRT or Flash

SRT and Flash are legitimate streaming modes actively wired into the architecture. They provide value:
- SRT: reliable transport for networks with packet loss, used with OBS SRT source
- Flash: ultra-low-latency for the custom OBS plugin receiver

What CAN be removed: `SRTHelpers.swift` (62 lines of unused utilities).

### H264Encoder placement is misleading

`H264Encoder.swift` lives under `SRT/` but is shared by both SRT and Flash. It should be moved to a shared location (e.g., `Encoding/` or `Streaming/`).

---

## 5. Architecture Smells

### 5.1 God Object: AppCoordinator

`AppCoordinator` is the center of gravity. It:
- Is the single `NetworkRequestHandler` conformance
- Owns ALL services
- Manages ALL published state
- Handles ALL settings persistence
- Contains inline IP address detection

This makes it untestable and a merge conflict magnet.

### 5.2 Incomplete DI Migration

The codebase shows evidence of an abandoned DI migration:
- `ServiceContainer.swift` exists but is unused
- Controller classes exist but are unused
- Protocols (`CameraControlService`, `StatusProvider`) exist but have no conformers in live code
- `NetworkServer.registerRoutes()` has a TODO: "Phase 5 DI integration"

The architecture has two parallel systems: the dead "clean" architecture (controllers + DI + protocols) and the live "everything in AppCoordinator" approach.

### 5.3 NetworkServer Has Too Many Inline Handlers

`NetworkServer` registers routes and implements handlers inline, duplicating what the dead controllers do. This creates a 885-line monolith where NIO pipeline code sits next to JSON encoding logic.

### 5.4 Duplicated errorJSON Helpers

The `errorJSON(code:message:)` helper is implemented independently in:
- `NetworkServer` (line 557)
- `HTTPRouter` (line 61)
- `AuthMiddleware` (line 44)
- `RateLimitMiddleware` (line 35)

Four copies of the same 3-line function.

### 5.5 Duplicated TXT Record Construction

`BonjourService.createTXTRecord()` and `BonjourService.updateFlashPort()` both construct the full TXT dictionary independently. If a field is added to one, it must be manually added to the other.

### 5.6 Misplaced Files

- `H264Encoder.swift` is in `SRT/` but serves both SRT and Flash
- `FlashManager.swift` is in `RTP/` which is misleading (Flash uses RTP, but the folder name doesn't match the feature name)
- `ThermalMonitor.swift` (Utils) and `ThermalManager.swift` (Streaming) have overlapping names and responsibilities

### 5.7 Two Thermal Monitoring Systems

- `ThermalMonitor.swift` - NotificationCenter observer, provides `onThermalStateChange` callback
- `ThermalManager.swift` - Polling-based, called from `TelemetryAggregator.collectTelemetry()`

Both exist. `ThermalMonitor` is never started in the live code path. `AppCoordinator.setupThermalMonitoring()` only uses `ThermalManager`. The `ThermalMonitor` class is **dead code**.

### 5.8 Resolution Parsing Duplication

`StreamingCoordinator` has `parseWidth(from:)` and `parseHeight(from:)`. `SRTConfiguration.from(request:)` has identical inline parsing. These should be a single utility.

---

## 6. Testability

### Current Test Coverage: 0%

There are **zero** test files in the project. No XCTest targets exist.

### What Is Testable Today

1. **APIModels** - Pure Codable structs, trivially testable for encode/decode
2. **AppConfiguration** - Static generation methods testable
3. **TSMuxer** - Pure data transformation, testable with known H.264 inputs
4. **RTPPacketizer** - Pure data transformation, testable with crafted sample buffers
5. **ThermalManager** - Pure state machine, easily testable
6. **VideoSettings/VideoSettingsManager** - Pure model + UserDefaults, testable
7. **HTTPRouter** - Can test route matching
8. **Middleware** (Auth, CORS, RateLimit) - Pure request/response, highly testable
9. **SRTConfiguration** - Pure conversion logic

### What Needs Refactoring to Test

1. **AppCoordinator** - Cannot test without creating real NDI/SRT/network instances. Needs protocol-based DI.
2. **NetworkServer** - Tightly coupled to NIO. Handler logic should be extracted.
3. **CaptureManager** - Depends on real AVCaptureSession. Needs protocol abstraction or test device injection.
4. **NDIManager** - Depends on NDI SDK C functions. Would need a protocol wrapper.
5. **SRTManager** - Depends on SwiftSRT. Would need protocol abstraction.

---

## 7. Concurrency Patterns

### Actors (Good)
- `CaptureManager` - actor, correctly isolates mutable state
- `H264Encoder` - actor
- `SRTManager` - actor
- `FlashManager` - actor
- `RTPPacketizer` - actor
- `UDPTransmitter` - actor
- `TelemetryCollector` - actor
- `TelemetryAggregator` - actor
- `TorchController` - actor
- `StreamingCoordinator` - actor

### Classes (Mixed Patterns)
- `NDIManager` - **plain class with DispatchQueue + DispatchSemaphore** (old-style concurrency). Uses `nonisolated(unsafe)` and `@unchecked Sendable` patterns. Thread safety depends on manual locking (`OSAllocatedUnfairLock`). Not an actor despite having significant mutable state.
- `NetworkServer` - **plain class**, thread safety via `OSAllocatedUnfairLock` for WebSocket clients. Handler closures capture `[weak self]`. NIO handlers are `@unchecked Sendable`.
- `NDITallyPoller` - **plain class** with Task-based polling. Has `@Published` property but is not MainActor-isolated. Mutation of `lastProgram`, `lastPreview`, `lastExternalTallyTime` from async contexts is not provably safe.
- `ThermalManager` - **plain class** with mutable state accessed from multiple actors (set `isStreaming` from TelemetryAggregator actor, read from checkThermalState called from same). Not thread-safe.
- `BonjourService` - **plain class**, should be fine since NetService is main-thread-bound.

### Specific Issues

**NDITallyPoller race condition:** `lastProgram`, `lastPreview`, and `lastExternalTallyTime` are mutated in `pollTallyState()` (from a Task) and `setExternalTally()` (from another Task). Since NDITallyPoller is a plain class, these accesses are not serialized. Should be an actor.

**ThermalManager data race:** `isStreaming` is set from `TelemetryAggregator` (an actor) via `thermalManager?.isStreaming = isStreaming` and read from `checkThermalState()` called in the same flow. Since `ThermalManager` is a `final class`, this crosses actor boundaries without protection.

**CaptureManager nonisolated(unsafe) usage:** The `_frameCallback` and `captureSession` properties are marked `nonisolated(unsafe)` with manual locking. This is correct but fragile -- future changes could introduce races if the lock discipline is not maintained.

**H264Encoder callback bridge:** Uses `Unmanaged.passUnretained(self).toOpaque()` to pass `self` as a C callback refcon. This is inherently unsafe if the encoder is deallocated while a frame is in-flight. The `nonisolated func handleEncodedFrame` creates a Task to hop back to the actor, which is correct but adds latency.

### Missing Sendable Conformances

- `Telemetry` struct - used across actor boundaries, should be `Sendable`
- `CurrentSettings` struct - crossed between actors, should be `Sendable`
- `StatusResponse` struct - sent across boundaries, should be `Sendable`

---

## 8. Error Handling

### Silent Failures (Errors Swallowed)

1. **`AppCoordinator.init()`** - The `Task` that wires services (`setTallyPoller`, `setStreamingCoordinator`) has no error handling. If either fails, initialization silently continues with broken wiring.

2. **`AppCoordinator.stop()`** - Creates three separate Tasks for stopStreaming, stopPreviewSession, and telemetryAggregator.stopCollection(). None are awaited. If the app is terminated during these, cleanup is incomplete.

3. **`CaptureManager.startCapture()` callback** - The frame callback silently returns if no pixel buffer is available: `guard let pixelBuffer = ... else { return }`. No counter, no logging.

4. **`NDIManager.send()`** - If backpressure drops a frame, it logs every 30th drop but has no mechanism to signal the caller or adjust quality.

5. **`SRTManager.sendEncodedFrame()`** - If `connectedClient` is nil (no OBS connected), frames are silently dropped with no counter increment.

6. **`TelemetryCollector.getWiFiRSSI()`** - Always returns -50 (hardcoded placeholder). Silent lie in telemetry data.

### Inconsistent Error Patterns

- `NDIManager` throws `NSError` (not `AVOCamError`) on start failure
- `SRTManager` has its own `SRTError` enum
- `FlashManager` has its own `FlashError` enum
- `H264Encoder` has its own `H264EncoderError` enum
- `NetworkServer` has `NetworkError` enum
- `AVOCamError` exists as a unified error type but is only used for `.alreadyStreaming`, `.invalidConfiguration`, and capture errors

The error taxonomy is fragmented. Four different error enums for transport failures.

### Error Context Loss

Many handlers use `try?` to decode JSON, losing the decode error:
```swift
guard let request = try? JSONDecoder().decode(StreamStartRequest.self, from: body) else {
    return HTTPResponse(status: 400, ...)
}
```
The actual decoding error (missing field? type mismatch?) is discarded.

---

## 9. Recommendations (Prioritized)

### Phase 1: Dead Code Removal (Low risk, high clarity)

**Estimated savings: ~1,100 lines**

1. **Delete dead controllers** (628 lines):
   - `CameraController.swift`
   - `SettingsController.swift`
   - `StatusController.swift`
   - `StreamController.swift`
   - `StaticController.swift`

2. **Delete dead DI container** (173 lines):
   - `ServiceContainer.swift`

3. **Delete dead protocols** (39 lines):
   - `APIController.swift`
   - `CameraControlService.swift`
   - `StatusProvider.swift`

4. **Delete dead utils** (148 lines):
   - `SRTHelpers.swift` (62 lines, never called)
   - `ThermalMonitor.swift` (86 lines, superseded by ThermalManager)

5. **Remove dead methods within live files:**
   - `NDIManager.updateMetadata()` (never called)
   - `BonjourService.updateStreamInfo()` (never called)
   - `TelemetryCollector.isWiFiConnected()` (never called)

6. **Clean up unused UserDefaults accessors** (`cameraSettingsData`, `videoSettingsData`)

### Phase 2: Fix Thread Safety Bugs (High risk if unfixed)

1. **Make `NDITallyPoller` an actor** - it mutates state from concurrent Tasks
2. **Make `ThermalManager` thread-safe** - either make it an actor or protect `isStreaming` with a lock
3. **Add `Sendable` conformance** to `Telemetry`, `CurrentSettings`, `StatusResponse`

### Phase 3: Extract AppCoordinator (Medium effort, high payoff)

1. **Extract `NetworkRequestHandler` conformance** into a dedicated `RequestHandlerBridge` that delegates to typed services
2. **Extract settings persistence** into a `SettingsPersistence` service
3. **Extract IP detection** into a utility function
4. **Keep AppCoordinator** as a thin UI state holder + lifecycle orchestrator

### Phase 4: NetworkServer Decomposition (Medium effort)

1. **Move inline route handlers** out of NetworkServer into the (currently dead) controller classes, or new handler objects
2. **Extract HTTPServerHandler and WebSocketServerHandler** into separate files
3. **Extract `HTTPResponse`, `WebSocketClient`, `NetworkError`** into their own files
4. **Consolidate `errorJSON` helper** into `HTTPResponse.error()` (which already exists)

### Phase 5: File Organization (Low effort)

1. **Move `H264Encoder.swift`** from `SRT/` to `Encoding/` or `Streaming/`
2. **Rename `RTP/` folder** to `Flash/` to match the feature name
3. **Move `FlashManager.swift`** alongside its transport peers

### Phase 6: Testability (Ongoing)

1. Add XCTest target
2. Write tests for pure logic first: `ThermalManager`, `RTPPacketizer`, `TSMuxer`, `APIModels`, `AppConfiguration`
3. Introduce protocol abstractions for `NDIManager` and `CaptureManager` to enable mocked tests of `StreamingCoordinator`

---

## Summary

| Category | Count | Lines |
|----------|-------|-------|
| Total source files | 50 | 9,508 |
| Dead files (safe to delete) | 10 | ~1,108 |
| Monolith files (need decomposition) | 3 | 2,661 |
| Thread safety issues | 2 | -- |
| Test files | 0 | 0 |
| Duplicate code instances | 5+ | -- |

**Recommended order: Remove dead code first (Phase 1), then fix concurrency bugs (Phase 2).** Dead code removal is zero-risk, immediately reduces cognitive load, and makes subsequent refactoring easier by reducing the surface area. The concurrency bugs in Phase 2 are latent race conditions that could manifest as crashes under load -- they should be fixed before any architectural refactoring.

Do NOT remove SRT or Flash. They are live transport modes actively used by the streaming pipeline. Only `SRTHelpers.swift` is dead among transport-related files.
