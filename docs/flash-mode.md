# Mode Flash - Transport UDP/RTP Ultra Low-Latency

## Vue d'ensemble

Le **Mode Flash** est le 3ème mode de streaming d'AVOLO-CAM, conçu pour atteindre une latence glass-to-glass inférieure à 50ms. Il complète les modes existants :

| Mode | Transport | Latence | Usage |
|------|-----------|---------|-------|
| **NDI** | NDI SDK | ~150ms | Compatible OBS NDI plugin |
| **SRT** | Haivision SRT + MPEG-TS | ~100-200ms | Réseaux instables, CPU faible |
| **Flash** | UDP/RTP custom | **<50ms** | Monitoring local, réseaux stables |

## Architecture

```
iOS Camera                              OBS Plugin
┌──────────────────┐                   ┌───────────────────────────┐
│ CaptureManager   │                   │ UDPReceiver               │
│       ↓          │                   │ (port dynamique via mDNS) │
│ H264Encoder      │                   │       ↓                   │
│ (VideoToolbox)   │  UDP/RTP          │ JitterBuffer              │
│       ↓          │ ──────────────→   │ (ultra-low / stable)      │
│ RTPPacketizer    │                   │       ↓                   │
│ (RFC 6184)       │                   │ RtpDepacketizer           │
│       ↓          │                   │ (FU-A → NAL)              │
│ UDPTransmitter   │                   │       ↓                   │
└──────────────────┘                   │ AccessUnitAssembler       │
        ↑                              │ (NAL → frame)             │
        │  WebSocket (:8888)           │       ↓                   │
        │  - frame_info {rtp_ts, ...}  │ SyncStateMachine          │
        │  - request_idr               │       ↓                   │
        │  ← ← ← ← ← ← ← ← ← ← ← ← ← ← │ PlatformDecoder           │
        │                              │   ├─ macOS: VideoToolbox  │
        │  mDNS: _avolocam._tcp        │   └─ Win: Media Foundation│
        │  TXT: flash_udp_port=5001    │       ↓                   │
        └──────────────────────────────│ OBS Source Output         │
                                       └───────────────────────────┘
```

## Plan Initial

L'implémentation suit le plan défini dans la session de planification :

### Phase 1 : iOS Flash Transport ✅
- `RTPPacketizer.swift` - Packetisation RFC 6184 (Single NAL + FU-A)
- `UDPTransmitter.swift` - Envoi UDP via Network.framework
- `FlashManager.swift` - Coordinateur actor

### Phase 2 : Intégration iOS ✅
- `StreamingCoordinator.swift` - Support `.flash` mode
- `APIModels.swift` - `StreamingMode.flash` + params Flash
- `BonjourService.swift` - TXT record `flash_udp_port` dynamique

### Phase 3 : Tauri Controller ✅
- `models.rs` - `StreamingMode::Flash`
- `StreamSettingsPanel.svelte` - UI Flash mode
- `api.ts` - Params Flash dans les appels

### Phase 4 : OBS Plugin ✅
- `avolocam-source.cpp` - Source OBS complète
- `rtp-depacketizer.cpp` - Single NAL + FU-A + STAP-A
- `videotoolbox-decoder.mm` - Décodage HW macOS
- `mf-decoder.cpp` - Décodage HW Windows
- `websocket-client.cpp` - Réception frame_info + IDR request

## Corrections Importantes

### 1. Port UDP Dynamique (Multi-Caméra)

**Problème initial** : Port fixe 5000 empêchait plusieurs caméras sur le même PC.

**Solution** : Chaque caméra annonce son port via :
- mDNS TXT record : `flash_udp_port=5001`
- API HTTP : `GET /api/v1/status` → `flash_udp_port: 5001`

```swift
// iOS - BonjourService.swift
func updateFlashPort(_ port: UInt16) {
    // Met à jour le TXT record mDNS dynamiquement
}
```

### 2. Mapping RTP ↔ WebSocket (rtp_ts)

**Problème initial** : Impossible de corréler timestamps RTP avec timing de capture.

**Solution** : Message WebSocket `frame_info` avec `rtp_ts` explicite :

```json
{
  "op": "frame_info",
  "frame_idx": 12345,
  "rtp_ts": 2703456000,
  "capture_ts_ns": 1706745600123456789,
  "encode_ts_ns": 1706745600127000000
}
```

Le receiver OBS utilise `rtp_ts` pour matcher les paquets RTP reçus.

### 3. Fix Alignement Mémoire (Crash iOS)

**Problème** : `Fatal error: load from misaligned raw pointer` en 4K.

**Cause** : `UnsafeRawPointer.load(as: UInt32.self)` requiert alignement 4 bytes.

**Solution** : Lecture manuelle des bytes :
```swift
// Avant (crash)
let nalLength = lengthBytes.load(as: UInt32.self).bigEndian

// Après (safe)
let byte0 = UInt32(UInt8(bitPattern: pointer.advanced(by: offset)[0]))
let byte1 = UInt32(UInt8(bitPattern: pointer.advanced(by: offset + 1)[0]))
let byte2 = UInt32(UInt8(bitPattern: pointer.advanced(by: offset + 2)[0]))
let byte3 = UInt32(UInt8(bitPattern: pointer.advanced(by: offset + 3)[0]))
let nalLength = (byte0 << 24) | (byte1 << 16) | (byte2 << 8) | byte3
```

## Configuration

### iOS (StreamStartRequest)

```json
{
  "resolution": "1920x1080",
  "framerate": 25,
  "bitrate": 10000000,
  "codec": "h264",
  "streaming_mode": "flash",
  "flash_destination_host": "192.168.1.100",
  "flash_destination_port": 5000,
  "flash_jitter_mode": "ultra_low"
}
```

### OBS Plugin Properties

| Property | Description | Default |
|----------|-------------|---------|
| Camera IP | IP de la caméra iOS | - |
| UDP Port | Port Flash (depuis mDNS) | 5000 |
| Auth Token | Bearer token | - |
| Jitter Buffer | `ultra_low` (8ms) / `stable` (50ms) | stable |
| Prefer Zero-Copy | GPU texture directe | true |
| Show Latency | Overlay latence | false |

## Jitter Buffer

Deux modes configurables selon le réseau :

| Mode | Buffer | Latence | Usage |
|------|--------|---------|-------|
| **Ultra-low** | 0-8ms | Minimum | Ethernet, WiFi 6 stable |
| **Stable** | 16-50ms | Tolérant | WiFi variable, production |

**Comportement** :
- Time-based + reorder par sequence number
- Never wait for missing packets (drop silently)
- Gap detection → request IDR si >3 packets consécutifs perdus

## Sync State Machine

```
    ┌───────┐     frame complete      ┌────────────┐
    │ SYNC  │ ──────────────────────▶ │ SYNC       │
    └───────┘                         └────────────┘
        │                                    ▲
        │ packet loss /                      │
        │ decode error                       │
        ▼                                    │
    ┌────────────┐   IDR received     ┌────────────┐
    │ OUT_OF_SYNC│ ─────────────────▶ │ RESYNC     │
    │ (drop all) │                    │ (wait IDR) │
    └────────────┘                    └────────────┘
        │                                    │
        └──── request_idr via WS ────────────┘
```

## Fichiers Créés

### iOS App
```
ios-app/AvoCam/AvoCam/Sources/RTP/
├── RTPPacketizer.swift      # RFC 6184 packetisation
├── UDPTransmitter.swift     # Network.framework UDP
└── FlashManager.swift       # Coordinateur actor
```

### OBS Plugin
```
obs-avolocam-plugin/
├── CMakeLists.txt
├── src/
│   ├── plugin-main.cpp
│   ├── avolocam-source.cpp/h
│   ├── udp-receiver.cpp/h
│   ├── jitter-buffer.cpp/h
│   ├── rtp-depacketizer.cpp/h
│   ├── access-unit-assembler.cpp/h
│   ├── sync-state-machine.cpp/h
│   ├── timestamp-mapper.cpp/h
│   ├── mdns-discovery.cpp/h
│   ├── websocket-client.cpp/h
│   ├── texture-output.h
│   ├── texture-output-macos.mm
│   ├── texture-output-windows.cpp
│   └── decoder/
│       ├── platform-decoder.h
│       ├── videotoolbox-decoder.mm   # macOS HW
│       └── mf-decoder.cpp            # Windows HW
└── packaging/
    ├── macos/build-pkg.sh
    └── windows/installer.iss
```

## Budget Latence Théorique

| Étape | Ultra-low | Stable |
|-------|-----------|--------|
| Sensor exposure (25fps) | 40ms | 40ms |
| iOS capture queue | 1ms | 1ms |
| VideoToolbox encode | 4ms | 4ms |
| RTP packetization | <1ms | <1ms |
| Network (WiFi 6 LAN) | 2ms | 2ms |
| Jitter buffer | **0-8ms** | **16-50ms** |
| NAL reassembly | <1ms | <1ms |
| Hardware decode | 4ms | 4ms |
| OBS render + vsync | 16ms | 16ms |
| **Total** | **~65-75ms** | **~85-120ms** |

Note: À 25fps, l'exposure time (40ms) est le facteur dominant. Pour <50ms total, 60fps serait nécessaire.

## Prochaines Étapes

- [ ] Tests multi-caméra (2+ iPhones vers même PC)
- [ ] Profiling latence réelle avec timestamps instrumentés
- [ ] GPU zero-copy effectif (IOSurface/D3D11)
- [ ] Tests stabilité 1h+
- [ ] Packaging final (.pkg / .exe)
