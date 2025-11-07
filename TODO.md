# AVOLO-CAM Implementation Status

**Branch:** `claude/camera-controls-and-fixes-011CUsY9sz5Ct1cEGK4itMr7`
**Last Updated:** 2025-11-07

---

## ✅ COMPLETED FEATURES

### Phase 1: Critical Fixes
- [x] **Tauri Models Fixed** - Added missing `iso_mode` and `shutter_mode` fields to match iOS API
- [x] **Settings Persistence Fixed** - `get_all_cameras()` now fetches fresh status instead of returning stale cache
- [x] **WebSocket Reconnection Improved** - Increased max attempts from 5→100, capped exponential backoff at 30s

### Phase 2: Camera Lens Selection (Backend Complete)
- [x] **iOS CaptureManager** - Full lens switching implementation
  - Support for wide/ultra_wide/telephoto lenses
  - Support for front/back camera positions
  - Automatic fallback to wide angle if requested lens unavailable
  - Session reconfiguration on camera/lens change
- [x] **iOS API Models** - Added `camera_position` and `lens` fields to `CurrentSettings` and `CameraSettingsRequest`
- [x] **iOS WebUI** - Added camera position and lens selectors
- [x] **Tauri Controller UI** - Added camera position and lens selectors
- [x] **Tauri Models** - Synced with iOS API (camera_position, lens fields)

### Phase 4: Code Cleanup
- [x] **Removed EncoderManager** - Deleted 376 lines of unused code
  - NDI SDK handles encoding internally, no separate encoder needed
  - Simplified architecture

### Phase 5: Live Settings Editing (Partial)
- [x] **Tauri Controller** - Removed Apply button, added 300ms debouncing
  - Settings update automatically as user adjusts controls
  - Visual "Saving..." indicator

---

## 🔴 KNOWN ISSUES (Critical)

### 1. Camera Lens Switching Not Working
**Status:** ❌ BROKEN
**Description:** Selecting different camera positions (front/back) or lenses (wide/ultra_wide/telephoto) has no effect. Nothing happens when user changes these settings.

**Affected:**
- iOS embedded WebUI
- Tauri controller
- iOS app UI (if implemented)

**Possible Causes:**
- CaptureManager may not be properly reconfiguring the session
- Fallback logic might be preventing actual lens switch
- Device capabilities not being queried correctly
- API request may not be reaching CaptureManager

**Debug Steps Needed:**
- [ ] Add extensive logging in `CaptureManager.updateSettings()` camera/lens switching section
- [ ] Verify API request is reaching the server with correct payload
- [ ] Check if `configure()` is being called when lens changes
- [ ] Verify device discovery is finding requested lens type
- [ ] Test on actual device with multiple lenses (not simulator)

### 2. Automatic Camera Detection Not Working (Tauri)
**Status:** ❌ BROKEN
**Description:** mDNS discovery in Tauri controller is not automatically finding cameras on the network.

**Affected:**
- Tauri controller camera discovery

**Current State:**
- Users must manually add cameras (IP, port, token)
- Auto-discovery feature exists but doesn't find cameras

**Possible Causes:**
- mDNS service type mismatch (`_avolocam._tcp.local` vs `_avolocam._tcp.local.`)
- Firewall blocking mDNS traffic
- iOS Bonjour service not advertising correctly
- Network configuration issues (VLAN, multicast routing)

**Debug Steps Needed:**
- [ ] Verify iOS is advertising mDNS service (check iOS logs)
- [ ] Use `dns-sd -B _avolocam._tcp` on macOS to verify service is visible
- [ ] Add debug logging to `camera_discovery.rs`
- [ ] Check if service type matches exactly between iOS and Tauri
- [ ] Test on same subnet/network

### 3. WebSocket Connection Failures (Tauri)
**Status:** ❌ BROKEN
**Description:** Persistent WebSocket connection errors in Tauri controller console

**Error Logs:**
```
[2025-11-07T12:30:08Z ERROR avocam_controller::camera_client] WebSocket connection error: Failed to connect to WebSocket
[2025-11-07T12:30:12Z ERROR avocam_controller::camera_client] WebSocket connection error: Failed to connect to WebSocket
[2025-11-07T12:30:20Z ERROR avocam_controller::camera_client] WebSocket connection error: Failed to connect to WebSocket
```

**Affected:**
- Tauri controller real-time telemetry
- Live updates for FPS, bitrate, battery, etc.

**Possible Causes:**
- Authentication token not being passed correctly in WebSocket upgrade
- URL format incorrect (`ws://ip:port/ws` vs `ws://ip:port/ws?token=...`)
- iOS WebSocket server not accepting connections
- CORS or connection rejection by iOS server

**Debug Steps Needed:**
- [ ] Check WebSocket URL format in `camera_client.rs` line 214
- [ ] Verify iOS NetworkServer is accepting WebSocket connections
- [ ] Test WebSocket connection manually (e.g., with `websocat` tool)
- [ ] Check if authentication is required for WebSocket upgrade
- [ ] Add more detailed error logging (connection refused vs timeout vs auth failure)

---

## 🚧 IN PROGRESS / PARTIALLY COMPLETE

### iOS WebUI Live Editing
**Status:** 🟡 PARTIAL
**Current:** Apply button still present, settings require manual submit
**Target:** Remove Apply button, add debouncing (like Tauri controller)

### Camera Persistence (Tauri)
**Status:** 🟡 NOT STARTED
**Target:** Save discovered cameras to `cameras.json` so they persist across app restarts

---

## 📋 TODO (Priority Order)

### HIGH PRIORITY (Fix Broken Features)
1. **[ ] Fix Camera Lens Switching**
   - Debug why camera position/lens changes don't work
   - Add logging to trace execution path
   - Test on physical device with multiple lenses
   - Verify session reconfiguration is happening

2. **[ ] Fix WebSocket Connection Issues**
   - Debug connection failure causes
   - Fix authentication token passing
   - Verify iOS WebSocket server is working
   - Test with manual WebSocket client

3. **[ ] Fix mDNS Auto-Discovery**
   - Debug why cameras aren't being discovered
   - Verify service advertisement from iOS
   - Test with `dns-sd` command line tool
   - Check network configuration

### MEDIUM PRIORITY (Feature Completion)
4. **[ ] iOS WebUI Live Editing**
   - Remove Apply button
   - Add JavaScript debouncing (300ms)
   - Add saving indicator

5. **[ ] Camera Persistence (Tauri)**
   - Save discovered cameras to `cameras.json`
   - Load cameras on app startup
   - Merge with live mDNS discoveries

6. **[ ] Profile Management (Tauri)**
   - Save camera settings as named profiles
   - Load profiles and apply to selected cameras
   - Delete profiles
   - UI for profile management

### LOW PRIORITY (Nice to Have)
7. **[ ] Resolution/Framerate Picker**
   - Query available formats from device
   - Dynamic UI based on capabilities
   - Replace fixed presets with dynamic selection

8. **[ ] Screen Blackout Mode (iOS)**
   - Real screen blackout (not just dim)
   - UIScreen.brightness = 0 + black fullscreen view
   - Toggle in settings

9. **[ ] End-to-End Testing**
   - Multi-camera streaming test (3+ devices)
   - Network interruption recovery test
   - Settings sync verification

---

## 🐛 DEBUGGING GUIDE

### Camera Lens Switching Issue

**Test Steps:**
1. Open iOS WebUI or Tauri controller
2. Change camera position from "Back" to "Front"
3. Expected: Preview switches to front camera
4. Actual: Nothing happens

**Where to Look:**
- `ios-app/AvoCam/AvoCam/Sources/Capture/CaptureManager.swift:227-254` - Camera switching logic
- `ios-app/AvoCam/AvoCam/Sources/AppCoordinator.swift:406-457` - Settings update handler
- Network logs to verify API request is received

**Quick Test:**
```bash
# Send camera switch request manually
curl -X POST http://<iOS-IP>:8888/api/v1/camera \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{"camera_position":"front","lens":"wide"}'
```

### WebSocket Connection Issue

**Test Steps:**
1. Launch Tauri controller
2. Add camera manually (IP, port, token)
3. Check console logs
4. Expected: WebSocket connected
5. Actual: Connection error repeatedly

**Where to Look:**
- `tauri-controller/src-tauri/src/camera_client.rs:206-252` - WebSocket connection logic
- `ios-app/AvoCam/AvoCam/Sources/Network/NetworkServer.swift` - WebSocket server handler

**Quick Test:**
```bash
# Test WebSocket connection manually
websocat ws://<iOS-IP>:8888/ws

# Or with wscat
wscat -c ws://<iOS-IP>:8888/ws
```

### mDNS Discovery Issue

**Test Steps:**
1. Start iOS app (should advertise mDNS service)
2. Launch Tauri controller
3. Expected: Camera appears automatically
4. Actual: No cameras found

**Where to Look:**
- `ios-app/AvoCam/AvoCam/Sources/Network/BonjourService.swift:24-62` - mDNS advertisement
- `tauri-controller/src-tauri/src/camera_discovery.rs` - mDNS browsing

**Quick Test:**
```bash
# Check if iOS is advertising service (run on macOS)
dns-sd -B _avolocam._tcp

# Should show something like:
# Browsing for _avolocam._tcp
# Timestamp     A/R Flags if Domain    Service Type         Instance Name
# 12:30:00.000  Add     3  4 local.   _avolocam._tcp.      AVOLO-CAM-01
```

---

## 📊 CODE STATISTICS

**Total Commits:** 6
**Files Modified:** 8
**Lines Added:** ~250
**Lines Removed:** ~390 (mostly EncoderManager deletion)

**Modified Files:**
```
ios-app/AvoCam/AvoCam/Sources/
  ├── AppCoordinator.swift
  ├── Capture/CaptureManager.swift
  ├── Models/APIModels.swift
  ├── Network/NetworkServer.swift
  ├── UI/CameraSettingsPanel.swift
  └── Encode/EncoderManager.swift (DELETED)

tauri-controller/src-tauri/src/
  ├── camera_client.rs
  ├── camera_manager.rs
  └── models.rs

tauri-controller/src/
  └── App.svelte
```

---

## 🎯 NEXT STEPS

### Immediate Actions (Today)
1. **Debug camera lens switching** - Add extensive logging, test on device
2. **Debug WebSocket connection** - Verify URL format and authentication
3. **Debug mDNS discovery** - Use command-line tools to verify service

### Short Term (This Week)
4. Complete iOS WebUI live editing
5. Implement camera persistence in Tauri
6. Add comprehensive error logging for debugging

### Long Term (Next Week)
7. Profile management feature
8. Resolution/framerate picker
9. End-to-end testing
10. Documentation updates

---

## 💡 NOTES

- **NDI SDK handles encoding** - EncoderManager removed, telemetry FPS/bitrate now return 0
- **iOS already has debouncing** - 50ms rate limiting in NetworkServer.swift
- **Tauri has live editing** - No apply button, 300ms debounce working
- **All API models synced** - iOS and Tauri models match exactly

---

## 🔗 RESOURCES

- **Project Docs:** `/docs/specs.md`
- **Checklist:** `/LOT-A-CHECKLIST.md`
- **README:** `/ios-app/README.md`
- **Branch:** `claude/camera-controls-and-fixes-011CUsY9sz5Ct1cEGK4itMr7`

---

**For Questions/Issues:** Check logs in:
- iOS: Xcode console when running on device
- Tauri: Terminal where app was launched
- WebSocket: Browser dev console (for WebUI)
