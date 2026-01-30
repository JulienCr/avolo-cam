# AvoCam iOS App

Multi-iPhone NDI streaming app for OBS with remote control capabilities.

## Project Status

🚧 **Phase 1 Complete**: Core project structure and source files created
📝 **Next Steps**: Create Xcode project, integrate NDI SDK, implement SwiftNIO server

## Prerequisites

- macOS with Xcode 15+ installed
- iOS 15+ target devices (physical iPhones for testing)
- NDI SDK for iOS (download from [ndi.tv/sdk](https://ndi.tv/sdk))
- Apple Developer account (for device deployment and entitlements)

## Project Setup

### Step 1: Create Xcode Project

Since Xcode projects (.xcodeproj) can't be created programmatically, follow these steps:

1. Open Xcode
2. Create new project: File → New → Project
3. Select **iOS** → **App**
4. Configure project:
   - Product Name: `AvoCam`
   - Team: Your team
   - Organization Identifier: `com.avocam` (or your identifier)
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Save location: `/Users/julien.cruau/dev/avolo-cam/ios-app/`

5. Delete the default files Xcode creates:
   - Delete `AvoCamApp.swift` (we have our own)
   - Delete `ContentView.swift` (we have our own)

6. Add our source files to the project:
   - Drag `Sources/` folder into Xcode project navigator
   - Check "Create groups" (not "Create folder references")
   - Ensure target is AvoCam

7. Add Resources:
   - Select project in navigator → AvoCam target → Build Settings
   - Set "Info.plist File" to: `Resources/Info.plist`
   - Add `Resources/AvoCam.entitlements` via: Target → Signing & Capabilities → (select the entitlements file)

### Step 2: Configure Signing & Capabilities

1. Select project → AvoCam target → **Signing & Capabilities**
2. Select your team
3. Enable capabilities:
   - **Multicast Networking** (automatic with entitlements file)
4. Verify entitlements file is set

### Step 3: Install Swift Dependencies

The `Package.swift` file defines SwiftNIO dependencies, but for an iOS app project:

1. In Xcode: File → Add Package Dependencies
2. Add the following packages:
   - SwiftNIO: `https://github.com/apple/swift-nio.git` (version 2.62.0+)
   - swift-nio-extras: `https://github.com/apple/swift-nio-extras.git` (version 1.20.0+)
   - WebSocketKit: `https://github.com/vapor/websocket-kit.git` (version 2.14.0+)

3. Select products to add:
   - NIO
   - NIOHTTP1
   - NIOWebSocket
   - WebSocketKit

### Step 4: Integrate NDI SDK

⚠️ **Critical**: This app requires the NDI SDK for iOS. Without it, the app will compile but won't stream.

1. **Download NDI SDK**:
   - Visit [https://ndi.tv/sdk/](https://ndi.tv/sdk/)
   - Download "NDI SDK for Apple" (includes iOS frameworks)
   - Extract the archive

2. **Add NDI Framework**:
   - Locate `NDI SDK for Apple/lib/iOS/libndi_iOS.xcframework` in the extracted SDK
   - Drag `libndi_iOS.xcframework` into your Xcode project
   - Select "Copy items if needed"
   - Add to AvoCam target

3. **Configure Framework**:
   - Project → AvoCam target → General → Frameworks, Libraries, and Embedded Content
   - Ensure `libndi_iOS.xcframework` is set to "Embed & Sign"

4. **Create Bridging Header** (if needed for C API):
   - File → New → File → Header File
   - Name: `AvoCam-Bridging-Header.h`
   - Add content:
   ```objc
   #import <libndi_iOS/libndi_iOS.h>
   ```
   - Project → AvoCam target → Build Settings → Swift Compiler - General
   - Set "Objective-C Bridging Header" to: `AvoCam/AvoCam-Bridging-Header.h`

5. **Implement NDI Integration**:
   - Open `Sources/NDI/NDIManager.swift`
   - Replace TODO sections with actual NDI SDK calls
   - See inline comments in file for guidance

### Step 5: Implement SwiftNIO Server

The NetworkServer is currently a stub. To complete it:

1. Study SwiftNIO examples: [https://github.com/apple/swift-nio-examples](https://github.com/apple/swift-nio-examples)
2. Implement HTTP request/response handling
3. Implement WebSocket upgrade and message handling
4. See inline TODOs in `Sources/Network/NetworkServer.swift`

Alternative: Consider using Vapor framework for easier HTTP/WS server implementation.

### Step 6: Build and Test

1. Connect an iPhone to your Mac
2. Select the device in Xcode
3. Build and run (⌘R)
4. Grant camera and network permissions when prompted
5. Check console for startup messages

## Project Structure

```
ios-app/AvoCam/
├── Sources/
│   ├── AvoCamApp.swift          # Main app entry point
│   ├── AppCoordinator.swift     # Central coordinator
│   ├── Capture/
│   │   └── CaptureManager.swift # AVFoundation video capture
│   ├── Encode/
│   │   └── EncoderManager.swift # VideoToolbox H.264 encoding
│   ├── NDI/
│   │   └── NDIManager.swift     # NDI|HX transmission (NEEDS SDK)
│   ├── Network/
│   │   ├── NetworkServer.swift  # HTTP/WS server (NEEDS IMPLEMENTATION)
│   │   └── BonjourService.swift # mDNS advertisement
│   ├── Models/
│   │   ├── APIModels.swift      # API data structures
│   │   └── TelemetryCollector.swift # System telemetry
│   └── UI/
│       └── ContentView.swift    # SwiftUI interface
├── Resources/
│   ├── Info.plist              # App configuration
│   └── AvoCam.entitlements     # Entitlements (multicast)
└── Package.swift               # Swift Package dependencies
```

## Key Configuration

### Info.plist Keys (Already Configured)

- ✅ `NSCameraUsageDescription` - Camera access
- ✅ `NSLocalNetworkUsageDescription` - Local network
- ✅ `NSBonjourServices` - `["_avolocam._tcp"]`
- ✅ `NSAppTransportSecurity` - Allow HTTP on LAN

### Entitlements (Already Configured)

- ✅ `com.apple.developer.networking.multicast` - Required for mDNS on iOS 14+

### Video Pipeline Settings (Already Implemented)

- ✅ Pixel format: `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`
- ✅ Color space: Rec.709 Full (primaries, matrix, transfer)
- ✅ VideoToolbox: Real-time, no B-frames, GOP=fps
- ✅ Bitrate: 10 Mbps baseline (8-12 Mbps range)
- ✅ Thermal management: Monitor and step down on serious/critical

## API Endpoints

The app exposes these REST endpoints on port 8888 (when fully implemented):

- `GET /api/v1/status` - Current status and telemetry
- `GET /api/v1/capabilities` - Supported formats
- `POST /api/v1/stream/start` - Start NDI stream
- `POST /api/v1/stream/stop` - Stop NDI stream
- `POST /api/v1/camera` - Adjust camera settings
- `POST /api/v1/encoder/force_keyframe` - Force IDR frame
- `GET /api/v1/logs.zip` - Download logs
- `GET /` - Web UI (minimal control page)

WebSocket telemetry: `ws://<ip>:8888/ws` (1Hz updates)

## Implementation Status

### ✅ Completed

- [x] Project structure
- [x] Info.plist configuration
- [x] Entitlements setup
- [x] API data models
- [x] AppCoordinator architecture
- [x] CaptureManager (AVFoundation)
- [x] EncoderManager (VideoToolbox with low-latency config)
- [x] TelemetryCollector
- [x] BonjourService (mDNS advertisement)
- [x] Basic SwiftUI interface

### 🚧 In Progress / TODO

- [ ] **NDI SDK integration** (see NDIManager.swift)
- [ ] **SwiftNIO server implementation** (see NetworkServer.swift)
- [ ] **Web UI HTML page** (embedded in app)
- [ ] **Rotating logs with zip download**
- [ ] **Testing on physical devices**
- [ ] **Performance tuning and latency optimization**

## Testing

### Local Testing (iOS Simulator)

⚠️ The iOS Simulator **cannot** access the camera or run NDI. You MUST use physical iPhones.

### Device Testing Checklist

1. **Network Setup**:
   - Connect iPhone to same WiFi as testing Mac/OBS machine
   - Ensure WiFi allows multicast (not guest network)
   - Verify mDNS works: `dns-sd -B _avolocam._tcp`

2. **Camera Permissions**:
   - First launch: grant camera access
   - Grant local network access

3. **Verify Bonjour**:
   - Check console for "Bonjour service published"
   - From Mac: `dns-sd -B _avolocam._tcp` should show your camera

4. **Test API**:
   - Find iPhone IP (Settings → WiFi → (i) button)
   - Test status: `curl -H "Authorization: Bearer <token>" http://<ip>:8888/api/v1/status`
   - Token is printed to console on first launch

5. **OBS Integration**:
   - Install NDI Plugin for OBS
   - Add NDI Source
   - Look for "AVOLO-CAM-XX" in source list
   - Verify video appears with correct colors

## Troubleshooting

### Build Errors

- **"Module 'NIO' not found"**: Add SwiftNIO packages in Xcode (Step 3)
- **"Undefined symbol: NDIlib_..."**: NDI SDK not integrated (Step 4)
- **"Could not read entitlements"**: Check entitlements file path in Build Settings

### Runtime Issues

- **Camera not starting**: Check Info.plist for `NSCameraUsageDescription`
- **Bonjour not advertising**: Verify multicast entitlement and `NSBonjourServices`
- **"Network permission denied"**: Check `NSLocalNetworkUsageDescription` and `NSAppTransportSecurity`
- **No NDI stream in OBS**: Check if NDIManager is fully implemented with SDK

### Performance Issues

- **High temperature**: Thermal management will step down bitrate automatically
- **Frame drops**: Check WiFi signal strength, try lower bitrate
- **High latency**: Verify GOP=fps, no B-frames, real-time encoder flags set

## Next Steps

1. **Complete Xcode project creation** (Step 1)
2. **Integrate NDI SDK** (Step 4) - most critical for actual streaming
3. **Implement SwiftNIO server** (Step 5) - needed for remote control API
4. **Test on physical iPhone** with OBS
5. **Measure latency** with LED clock method (target ≤150ms)
6. **Begin Tauri controller development** (separate project)

## Resources

- [NDI SDK Documentation](https://ndi.tv/sdk/)
- [SwiftNIO Examples](https://github.com/apple/swift-nio-examples)
- [AVFoundation Programming Guide](https://developer.apple.com/documentation/avfoundation)
- [VideoToolbox Reference](https://developer.apple.com/documentation/videotoolbox)
- [LOT A Checklist](../docs/LOT-A-CHECKLIST.md)

## Support

For issues and questions:
- Check inline code comments (especially in NDIManager and NetworkServer)
- Review [CLAUDE.md](../CLAUDE.md) for architecture details
- See [docs/specs.md](../docs/specs.md) for requirements
