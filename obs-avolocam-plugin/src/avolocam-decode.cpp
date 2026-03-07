/**
 * avolocam-decode.cpp - Decode thread and frame output
 *
 * Extracted from avolocam-source.cpp: decode loop, GPU/CPU frame handling.
 */

#include "avolocam-source-data.h"
#include "pipeline-config.h"

namespace avolocam {

/**
 * Decode thread main loop (Phase 3: async pipeline)
 * Pulls access units from queue and decodes them
 */
void SourceData::decode_loop() {
    ALOG(LOG_INFO, "Decode thread started");

    while (running.load()) {
        AccessUnit au;
        bool has_au = false;

        // Wait for work
        {
            std::unique_lock<std::mutex> lock(decode_queue.mutex);
            if (decode_queue.queue.empty()) {
                // Flash mode: 1ms wait with predicate for fastest wakeup
                // Stable mode: 50ms wait (less CPU usage)
                auto wait_ms = config.flash_mode ? DECODE_CV_WAIT_FLASH_MS : DECODE_CV_WAIT_STABLE_MS;
                decode_queue.cv.wait_for(lock,
                    std::chrono::milliseconds(wait_ms),
                    [this]() { return !decode_queue.queue.empty() || !running.load(); });
            }

            if (!decode_queue.queue.empty()) {
                au = std::move(decode_queue.queue.front());
                decode_queue.queue.pop_front();
                has_au = true;
            }
        }

        if (!has_au) continue;
        if (!running.load()) break;

        // Decode the access unit
        decode_frame_async(au);
    }

    ALOG(LOG_INFO, "Decode thread stopped");
}

/**
 * Initialize decoder on first access unit with SPS/PPS.
 * Returns true if decoder is ready, false if still uninitialized.
 */
bool SourceData::init_decoder(const AccessUnit& au) {
    if (pipeline.decoder->is_initialized())
        return true;

    if (au.has_sps && au.has_pps) {
        std::vector<uint8_t> sps, pps;
        extract_parameter_sets(au.data, sps, pps);
        if (!sps.empty() && !pps.empty()) {
            if (pipeline.decoder->initialize(sps.data(), sps.size(), pps.data(), pps.size())) {
                // Enable GPU output if decoder supports it AND
                // exposes its D3D device (needed for GPUConverter NV12→RGBA).
                // MF decoder exposes a D3D device but currently uses the CPU
                // conversion path due to GPUConverter interop constraints.
                // FFmpeg D3D11VA exposes a compatible device → full GPU zero-copy path.
                if (config.prefer_zero_copy.load() && pipeline.decoder->supports_gpu_output()
                    && pipeline.decoder->get_d3d_device()) {
                    pipeline.decoder->set_gpu_output(true);
                    gpu.use_gpu_decode.store(true);
                    ALOG(LOG_INFO, "GPU decode enabled (CUSTOM_DRAW path)");
                } else {
                    gpu.use_gpu_decode.store(false);
                }

                // Set decode queue size based on mode and decoder type:
                // Flash mode: always 1 (minimum latency)
                // Hardware decoders are fast → small queue (4)
                // Software fallback is slower → larger queue (6) to absorb stalls
                if (config.flash_mode.load()) {
                    decode_queue.max_size = DECODE_QUEUE_FLASH;
                    ALOG(LOG_INFO, "Decoder initialized (%s), "
                         "flash mode: decode queue size = %zu",
                         pipeline.decoder->is_hardware() ? "hardware" : "software",
                         DECODE_QUEUE_FLASH);
                } else if (pipeline.decoder->is_hardware()) {
                    decode_queue.max_size = DECODE_QUEUE_HW;
                    ALOG(LOG_INFO, "Decoder initialized (hardware), "
                         "decode queue size = %zu", DECODE_QUEUE_HW);
                } else {
                    decode_queue.max_size = DECODE_QUEUE_SW;
                    ALOG(LOG_INFO, "Decoder initialized (software fallback), "
                         "decode queue size = %zu", DECODE_QUEUE_SW);
                }
            }
        }
    }

    if (!pipeline.decoder->is_initialized()) {
        frames_dropped.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
    return true;
}

/**
 * Attempt GPU zero-copy decode path (NV12 → RGBA shared texture).
 * Returns true if GPU consumed the frame, false to fall through to CPU.
 */
#ifdef _WIN32
bool SourceData::decode_gpu_frame(DecodedFrame& frame) {
    if (!(frame.has_gpu_texture && frame.gpu_texture && gpu.use_gpu_decode.load()))
        return false;

    // Initialize GPUConverter once with decoder's D3D11 device
    if (!gpu.converter_initialized && pipeline.decoder) {
        void *dev = pipeline.decoder->get_d3d_device();
        void *ctx = pipeline.decoder->get_d3d_context();
        if (dev && ctx) {
            gpu.converter = std::make_unique<GPUConverter>();
            if (gpu.converter->initialize(
                    static_cast<ID3D11Device*>(dev),
                    static_cast<ID3D11DeviceContext*>(ctx))) {
                gpu.converter_initialized = true;
                ALOG(LOG_INFO, "GPUConverter initialized for CUSTOM_DRAW path");
            } else {
                gpu.converter.reset();
                ALOG(LOG_WARNING, "GPUConverter init failed, using CPU path");
            }
        }
    }

    // Convert NV12 shared texture → RGBA shared texture via GPUConverter
    if (gpu.converter_initialized && gpu.converter) {
        GPUDecodedFrame gpu_input;
        gpu_input.texture = static_cast<ID3D11Texture2D*>(frame.gpu_texture);
        gpu_input.subresource = 0;
        gpu_input.width = frame.width;
        gpu_input.height = frame.height;
        gpu_input.pts = 0;

        ConvertedFrame converted;
        if (gpu.converter->convert(gpu_input, converted)) {
            // Flush decoder device to ensure GPU commands are submitted
            auto *ctx = static_cast<ID3D11DeviceContext*>(pipeline.decoder->get_d3d_context());
            if (ctx) ctx->Flush();

            // Store dimensions first, then handle with release so
            // the render thread's acquire load sees consistent values.
            gpu.texture_width.store(frame.width, std::memory_order_relaxed);
            gpu.texture_height.store(frame.height, std::memory_order_relaxed);
            gpu.latest_shared_handle.store(converted.shared_handle, std::memory_order_release);
            gpu.use_gpu_render.store(true);

            output_count++;
            if (output_count == 1) {
                ALOG(LOG_INFO, "First GPU frame (CUSTOM_DRAW): %ux%u, handle=%p",
                     frame.width, frame.height, converted.shared_handle);
            }

            // Release the converted frame back to pool (handle stays valid)
            gpu.converter->release_frame(converted);
            // Release IMFSample (MF decoder keeps texture alive via sample ref)
            if (frame.platform_handle) {
                ComPtr<IUnknown> prevent_leak;
                prevent_leak.Set(static_cast<IUnknown*>(frame.platform_handle));
                frame.platform_handle = nullptr;
            }
            return true;
        }
        ALOG(LOG_WARNING, "GPU conversion failed, falling back to CPU");
    }

    // Fall through to CPU path — release IMFSample since GPU didn't consume it
    if (frame.platform_handle) {
        ComPtr<IUnknown> prevent_leak;
        prevent_leak.Set(static_cast<IUnknown*>(frame.platform_handle));
        frame.platform_handle = nullptr;
    }
    return false;
}
#endif

/**
 * Store decoded frame in double buffer and output to OBS (CPU path).
 */
void SourceData::store_cpu_frame(const DecodedFrame& frame) {
    if (!frame.y_plane) {
        frames_dropped.fetch_add(1, std::memory_order_relaxed);
        return;
    }

    // Store in latest frame buffer (double buffering)
    // Use current_buffer to select which buffer to write to
    int write_idx = 1 - decode_queue.current_buffer.load();  // Write to the other buffer
    DecodeQueue::Frame* write_buf = (write_idx == 0) ? &decode_queue.buffer_a : &decode_queue.buffer_b;

    // Copy frame data to buffer (under lock to prevent reader from seeing
    // a partially-written buffer if the atomic swap races with output_latest_frame)
    {
        std::lock_guard<std::mutex> lock(frame_mutex);

        size_t y_size = (size_t)frame.y_stride * frame.height;
        size_t uv_size = (size_t)frame.uv_stride * (frame.height / 2);
        size_t total_size = y_size + uv_size;

        if (write_buf->data.size() < total_size) {
            write_buf->data.resize(total_size);
        }

        memcpy(write_buf->data.data(), frame.y_plane, y_size);
        memcpy(write_buf->data.data() + y_size, frame.uv_plane, uv_size);

        write_buf->width = frame.width;
        write_buf->height = frame.height;
        write_buf->y_stride = frame.y_stride;
        write_buf->uv_stride = frame.uv_stride;
        write_buf->pts = frame.pts;
        write_buf->valid = true;

        // Atomic swap to make new frame visible
        decode_queue.current_buffer.store(write_idx);
        decode_queue.latest.store(write_buf);
    }

    // Also output immediately (for async video source compatibility)
    output_latest_frame();
}

/**
 * Decode a frame and store in latest_frame_ (async version)
 */
void SourceData::decode_frame_async(const AccessUnit& au) {
    au_count++;

    if (!pipeline.decoder) {
        frames_dropped.fetch_add(1, std::memory_order_relaxed);
        return;
    }

    // Log decode timing stats every 300 frames
    if (config.debug_mode && au_count % 300 == 0 && pipeline.decoder->is_initialized()) {
        const auto& stats = pipeline.decoder->get_timing_stats();
        uint64_t queue_drops = decode_queue_drops.load();
        ALOG(LOG_DEBUG, "Decode timing (avg over %llu frames): "
             "input=%.2fms output=%.2fms lock=%.2fms copy=%.2fms total=%.2fms | queue_drops=%llu",
             (unsigned long long)stats.frame_count,
             stats.avg_input_ms(),
             stats.avg_output_ms(),
             stats.avg_lock_ms(),
             stats.avg_memcpy_ms(),
             stats.avg_total_ms(),
             (unsigned long long)queue_drops);
    }

    if (!init_decoder(au))
        return;

    // Decode
    DecodedFrame frame;
    if (!pipeline.decoder->decode(au.data.data(), au.data.size(), frame)) {
        if (pipeline.sync_state) pipeline.sync_state->on_decode_error();
        frames_dropped.fetch_add(1, std::memory_order_relaxed);
        return;
    }

    frames_decoded.fetch_add(1, std::memory_order_relaxed);

#ifdef _WIN32
    if (decode_gpu_frame(frame))
        return;
#endif

    store_cpu_frame(frame);
}

/**
 * Output the latest decoded frame to OBS
 */
void SourceData::output_latest_frame() {
    DecodeQueue::Frame* frame = decode_queue.latest.load();
    if (!frame || !frame->valid) return;
    if (!source) return;

    // Lock to prevent store_cpu_frame from mutating the buffer while we read it
    std::lock_guard<std::mutex> lock(frame_mutex);

    output_count++;

    struct obs_source_frame obs_frame = {};
    obs_frame.width = frame->width;
    obs_frame.height = frame->height;
    obs_frame.format = VIDEO_FORMAT_NV12;
    obs_frame.timestamp = os_gettime_ns();

    size_t y_size = (size_t)frame->y_stride * frame->height;

    obs_frame.data[0] = frame->data.data();
    obs_frame.data[1] = frame->data.data() + y_size;
    obs_frame.linesize[0] = frame->y_stride;
    obs_frame.linesize[1] = frame->uv_stride;

    video_format_get_parameters(VIDEO_CS_709, VIDEO_RANGE_FULL,
                                obs_frame.color_matrix,
                                obs_frame.color_range_min,
                                obs_frame.color_range_max);
    obs_frame.full_range = true;

    obs_source_output_video(source, &obs_frame);

    if (output_count == 1) {
        ALOG(LOG_INFO, "First frame output: %ux%u", frame->width, frame->height);
    } else if (config.debug_mode && output_count % 300 == 0) {
        ALOG(LOG_DEBUG, "Output frame #%d: %ux%u",
             output_count, frame->width, frame->height);
    }
}

// Get current latency for overlay display
double SourceData::get_display_latency() const {
    return current_latency_ms.load(std::memory_order_relaxed);
}

} // namespace avolocam
