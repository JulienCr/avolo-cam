# Bug Hunt Report — obs-avolocam-plugin

**Date:** 2026-03-07
**Method:** Systematic bug hunting with adversarial validation (logic-hunter + cpp-hunter)
**Scope:** Full codebase scan (`obs-avolocam-plugin/src/`)

---

## Summary

| Metric | Count |
|--------|-------|
| Initial findings (pre-challenge) | 21 |
| After deduplication | 19 |
| **CONFIRMED (real bugs)** | **4** |
| FALSE_POSITIVE (rejected) | 15 |

---

## Confirmed Bugs

### BUG-1: Sync resync logic is dead code — no recovery after packet loss

| Field | Value |
|-------|-------|
| **Location** | `sync-state-machine.cpp:51-66` |
| **Confidence** | CERTAIN |
| **Severity** | High |
| **Category** | Dead Code / Contract Violation |
| **Found by** | Logic Hunter |
| **Challenger verdict** | CONFIRMED |

**Description:**
`SyncStateMachine::on_decode_error()` and `SyncStateMachine::on_packet_loss()` are defined in the source but **never called** from `avolocam-source.cpp` or any other file. The state machine can never transition from `SYNC` to `OUT_OF_SYNC` after stream corruption.

**Consequence:**
After packet loss or decode errors, corrupted non-IDR frames continue to be assembled and fed to the decoder instead of being dropped. No IDR resync is ever requested. This causes prolonged visual artifacts until the next natural keyframe (up to 1 second at GOP=30).

**Evidence:**
- `grep -rn "on_decode_error\|on_packet_loss" obs-avolocam-plugin/src/` returns only the declaration and definition — zero call sites.
- The state machine transitions `SYNC -> OUT_OF_SYNC` only exist in these uncalled methods.

**Suggested fix:**
Call `on_decode_error()` when `decoder->decode()` returns false, and `on_packet_loss()` when the jitter buffer or depacketizer detects a sequence gap.

---

### BUG-2: UDP flash mode drain loop blocks indefinitely

| Field | Value |
|-------|-------|
| **Location** | `udp-receiver.cpp:100-152`, `avolocam-source.cpp:552-560` |
| **Confidence** | HIGH |
| **Severity** | High |
| **Category** | Control Flow Bug |
| **Found by** | Logic Hunter |
| **Challenger verdict** | CONFIRMED |

**Description:**
The UDP socket is created as blocking (no `O_NONBLOCK` or `FIONBIO`). In `UDPReceiver::receive()`, when `timeout_ms > 0`, `select()`/`poll()` provides the timeout before calling `recvfrom()`. When `timeout_ms == 0`, the select/poll is **skipped entirely** (line 106: `if (timeout_ms > 0)`), and `recvfrom()` is called directly on the blocking socket.

The flash mode drain loop in `avolocam-source.cpp:552-560` passes `timeout_ms=0` expecting non-blocking behavior:
```cpp
// Drain all remaining packets in the socket (non-blocking)
while (true) {
    int extra = receiver->receive(drain_buf, sizeof(drain_buf), 0);
    if (extra <= 0) break;
    process_packet_direct(...);
}
```

Once the socket buffer is drained, `recvfrom()` blocks indefinitely, **hanging the UDP receive thread**.

**Evidence:**
- Socket creation in `udp-receiver.cpp:bind()` only sets `SO_RCVBUF`, no non-blocking flag.
- `receive()` line 106: `if (timeout_ms > 0)` gates the select/poll.
- Flash mode drain at `avolocam-source.cpp:552-560` passes `0` as timeout.

**Suggested fix:**
Either set the socket to non-blocking mode (`FIONBIO`), or use `select()` with a zero timeout (`tv = {0, 0}`) when `timeout_ms == 0` to poll without blocking.

---

### BUG-3: IMFSample leak in Media Foundation GPU decode path

| Field | Value |
|-------|-------|
| **Location** | `mf-decoder.cpp:1192-1204` |
| **Confidence** | HIGH |
| **Severity** | Critical |
| **Category** | COM Reference Leak |
| **Found by** | C++ Hunter |
| **Challenger verdict** | CONFIRMED |

**Description:**
In `MFDecoder::process_output_gpu()`, when GPU texture extraction succeeds, `result_sample` (an `IMFSample*`) is stored in `DecodedFrame::platform_handle` as a raw `void*`:
```cpp
out.platform_handle = result_sample;
```

The `DecodedFrame` struct has no destructor and `platform_handle` is never `Release()`'d downstream. Each decoded GPU frame leaks one `IMFSample` COM object.

**Consequence:**
At 30fps, **1,800 IMFSample objects leak per minute**. This exhausts GPU memory and causes OBS to freeze or crash within minutes when using the MF GPU decode path.

**Evidence:**
- `DecodedFrame` in `platform-decoder.h` has `void* platform_handle` with no release semantics.
- `texture-output-windows.cpp` reads `platform_handle` into `input.sample_ref` but never calls `Release()`.
- No `Release()` on `platform_handle` found anywhere via grep.

**Suggested fix:**
Add explicit `IMFSample::Release()` after the frame is consumed in the output path, or use a RAII wrapper / custom deleter for `platform_handle`.

---

### BUG-4: GPUConverter texture pool reuse race with OBS render thread

| Field | Value |
|-------|-------|
| **Location** | `gpu-converter.cpp`, `avolocam-source.cpp:866-868` |
| **Confidence** | MEDIUM |
| **Severity** | Medium |
| **Category** | D3D11 Resource Race |
| **Found by** | C++ Hunter |
| **Challenger verdict** | CONFIRMED |

**Description:**
In `decode_frame_async()`, after storing the shared handle atomically, the converter pool slot is immediately released:
```cpp
gpu_converter_->release_frame(converted);
```

The render thread later calls `gs_texture_open_shared()` in `video_tick` to open the shared handle on OBS's device. Between `release_frame` and the next `video_tick`, a new `convert()` call could reuse that pool slot, destroying and recreating the texture — **invalidating the shared handle before OBS has opened it**.

**Consequence:**
Sporadic visual corruption or crash if OBS attempts to open an invalidated shared handle. The window is narrow at 30fps but widens under GPU load or higher framerates.

**Evidence:**
- `release_frame()` in `gpu-converter.cpp:583-595` sets `in_use = false` on the pool slot.
- `convert()` can then reuse the slot, calling `ID3D11Texture2D::Release()` on the old texture and creating a new one.
- `video_tick` runs on the OBS video thread asynchronously from the decode thread.

**Suggested fix:**
Defer `release_frame()` until after OBS has opened the shared handle (e.g., in `video_tick` after `gs_texture_open_shared` succeeds), or use a ring of shared handles large enough that reuse cannot occur within one frame interval.

---

## Rejected Findings (FALSE_POSITIVE)

These were investigated but rejected during adversarial challenge:

| Finding | Reason for rejection |
|---------|---------------------|
| Tally inversion race on WS reconnect | `send_tally_state()` always sends the correct OBS state; at worst one stale heartbeat self-corrected in 2s |
| `cleanup_old_entries()` never called | `MAX_ENTRIES` (256) already bounds growth via automatic trim in `register_frame_info()` |
| AU assembler `std::map` wraparound | Signed `int32_t` diff handles wrap correctly; max 16 pending entries, negligible practical impact |
| SyncStateMachine starts in SYNC | FFmpeg silently drops frames without IDR reference; no corruption, just log noise |
| `deactivate` doesn't stop pipeline | Intentional design for fast scene switching; `destroy` handles full cleanup |
| JSON parser doesn't handle escaped quotes | Telemetry values are fixed enum strings, never contain quotes |
| JSON int64/uint32 via double precision | No realistic protocol value exceeds 2^53 |
| `static debug_count` data race | Benign — at worst a few extra log lines; no incorrect behavior |
| `packet_->data` aliasing input buffer | `thread_count=1` + `LOW_DELAY` = synchronous consumption; buffer valid throughout |
| Double-buffer torn reads | Scheme is correct: `seq_cst` fence on atomic store guarantees visibility of non-atomic writes |
| `obs_source_output_video` from decode thread | API is documented as thread-safe; standard OBS async source pattern |
| WebSocket send after close | `send_mutex_` serializes sends; worst case is a harmless failed send |
| MF decoder Y copy padding uninitialized | OBS uses `width` (not stride) for visible pixels; padding is never displayed |
| `timestamp_diff` at exactly half-range | Astronomically improbable; cast is well-defined on MSVC x64 |
| `obs_enter_graphics` in destructor | OBS never calls `destroy` from graphics context; standard plugin pattern |

---

## Broader Code Quality Observations

While not individual bugs, the following systemic issues were noted during the scan:

- **Monolithic source file:** `avolocam-source.cpp` is ~1200+ lines with pipeline management, OBS callbacks, decode logic, tally, WebSocket handling, and test patterns all interleaved in a single struct.
- **No tests:** Zero unit tests or integration tests for any pipeline stage. The jitter buffer, depacketizer, assembler, sync state machine, and timestamp mapper are all untested.
- **Minimal error handling:** Decode failures, network errors, and D3D11 HRESULT failures are mostly logged and silently continued. No structured error propagation.
- **Raw resource management:** Mix of raw pointers (`void* platform_handle`), manual `Release()` calls, and no RAII wrappers for COM objects, FFmpeg resources, or sockets.
- **Dead code:** `SyncStateMachine::on_decode_error()`, `on_packet_loss()`, and `TimestampMapper::cleanup_old_entries()` are implemented but never called.
- **Implicit threading contracts:** Which thread calls which function is not documented or enforced. Thread safety relies on convention rather than type system or annotations.
