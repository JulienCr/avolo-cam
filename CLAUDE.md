# CLAUDE.md

## Commands

```bash
# Build
make build          # Build all (iOS + Tauri + OBS)
make build-ios      # Build iOS Ad Hoc IPA (runs ios-app/AvoCam/build-ipa.sh)
make build-tauri    # Build Tauri desktop app (pnpm install + tauri build)
make build-obs      # Build OBS plugin (cmake Release)
make install-obs    # Build + install OBS plugin to OBS dir (Windows, UAC)
make clean          # Clean all build artifacts
make debug-ios      # Debug build + install + live console logs on connected iPhones

# Dev
cd tauri-controller && pnpm install && pnpm dev              # Dev mode
cd tauri-controller && pnpm dev:verbose                      # Verbose dev mode (RUST_LOG=debug)

# OBS plugin (macOS local build)
cd obs-avolocam-plugin && cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build --config Release
```

**Package manager**: Always use `pnpm`, never `npm` or `yarn`.

## Architecture

Three components — see [README.md](README.md) for full details.

```
ios-app/AvoCam/      Swift / AVFoundation / VideoToolbox — capture, H.264 encode, stream, control API (SwiftNIO HTTP/WS)
obs-avolocam-plugin/ C++17 OBS plugin — Flash RTP receiver + HW decode (FFmpeg D3D11VA, GPU NV12→RGBA)
tauri-controller/    Rust+Tokio backend + Svelte 5 frontend — mDNS discovery, telemetry, group control
```

### Streaming Modes

The iOS app supports 3 transport modes, selectable via `POST /api/v1/stream/start` (`StreamingMode` enum):

| Mode | Transport | OBS Integration | Latency |
|------|-----------|-----------------|---------|
| `ndi` | NDI\|HX (SDK) | Standard OBS NDI Source plugin | ~100-150ms |
| `srt` | SRT/UDP + MPEG-TS | OBS Media Source | Configurable |
| `flash` | RTP/UDP RFC 6184 (FU-A) | Custom `obs-avolocam-plugin` (source: "AvoCam Flash Source", id `avolocam_source`) | ~40-80ms |

- **SRT**: iOS listens (`srt://0.0.0.0:<port>`, MPEG-TS); OBS connects as caller via a Media Source.
- **Flash**: dynamic UDP port starting at **5000** (5001 for the 2nd camera on the same PC, etc.), advertised via mDNS TXT `flash_udp_port` and `GET /api/v1/status`.

### Control Plane

- HTTP REST API on port **8888** (Bearer token auth, SwiftNIO server)
- WebSocket `ws://<ip>:8888/ws` for telemetry (1Hz) and bidirectional commands
- `GET /` serves an embedded web UI for standalone control
- mDNS `_avolocam._tcp.local.` with TXT records (`alias`, `protocol`, `token`, `ws_port`, `flash_udp_port`, stream info); token in TXT is by design for LAN-only zero-config auth

### Ecosystem

The Flash plugin's OBS source instances (named e.g. `Flash - Cam Main` in OBS scenes) must match the scene/source naming used by `xtouch-gw-v3` and the `obs-manager` collections. The plugin source *type* is "AvoCam Flash Source" (id `avolocam_source`); per-instance scene names are operator-chosen and shared with those tools. (`xtouch-gw-v3`/`obs-manager` live in separate repos — exact names not verifiable here.)

## Key Technical Constraints

- **Color**: Rec.709 Full range end-to-end, all modes
- **H.264**: CBR, High 4.2, GOP=fps, B-frames=0, RealTime=true
- **Resolution**: Up to 4K (3840x2160), with presets in `VideoSettings.swift`
- **Latency target**: ≤150ms glass-to-glass (Flash mode: ~40-80ms)
- **Stability target**: ≥2h streaming, <1% frame drops

## Code Style & Conventions

- **iOS**: Swift, async/await, AVFoundation + VideoToolbox
- **OBS Plugin**: C++17, raw COM `Release()` calls (not ComPtr)
- **Controller**: Rust (Tokio async), Svelte 5 frontend, Tailwind CSS
- **API errors**: Uniform `{"code": "ERROR_CODE", "message": "Human readable"}`

## Gotchas

- **OBS plugin COM**: Uses raw `Release()`, not ComPtr — watch for leak paths on error returns
- **GPU converter shutdown**: `GPUConverter::shutdown()` skips if `!initialized_` — partial init must clean up inline
- **Texture pool**: Slots must be nulled after `Release()` to prevent double-free on resize failure
- **D3D11 `GetResource()`**: Adds a ref that must be explicitly released
- **GPU code path**: Currently disabled (`if (false && ...)` in `avolocam-source.cpp:672`)
- **OBS plugin macOS**: Builds with local OBS SDK headers from `deps/obs-studio-32.0.4`
- **Windows build**: Requires OBS SDK, Bonjour SDK, Media Foundation libs; `NO_MDNS_DISCOVERY` disables Bonjour

## API Quick Reference

All endpoints require Bearer token. Port 8888. Routes registered in `NetworkServer.swift`.

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/v1/status` | GET | Parameters + telemetry + capabilities |
| `/api/v1/capabilities` | GET | Supported resolutions/FPS/codecs per lens |
| `/api/v1/video/settings` | GET / PUT | Read / update video settings |
| `/api/v1/stream/start` | POST | Start stream (`{streaming_mode, resolution, framerate, bitrate, codec, ...}`) |
| `/api/v1/stream/stop` | POST | Stop stream |
| `/api/v1/camera` | POST | Camera settings (WB, ISO, shutter, focus, zoom) |
| `/api/v1/camera/wb/measure` | POST | Grey-card white-balance measurement |
| `/api/v1/screen/brightness` | POST | Screen dim control |
| `/api/v1/settings/alias` | PUT | Rename camera (alias) |
| `/api/v1/torch/level` | GET / PUT | Torch level (tally feedback) |
| `/api/v1/logs.zip` | GET | Download rotating logs |

> `POST /api/v1/encoder/force_keyframe` is documented in `ios-app/SWIFTNIO_SERVER_TESTING.md` but **not currently registered** in `NetworkServer.swift`. Flag before relying on it.

Full API contracts and payloads: [docs/specs.md](docs/specs.md)

## Roadmap

### Active Development

**Lot A - MCP Core** — Single app build, multi-transport streaming (NDI/SRT/Flash up to 4K), Tauri controller with discovery + grid + group control. Target: ≥3 iPhones, ≥2h stable.

### Planned Enhancements (by complexity)

| Feature | Complexity | Notes |
|---------|-----------|-------|
| Audio capture (AAC) | Low | Add mic capture + AAC encoding, mux into existing transports |
| USB transport via usbmuxd | Medium | Zero packet loss, ~1-2ms transport. Tunnel existing TCP protocol over Lightning/USB-C |
| 120 FPS support | Medium | VideoToolbox supports it, needs UI + transport validation |
| HDR HLG / BT.2020 | High | `ContentLightLevelInfo` + `MasteringDisplayColorVolume` VT props, OBS color space handling |
| Android support | High | Rewrite iOS app in Kotlin, same API surface |

### Lot B-E (existing roadmap)

- **Lot B**: Reconnect logic, thermal management, RSSI telemetry, settings profiles
- **Lot C**: Orientation lock, lens selection, anti-banding, WB presets, test patterns
- **Lot D**: Diagnostics endpoint, log download, telemetry charts, config backup/restore
- **Lot E**: Adaptive bitrate, NTP timestamps, TLS, Ethernet detection, LUT/HDR→SDR

## Project-Local Plugins

- **bug-hunters** (`obs-avolocam-plugin/.claude/plugins/bug-hunters/`) — Systematic bug hunting for the OBS plugin. **Always use this plugin's workflow (orchestrator + logic-hunter/cpp-hunter) for bug hunting on the OBS plugin instead of generic agents.**

## Resources

- [docs/specs.md](docs/specs.md) — Full specifications and API contracts
- [docs/LOT-A-CHECKLIST.md](docs/LOT-A-CHECKLIST.md) — Lot A task breakdown
- [docs/flash-mode.md](docs/flash-mode.md) — Flash mode implementation details
- [docs/PERFORMANCE_OPTIMIZATIONS.md](docs/PERFORMANCE_OPTIMIZATIONS.md) — Performance guide
