# Tentatives d'Optimisation de la Latence - Windows MF Decoder

**Date**: 31 Janvier 2026
**Objectif**: Réduire la latence de ~200ms à <100ms
**Résultat**: Échec - latence reste à ~200ms

---

## Contexte

Le plugin OBS reçoit un flux H.264 via UDP depuis une app iOS, le décode avec Media Foundation (D3D11VA hardware), et l'affiche dans OBS.

### Pipeline Actuelle

```
iOS (H.264 encode) → UDP → Jitter Buffer → RTP Depacketizer →
Access Unit Assembler → Decode Queue → MF Decoder (D3D11VA) →
Lock2D (GPU→CPU sync) → memcpy → obs_source_output_video → OBS
```

### Sources de Latence Identifiées

| Composant | Latence Estimée |
|-----------|-----------------|
| Jitter Buffer (mode stable) | 50ms |
| Decode Queue (3 frames) | 100ms |
| MF Decoder internal | 33ms |
| Lock2D (GPU→CPU sync) | 10-50ms |
| OBS processing | ~10ms |
| **Total** | **~200ms** |

---

## Tentative 1: GPU Zero-Copy Path

### Objectif
Éliminer le `Lock2D` (synchronisation GPU→CPU) en gardant les données sur GPU.

### Implémentation

1. **Extraction texture GPU du décodeur MF**
   - `IMFDXGIBuffer::GetResource()` pour obtenir `ID3D11Texture2D`
   - Fonctionne ✅

2. **Conversion NV12→RGBA sur GPU**
   - Compute shader HLSL custom
   - Texture staging NV12 avec `D3D11_BIND_SHADER_RESOURCE` (la texture MF n'a pas ce flag)
   - `CopySubresourceRegion` vers staging
   - Shader avec `PlaneSlice` pour Y/UV planes (nécessite D3D11.3, `CreateShaderResourceView1`)
   - Fonctionne ✅

3. **Partage cross-device avec OBS**
   - Le décodeur MF utilise son propre device D3D11
   - OBS utilise un device D3D11 différent
   - Solution: DXGI Shared Textures (`D3D11_RESOURCE_MISC_SHARED`)
   - `OpenSharedResource()` pour ouvrir la texture sur le device OBS
   - Fonctionne ✅ (après cache pour éviter `OpenSharedResource` à chaque frame)

4. **Rendu dans OBS**
   - Mode hybride: `OBS_SOURCE_ASYNC_VIDEO | OBS_SOURCE_VIDEO`
   - Callback `video_render` pour dessiner la texture GPU
   - `gs_draw_sprite()` avec la texture RGBA

### Résultat: ÉCHEC ❌

**Symptôme**: Framerate chute de 30fps à ~12fps

**Causes identifiées**:

1. **`obs_enter_graphics()` dans le thread de décodage**
   - Le thread de décodage doit acquérir le mutex graphics
   - Bloque le thread de rendu OBS
   - Crée une contention sévère

2. **Trop d'opérations GPU par frame**
   ```
   CopySubresourceRegion (MF → staging NV12)
   Compute Shader Dispatch (NV12 → RGBA)
   CopyResource (RGBA decoder device → shared)
   OpenSharedResource (cache miss = lent)
   CopyResource (shared → OBS texture)
   ```

3. **Mode hybride source OBS problématique**
   - `OBS_SOURCE_ASYNC_VIDEO | OBS_SOURCE_VIDEO` peut causer des rendus doubles
   - L'architecture n'est pas conçue pour ce cas d'usage

### Code Concerné

- `mf-decoder.cpp`: `process_output_gpu()`
- `gpu-converter.cpp`: Compute shader NV12→RGBA
- `texture-output-windows.cpp`: `prepare_gpu_frame()`, `output_via_d3d11()`
- `avolocam-source.cpp`: `video_render` callback

---

## Tentative 2: Async Staging Double-Buffer

### Objectif
Éviter le blocage `Lock2D` en lisant le frame précédent pendant que le GPU décode le frame courant.

### Implémentation

```cpp
// Double buffer staging textures
ID3D11Texture2D *staging_textures_[2];

// Frame N: GPU decode → CopySubresourceRegion → staging[0]
// Frame N+1: GPU decode → staging[1], CPU reads staging[0] (no wait)
```

- `D3D11_MAP_FLAG_DO_NOT_WAIT` pour éviter le blocage
- Fallback sur attente si GPU pas prêt

### Résultat: ÉCHEC ❌

**Symptôme**: Pas d'amélioration de latence, parfois perte de connexion

**Causes**:
- Le premier frame retourne `false` (pas de frame précédent à lire)
- Pipeline de +1 frame de latence (annule le gain)
- Complexité ajoutée sans bénéfice

---

## Tentative 3: Réduction des Buffers

### Changements

| Buffer | Avant | Après |
|--------|-------|-------|
| Decode Queue | 3 frames | 2 frames |
| Jitter Buffer | 50ms | 50ms (configurable) |

### Résultat: ÉCHEC PARTIEL ⚠️

- Queue = 1: Connexion échoue (trop agressif)
- Queue = 2: Fonctionne mais latence toujours ~200ms
- Le gain de 33ms est absorbé ailleurs dans la pipeline

---

## État Actuel du Code

### Fichiers Modifiés

```
src/decoder/mf-decoder.cpp      - GPU path + async staging (désactivé)
src/decoder/mf-decoder.h        - Staging textures, flags
src/gpu-converter.cpp           - Compute shader NV12→RGBA
src/gpu-converter.h             - GPUConverter class
src/texture-output-windows.cpp  - prepare_gpu_frame, shared texture cache
src/texture-output.h            - GPU output interface
src/avolocam-source.cpp         - video_render callback (désactivé)
```

### Flags Actuels

```cpp
// mf-decoder.h
bool gpu_output_enabled_ = false;  // GPU path désactivé
bool use_async_staging_ = false;   // Async staging désactivé

// avolocam-source.cpp
MAX_DECODE_QUEUE_SIZE = 2;         // Réduit de 3
info.output_flags = OBS_SOURCE_ASYNC_VIDEO;  // Mode sync uniquement
```

---

## Prochaine Étape: FFmpeg + d3d11va

### Motivation

Media Foundation a des limitations:
- API complexe et opaque
- Buffering interne difficile à contrôler
- `Lock2D` force une synchronisation GPU même en hardware decode

### Plan

Remplacer le décodeur MF par **FFmpeg avec accélération d3d11va**:

```cpp
// Avantages potentiels:
// 1. Contrôle direct sur le buffering (AVCodecContext options)
// 2. API hwaccel bien documentée
// 3. Possibilité de zero-copy avec av_hwframe_transfer_data()
// 4. Support natif du mapping GPU→CPU async
```

### Implémentation Proposée

1. **Créer `ffmpeg-decoder.cpp`**
   ```cpp
   AVCodecContext *codec_ctx;
   AVBufferRef *hw_device_ctx;  // d3d11va device
   AVFrame *hw_frame;           // GPU frame
   AVFrame *sw_frame;           // CPU frame (transfer)
   ```

2. **Configuration d3d11va**
   ```cpp
   av_hwdevice_ctx_create(&hw_device_ctx, AV_HWDEVICE_TYPE_D3D11VA, ...);
   codec_ctx->hw_device_ctx = av_buffer_ref(hw_device_ctx);
   codec_ctx->get_format = get_hw_format;  // Force d3d11va
   ```

3. **Décodage low-latency**
   ```cpp
   av_opt_set(codec_ctx->priv_data, "delay", "0", 0);
   codec_ctx->flags |= AV_CODEC_FLAG_LOW_DELAY;
   codec_ctx->flags2 |= AV_CODEC_FLAG2_FAST;
   ```

4. **Transfer GPU→CPU**
   ```cpp
   av_hwframe_transfer_data(sw_frame, hw_frame, 0);
   // Potentiellement plus rapide que Lock2D
   ```

### Dépendances

- FFmpeg libraries (avcodec, avutil, avformat)
- Ou FFmpeg DLLs bundled avec le plugin

---

## Leçons Apprises

1. **Cross-device D3D11 est coûteux**
   - `OpenSharedResource` est lent (~10-20ms)
   - Même avec cache, l'architecture reste complexe

2. **OBS graphics context est un goulot**
   - `obs_enter_graphics()` depuis un thread non-render cause des blocages
   - Le mode hybride `ASYNC_VIDEO | VIDEO` n'est pas stable

3. **Le buffering est distribué**
   - Réduire un buffer ne suffit pas si d'autres compensent
   - La latence totale = somme de tous les buffers de la pipeline

4. **Lock2D n'est pas le seul problème**
   - Même en éliminant Lock2D, la latence reste élevée
   - Le décodeur MF lui-même buffer 1-2 frames

---

## Références

- [D3D11 Video Decoding](https://docs.microsoft.com/en-us/windows/win32/medfound/direct3d-11-video-decoding)
- [DXGI Shared Textures](https://docs.microsoft.com/en-us/windows/win32/direct3d11/d3d11-graphics-programming-guide-resources-shared)
- [FFmpeg Hardware Acceleration](https://trac.ffmpeg.org/wiki/HWAccelIntro)
- [OBS Source API](https://obsproject.com/docs/reference-sources.html)
