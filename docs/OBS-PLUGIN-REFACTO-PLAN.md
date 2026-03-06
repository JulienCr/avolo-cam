# Plan de Refactoring - OBS AvoCam Plugin

> **Status**: Draft - En attente des findings du bughunting pour compléter
> **Scope**: ~8000 LOC C++ dans `obs-avolocam-plugin/src/`
> **Objectif**: Passer d'un prototype vibe-codé à un codebase maintenable et testable

---

## Diagnostic

### Ce qui marche
- Architecture en couches correcte (UDP → JitterBuffer → RTP → Decoder → Texture)
- `unique_ptr` partout pour les composants pipeline
- Memory ordering explicite sur les chemins critiques (release/acquire)
- Double-buffering frames et triple-buffering textures GPU

### Ce qui est cassé

| Problème | Sévérité | Impact |
|----------|----------|--------|
| `SourceData` = God Object (120+ membres, 1876 lignes) | CRITIQUE | Impossible à tester, modifier, ou comprendre |
| Zéro tests unitaires | CRITIQUE | Aucune protection contre les régressions |
| `decode_frame_async()` 192 lignes, 5+ responsabilités | HAUTE | Spaghetti GPU init + decode + output |
| 73 `static_cast<void*>` pour les handles D3D11 | HAUTE | Pas de type safety, risque de cast foireux |
| Ref-counting manuel sur `g_shared_d3d_device` | HAUTE | Use-after-free si lifetime rate |
| Frames droppées en silence (pas de log) | MOYENNE | Impossible de diagnostiquer les pertes |
| Duplication RTP parsing, cleanup GPU, logging | MOYENNE | Maintenance x2 |
| `<mfapi.h>` inclus sans `#ifdef _WIN32` | BASSE | Build cassé sur d'autres plateformes |

---

## Phases de Refactoring

### Phase -1 — Hotfixes critiques
> **Priorité**: IMMÉDIATE — bugs actifs en production
> **Effort**: ~0.5 jour
> **Risque**: BAS — fixes chirurgicaux, pas de refactoring

3 bugs confirmés par le bughunting nécessitent un fix immédiat, avant toute refacto :

**1. BUG-1 — Brancher la sync state machine** (`sync-state-machine.cpp`, `avolocam-source.cpp`)
- Appeler `sync_state->on_decode_error()` quand `decoder->decode()` retourne `false`
- Appeler `sync_state->on_packet_loss()` dans le depacketizer quand `seq != expected_seq + 1`
- ~10 lignes de code

**2. BUG-2 — Fix flash mode drain loop** (`udp-receiver.cpp:100-106`)
- Quand `timeout_ms == 0` : utiliser `select()` avec `tv = {0, 0}` au lieu de skip
- Alternative : passer le socket en `FIONBIO` au bind
- ~5 lignes de code

**3. BUG-3 — Release IMFSample après consommation** (`avolocam-source.cpp`, `texture-output-windows.cpp`)
- Après que `texture-output` a consommé le `platform_handle`, appeler `static_cast<IMFSample*>(frame.platform_handle)->Release()`
- Fix temporaire en attendant le ComPtr Phase 2
- ~3 lignes de code

---

### Phase 0 — Filet de sécurité (Tests)
> **Priorité**: Faire AVANT tout refactoring
> **Effort**: ~2-3 jours

Ajouter des tests unitaires sur les composants qui ont des edge cases critiques et qui sont déjà isolés (pas besoin de toucher à `SourceData`).

**Composants à tester en priorité**:

1. **`RtpDepacketizer`** — Le plus risqué
   - Single NAL passthrough
   - STAP-A avec 1, 2, N NALs agrégés
   - FU-A fragmentation: start/middle/end, paquets manquants, réordonnés
   - Paquets malformés (trop courts, type invalide)
   - Multi-SSRC (streams croisés)

2. **`JitterBuffer`** — Edge cases timing
   - Insertion en ordre, hors ordre, dupliqués
   - Timeout et flush de paquets vieux
   - Mode ultra-low (bypass)
   - Overflow du buffer

3. **`AccessUnitAssembler`** — Assemblage de frames
   - NALs avec même timestamp → 1 AU
   - Marker bit → flush AU
   - Cache SPS/PPS
   - Cleanup des AU pending > 16

4. **`SyncStateMachine`** — FSM simple mais critique
   - Transitions SYNC → OUT_OF_SYNC → RESYNC → SYNC
   - Drop de NALs hors sync
   - Re-sync sur IDR

**Setup**:
- Framework: Google Test (header-only, pas de deps lourdes)
- CMake: cible `obs-avolocam-tests` séparée
- CI: Faire tourner les tests sur chaque PR

---

### Phase 1 — Éclater le God Object `SourceData`
> **Priorité**: HAUTE — bloquant pour toute évolution
> **Effort**: ~3-4 jours
> **Risque**: MOYEN — nécessite le filet de tests Phase 0

`SourceData` (120+ membres) doit être découpé en responsabilités claires:

```
SourceData (orchestrateur léger, ~30 membres max)
  ├── PipelineConfig          — Configuration snapshot (IP, port, mode, token)
  ├── ReceivePipeline         — UDP + JitterBuffer + RTP + Assembler
  ├── DecodePipeline          — Queue + Decoder + GPU converter
  ├── RenderBridge            — Shared handles, texture cache, CPU fallback
  ├── TelemetryCollector      — Atomics, WS telemetry, stats agrégées
  └── TestPatternGenerator    — Texture, font, rendu "NO SIGNAL"
```

**Détail des nouvelles classes**:

#### `PipelineConfig`
```cpp
struct PipelineConfig {
    std::string camera_ip;
    uint16_t camera_port;
    int jitter_mode;
    std::string auth_token;
    bool prefer_zero_copy;
    bool debug_mode;
    int decoder_type;
    mutable std::mutex mutex;  // Protège les strings

    PipelineConfig snapshot() const;  // Copie thread-safe
};
```

#### `ReceivePipeline`
Encapsule: `UdpReceiver`, `JitterBuffer`, `RtpDepacketizer`, `AccessUnitAssembler`, `SyncStateMachine`
- Expose `start(config, callback)` / `stop()`
- Le callback `on_access_unit(AccessUnit&&)` remplace le couplage direct avec la decode queue
- Gère son propre thread
- Gère l'enregistrement/désenregistrement du port dans `g_bound_ports`

#### `DecodePipeline`
Encapsule: decode queue, `PlatformDecoder`, `GPUConverter`, double-buffering frames
- Expose `start(on_gpu_frame, on_cpu_frame)` / `stop()`
- `push(AccessUnit&&)` — appelé par ReceivePipeline
- `on_gpu_frame(shared_handle, width, height)` — callback vers RenderBridge
- `on_cpu_frame(LatestFrame*)` — callback vers RenderBridge
- Gère son propre thread
- Encapsule toute la logique d'init decoder, GPU converter, fallback CPU

#### `RenderBridge`
Encapsule: `latest_shared_handle_`, `obs_shared_texture_`, `cpu_fallback_texture_`, cache
- Méthodes appelées depuis le render thread OBS uniquement
- `update_gpu_frame(shared_handle, w, h)` — appelé par DecodePipeline (atomic store)
- `video_tick()` — ouvre/cache shared texture
- `video_render(effect)` — dessine
- `get_width() / get_height()`

#### `TelemetryCollector`
Encapsule: tous les atomics de stats, `WebSocketClient`, `TimestampMapper`
- `on_frame_received()`, `on_frame_decoded()`, `on_frame_dropped(reason)`
- `get_stats()` → struct agrégée
- Gère la connexion WS et le tally

#### `TestPatternGenerator`
Encapsule: `test_pattern_texture_`, font glyphs, rendu
- `ensure_created(gs_context, ip, name)`
- `get_texture()` → `gs_texture_t*`
- `get_width() / get_height()`
- Déjà presque isolé (fonctions `generate_test_pattern_rgba` et `render_text_to_rgba`)

**Résultat attendu pour `SourceData`**:
```cpp
struct SourceData {
    obs_source_t *source;
    PipelineConfig config;
    ReceivePipeline receive;
    DecodePipeline decode;
    RenderBridge render;
    TelemetryCollector telemetry;
    TestPatternGenerator test_pattern;

    void start();  // Wire pipelines, start all
    void stop();   // Stop all, unwire
};
```

---

### Phase 2 — Type Safety GPU (RAII + ComPtr)
> **Priorité**: HAUTE — élimine une classe entière de bugs
> **Effort**: ~2 jours

**Problème**: 73 `static_cast<void*>` pour les handles D3D11. Aucune type safety.

**Solution**: Introduire des wrappers typés.

#### 2a. ComPtr wrapper
```cpp
// src/d3d11-utils.h
template<typename T>
class ComPtr {
    T* ptr_ = nullptr;
public:
    ~ComPtr() { if (ptr_) ptr_->Release(); }
    T** operator&() { return &ptr_; }
    T* operator->() { return ptr_; }
    T* get() const { return ptr_; }
    void reset() { if (ptr_) { ptr_->Release(); ptr_ = nullptr; } }
    // Move semantics, no copy
};
```

**Fichiers impactés**:
- `gpu-converter.cpp` — `ID3D11Device*`, `ID3D11ComputeShader*`, pool textures
- `texture-output-windows.cpp` — staging textures, shared texture cache
- `ffmpeg-d3d11va-decoder.cpp` — device, context, shared pool
- `mf-decoder.cpp` — device, context, staging, MFT, device manager

#### 2b. Typed handles au lieu de `void*`

Remplacer dans `platform-decoder.h`:
```cpp
// AVANT
void *platform_handle = nullptr;
void *d3d_texture = nullptr;
void *d3d_shared_handle = nullptr;

// APRÈS
#ifdef _WIN32
ID3D11Texture2D *gpu_texture = nullptr;
HANDLE shared_handle = nullptr;
#endif
```

Cela élimine les 73 `static_cast` et rend les erreurs de type visibles à la compilation.

#### 2c. Shared D3D11 device avec RAII

Remplacer le ref-counting manuel dans `mf-decoder.cpp`:
```cpp
// AVANT (fragile)
static ID3D11Device *g_shared_d3d_device = nullptr;
static int g_shared_d3d_refcount = 0;

// APRÈS
class SharedD3D11Device {
    ComPtr<ID3D11Device> device_;
    ComPtr<ID3D11DeviceContext> context_;
    std::mutex mutex_;
    int refcount_ = 0;
public:
    ID3D11Device* acquire();   // ++refcount, create if needed
    void release();            // --refcount, destroy if 0
};
static SharedD3D11Device g_shared_device;
```

---

### Phase 3 — Refactorer les fonctions longues
> **Priorité**: MOYENNE
> **Effort**: ~2 jours

#### `decode_frame_async()` (192 lignes → 4 fonctions)

```cpp
// AVANT: 1 fonction qui fait tout
void decode_frame_async(const AccessUnit& au);

// APRÈS: responsabilités séparées
bool ensure_decoder_initialized(const AccessUnit& au);
DecodedFrame decode_access_unit(const AccessUnit& au);
void process_gpu_frame(DecodedFrame& frame);
void process_cpu_frame(DecodedFrame& frame);
```

#### `receive_loop()` (151 lignes → extraction du processing)

```cpp
// AVANT: bind + receive + process + tally dans une boucle
void receive_loop();

// APRÈS:
bool bind_and_register_port(uint16_t port);
void unregister_port(uint16_t port);
void poll_tally_and_heartbeat();
// receive_loop() ne fait plus que la boucle de réception
```

#### `start()` (179 lignes → extraction des phases)

```cpp
// AVANT: tout dans start()
void start();

// APRÈS:
PipelineConfig snapshot_config();
bool create_pipeline_components(const PipelineConfig& cfg);
void setup_websocket(const PipelineConfig& cfg);
void spawn_threads();
bool wait_for_bind_result();
```

---

### Phase 4 — Logging structuré
> **Priorité**: MOYENNE
> **Effort**: ~1 jour

**Problème**: Frames droppées en silence, 30+ appels `blog()` avec format inconsistant.

```cpp
// src/avolocam-log.h
#define AVOLOG_ERROR(fmt, ...) blog(LOG_ERROR, "[avolocam] " fmt, ##__VA_ARGS__)
#define AVOLOG_WARN(fmt, ...)  blog(LOG_WARNING, "[avolocam] " fmt, ##__VA_ARGS__)
#define AVOLOG_INFO(fmt, ...)  blog(LOG_INFO, "[avolocam] " fmt, ##__VA_ARGS__)
#define AVOLOG_DEBUG(fmt, ...) do { if (debug_mode_) blog(LOG_DEBUG, "[avolocam] " fmt, ##__VA_ARGS__); } while(0)

// Frame drops ne sont plus silencieux
enum class DropReason { NO_DECODER, NOT_INITIALIZED, NO_Y_PLANE, QUEUE_FULL, SYNC_LOST };
void log_frame_drop(DropReason reason, uint64_t total_drops);
```

**Fichiers impactés**: Tous les `.cpp` (remplacement mécanique de `blog()`)

---

### Phase 5 — Include hygiene & Platform guards
> **Priorité**: BASSE
> **Effort**: ~0.5 jour

1. **`<mfapi.h>` non gardé** dans `avolocam-source.cpp` → `#ifdef _WIN32`
2. **Forward declarations** dans les headers (ex: `class TimestampMapper;` au lieu de `#include`)
3. **Éliminer les includes redondants** (`platform-decoder.h` inclus 2x via des chemins différents — pas grave avec `#pragma once` mais sale)
4. **Ordonner les includes**: OBS headers → project headers → system headers

---

## Ordre d'exécution

```
Phase -1 (Hotfixes) ←── IMMÉDIAT, bugs actifs
  │
  │  BUG-1: Brancher sync state machine
  │  BUG-2: Fix drain loop bloquant
  │  BUG-3: Release IMFSample
  │
  ▼
Phase 0 (Tests)
  │
  ├── Peut commencer immédiatement après hotfixes
  │   Inclure tests de non-régression pour BUG-1, BUG-2, BUG-3
  │
  ▼
Phase 1 (Éclater SourceData) ──┐
  │                             ├── BUG-4 résolu (RenderBridge lifecycle)
  ▼                             │
Phase 2 (Type Safety GPU) ─────┘── BUG-3 éliminé (ComPtr), BUG-4 éliminé (pool RAII)
  │
  ├── Peut être en parallèle avec Phase 3
  │
  ▼
Phase 3 (Fonctions longues)
  │
  ▼
Phase 4 (Logging) ──────────── Peut être fait à n'importe quel moment
  │
  ▼
Phase 5 (Include hygiene) ──── Peut être fait à n'importe quel moment
```

**Dépendances dures**:
- Phase -1 → Phase 0 (hotfixes d'abord, tests ensuite pour verrouiller)
- Phase 0 → Phase 1 (pas de refacto structurel sans tests)
- Phase 1 → Phase 3 (les fonctions longues sont dans SourceData)

**Indépendants**:
- Phase 4 et 5 peuvent être faits à tout moment
- Phase 2 peut être faite en parallèle de Phase 1 (fichiers différents)

---

## Bughunting — 4 bugs confirmés

> Source: `docs/bug-hunt-report.md` — scan systématique avec adversarial validation
> 21 findings initiaux → 19 après dédup → **4 confirmés**, 15 faux positifs rejetés

### Bugs confirmés et mapping refacto

#### BUG-1: Sync resync = dead code (CERTAIN, High)
**Loc**: `sync-state-machine.cpp:51-66`
`on_decode_error()` et `on_packet_loss()` ne sont **jamais appelés**. La state machine ne peut jamais passer en `OUT_OF_SYNC`. Après une perte de paquet, des frames corrompues continuent d'alimenter le décodeur jusqu'au prochain keyframe naturel (~1s à GOP=30).

**Fix**: Appeler `on_decode_error()` quand `decode()` retourne false, `on_packet_loss()` sur gap de séquence RTP.
**Phase**: Hotfix immédiat (indépendant du refacto) + test unitaire Phase 0

#### BUG-2: Flash mode drain loop bloque indéfiniment (HIGH, High)
**Loc**: `udp-receiver.cpp:100-152`, `avolocam-source.cpp:552-560`
Le socket UDP est bloquant. La drain loop passe `timeout_ms=0` en pensant que c'est non-bloquant, mais `select()` est skippé quand `timeout_ms == 0` → `recvfrom()` bloque le thread receive indéfiniment.

**Fix**: `select()` avec timeout zero quand `timeout_ms == 0`, ou socket `FIONBIO`.
**Phase**: Hotfix immédiat + test unitaire Phase 0

#### BUG-3: IMFSample leak — 1800 objets COM/min (HIGH, Critical)
**Loc**: `mf-decoder.cpp:1192-1204`
`DecodedFrame::platform_handle` stocke un `IMFSample*` en `void*` sans jamais appeler `Release()`. Chaque frame GPU MF fuit un objet COM. À 30fps = OBS freeze/crash en quelques minutes.

**Fix immédiat**: `Release()` explicite après consommation du frame.
**Fix propre**: Phase 2 (ComPtr RAII sur `platform_handle`). Ce bug disparait complètement avec les typed handles.

#### BUG-4: GPU texture pool race condition (MEDIUM, Medium)
**Loc**: `gpu-converter.cpp`, `avolocam-source.cpp:866-868`
`release_frame()` remet le slot dans le pool immédiatement après le store atomique du shared handle. Le render thread n'a peut-être pas encore ouvert le handle → le slot est réutilisé → texture détruite → handle invalidé → corruption ou crash.

**Fix**: Déférer `release_frame()` jusqu'à ce que `video_tick` ait ouvert le handle, ou agrandir le ring de handles.
**Phase**: Phase 1 (RenderBridge gère le lifecycle) ou Phase 2 (pool RAII avec release différé)

### Impact sur le plan de refactoring

| Bug | Timing | Phase associée |
|-----|--------|----------------|
| BUG-1 (sync dead code) | **Hotfix AVANT refacto** | + test Phase 0 |
| BUG-2 (drain loop block) | **Hotfix AVANT refacto** | + test Phase 0 |
| BUG-3 (IMFSample leak) | **Hotfix AVANT refacto** | Éliminé proprement par Phase 2 |
| BUG-4 (texture pool race) | Peut attendre Phase 1/2 | Éliminé par RenderBridge ou ComPtr pool |

### Bugs éliminés structurellement par le refactoring

| Phase | Bugs éliminés | Mécanisme |
|-------|---------------|-----------|
| Phase 0 (Tests) | Détection régression BUG-1, BUG-2 | Tests sur SyncStateMachine, UdpReceiver |
| Phase 1 (Éclater SourceData) | BUG-4 partiellement | RenderBridge contrôle le lifecycle texture |
| Phase 2 (Type Safety GPU) | BUG-3 totalement, BUG-4 totalement | ComPtr = impossible de fuir un IMFSample. Pool RAII = release différé garanti |
| Phase 4 (Logging) | Visibilité sur BUG-1 | Les frame drops sont loggés avec la raison |

---

## Métriques de succès

| Métrique | Avant | Cible |
|----------|-------|-------|
| Taille max d'un fichier | 1876 LOC | < 500 LOC |
| Membres dans SourceData | 120+ | < 30 |
| Fonction la plus longue | 192 lignes | < 60 lignes |
| `static_cast<void*>` | 73 | 0 |
| Tests unitaires | 0 | > 50 |
| Drops silencieux | ~10 sites | 0 |
| Couverture des composants testés | 0% | > 80% (composants Phase 0) |
