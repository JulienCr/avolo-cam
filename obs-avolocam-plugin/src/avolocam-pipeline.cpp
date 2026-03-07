/**
 * avolocam-pipeline.cpp - Pipeline lifecycle management
 *
 * Extracted from avolocam-source.cpp: init, start, stop, cleanup methods.
 */

#include "avolocam-source-data.h"
#include "pipeline-config.h"

namespace avolocam {

Result<void> SourceData::init_pipeline(const std::string& ip, bool zero_copy) {
    pipeline.receiver = std::make_unique<UdpReceiver>();
    pipeline.receiver->set_expected_source(ip);  // Filter packets to only accept from this camera
    pipeline.depacketizer = std::make_unique<RtpDepacketizer>();
    pipeline.depacketizer->set_packet_loss_callback([this](int missing) {
        if (pipeline.sync_state) pipeline.sync_state->on_packet_loss(missing);
    });
    pipeline.assembler = std::make_unique<AccessUnitAssembler>();
    pipeline.sync_state = std::make_unique<SyncStateMachine>();
    pipeline.timestamp_mapper = std::make_unique<TimestampMapper>();

    // Initialize texture output
    pipeline.texture_output = std::make_unique<TextureOutput>();
    pipeline.texture_output->initialize(source, zero_copy);

    // Create FFmpeg D3D11VA decoder
    DecoderConfig decoder_config;
    decoder_config.prefer_hardware = zero_copy;
    decoder_config.low_latency = true;
    decoder_config.output_nv12 = true;

    pipeline.decoder = PlatformDecoder::create(decoder_config);
    if (!pipeline.decoder) {
        ALOG(LOG_ERROR, "Failed to create decoder");
        return {SourceError::DECODER_CREATE_FAILED};
    }

    // Note: GPU output will be enabled after decoder initialization in decode_frame_async
    // because supports_gpu_output() requires the D3D device to be created first
    gpu.use_gpu_decode.store(zero_copy);  // Store preference, will verify after init
    return {};
}

/**
 * Set up WebSocket client with callbacks and launch background connect thread.
 */
void SourceData::init_websocket(const std::string& ip, std::string token) {
    pipeline.ws_client = std::make_unique<WebSocketClient>();

    // Set up WebSocket callbacks
    pipeline.ws_client->set_frame_info_callback([this](const FrameTimingInfo &info) {
        if (pipeline.timestamp_mapper) {
            pipeline.timestamp_mapper->register_frame_info(info);
        }
    });

    pipeline.ws_client->set_telemetry_callback([this](const CameraTelemetry &telemetry) {
        {
            std::lock_guard<std::mutex> lock(telemetry_mutex);
            camera_telemetry = telemetry;
        }
    });

    // Re-send tally + subscribe to frame_info on every (re)connect
    pipeline.ws_client->set_connection_callback([this](WSState state) {
        if (state == WSState::CONNECTED) {
            // Subscribe to frame_info channel (only OBS needs it)
            pipeline.ws_client->send_command(R"({"op":"subscribe","channels":["frame_info"]})");

            // Invalidate cached tally state so tick_tally() will resend
            // on the next poll cycle (~100ms). We must NOT call
            // send_tally_state() here — it would send on the WebSocket
            // from within a connection callback context.
            tally_program.store(!tally_program.load());
            tally_preview.store(!tally_preview.load());
            ALOG(LOG_INFO, "WS connected: subscribed to frame_info, tally invalidated for resend");
        }
    });

    // Set up IDR request callback for sync state machine
    pipeline.sync_state->set_idr_request_callback([this]() {
        if (pipeline.ws_client && pipeline.ws_client->is_connected()) {
            pipeline.ws_client->request_idr();
        }
    });

    // Connect WebSocket in background — ws_client->connect() can block for
    // up to 21 seconds on TCP timeout when the camera is unreachable, and
    // start() runs on the OBS video thread (via activate callback).
    // Blocking here freezes ALL video_tick/video_render for every source.
    // Thread is stored (not detached) so stop() can join it safely.
    {
        std::string ws_url_str = "ws://" + ip + ":"
                                 + std::to_string(DEFAULT_WS_PORT) + "/ws";
        auto ws = pipeline.ws_client.get();
        ws_connect_thread_ = std::thread([ws, url = std::move(ws_url_str),
                     token = std::move(token)]() {
            ws->connect(url, token);
        });
    }
}

/**
 * Reset decode queue, spawn threads, wait for bind result.
 * Cleans up everything on bind failure.
 */
void SourceData::start_threads(uint16_t port) {
    // Reset async pipeline state
    {
        std::lock_guard<std::mutex> lock(decode_queue.mutex);
        decode_queue.queue.clear();
    }
    decode_queue.latest.store(nullptr);
    decode_queue.buffer_a.valid = false;
    decode_queue.buffer_b.valid = false;
    decode_queue.current_buffer.store(0);
    decode_queue_drops.store(0);

    running.store(true);
    bind_result_.store(0);  // Reset bind signal

    // Start decode thread (Phase 3: async pipeline)
    decode_thread = std::thread(&SourceData::decode_loop, this);

    receive_thread = std::thread(&SourceData::receive_loop, this);

    // Wait for bind result (up to 2 seconds)
    for (int i = 0; i < 200 && bind_result_.load() == 0 && running.load(); i++) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }

    if (bind_result_.load() != 1) {
        ALOG(LOG_ERROR, "Bind to port %d failed — stopping source", port);
        running.store(false);

        shutdown_websocket();

        {
            std::lock_guard<std::mutex> lock(decode_queue.mutex);
            decode_queue.cv.notify_all();
        }

        if (decode_thread.joinable()) decode_thread.join();
        if (receive_thread.joinable()) receive_thread.join();

        reset_pipeline();
    }
}

Result<void> SourceData::start() {
    if (running.load()) return {};

    // Snapshot config under lock
    std::string ip_copy, token_copy;
    {
        std::lock_guard<std::mutex> lock(config.mutex);
        ip_copy = config.camera_ip;
        token_copy = config.auth_token;
    }
    uint16_t port_copy = config.camera_port.load();
    bool zero_copy = config.prefer_zero_copy.load();

    if (ip_copy.empty()) {
        ALOG(LOG_WARNING, "No camera IP configured");
        return {SourceError::NO_CAMERA_IP};
    }

    // Reserve port atomically (insert returns false if already present)
    {
        std::lock_guard<std::mutex> lock(g_ports_mutex);
        if (!g_bound_ports.insert(port_copy).second) {
            ALOG(LOG_ERROR, "Port %d is already in use by another AvoCam source. "
                 "Each source must use a unique UDP port.", port_copy);
            return {SourceError::PORT_IN_USE};
        }
    }

    ALOG(LOG_INFO, "Starting receiver for %s:%d",
         ip_copy.c_str(), port_copy);

    auto result = init_pipeline(ip_copy, zero_copy);
    if (!result) {
        std::lock_guard<std::mutex> lock(g_ports_mutex);
        g_bound_ports.erase(port_copy);
        return result;
    }

    init_websocket(ip_copy, std::move(token_copy));
    start_threads(port_copy);
    return {};
}

/**
 * Two-phase WebSocket shutdown.
 * Phase 1: close socket to unblock ::connect() in ws_connect_thread_.
 * Phase 2 (after join): disconnect again because connect() may have
 * succeeded between phase 1 and join, re-creating socket + recv_thread_.
 */
void SourceData::shutdown_websocket() {
    if (pipeline.ws_client) {
        pipeline.ws_client->disconnect();
    }
    if (ws_connect_thread_.joinable()) {
        ws_connect_thread_.join();
    }
    if (pipeline.ws_client) {
        pipeline.ws_client->disconnect();
    }
}

/**
 * Release GPU rendering resources (converter, shared textures).
 */
void SourceData::cleanup_gpu_state() {
#ifdef _WIN32
    gpu.converter.reset();
#endif
    gpu.converter_initialized = false;
    gpu.use_gpu_render.store(false);
    gpu.latest_shared_handle.store(nullptr);
    gpu.cached_shared_handle = nullptr;
    if (gpu.obs_shared_texture) {
        obs_enter_graphics();
        gs_texture_destroy(gpu.obs_shared_texture);
        obs_leave_graphics();
        gpu.obs_shared_texture = nullptr;
    }
    if (gpu.cpu_fallback_texture) {
        obs_enter_graphics();
        gs_texture_destroy(gpu.cpu_fallback_texture);
        obs_leave_graphics();
        gpu.cpu_fallback_texture = nullptr;
    }
}

/**
 * Destroy all pipeline components.
 */
void SourceData::reset_pipeline() {
    pipeline.receiver.reset();
    pipeline.depacketizer.reset();
    pipeline.assembler.reset();
    pipeline.sync_state.reset();
    pipeline.decoder.reset();
    pipeline.timestamp_mapper.reset();
    pipeline.texture_output.reset();
    pipeline.ws_client.reset();
}

void SourceData::stop() {
    if (!running.load()) return;

    ALOG(LOG_INFO, "Stopping receiver");
    running.store(false);

    shutdown_websocket();

    // Note: port unregistration happens in receive_loop() exit, AFTER the
    // socket is actually closed, to avoid a TOCTOU window where another
    // source sees the port as free while the socket is still bound.

    // Wake up decode thread if waiting
    {
        std::lock_guard<std::mutex> lock(decode_queue.mutex);
        decode_queue.cv.notify_all();
    }

    if (decode_thread.joinable()) {
        decode_thread.join();
    }

    if (receive_thread.joinable()) {
        receive_thread.join();
    }

    cleanup_gpu_state();
    reset_pipeline();

    // Clear decode queue
    {
        std::lock_guard<std::mutex> lock(decode_queue.mutex);
        decode_queue.queue.clear();
    }

    // Reset frame state so test pattern shows on next start
    decode_queue.latest.store(nullptr);
    decode_queue.buffer_a.valid = false;
    decode_queue.buffer_b.valid = false;

    // Clear OBS async video cache (otherwise last frame stays displayed)
    if (source) {
        obs_source_output_video(source, nullptr);
    }
}

} // namespace avolocam
