/**
 * avolocam-source.cpp - Main OBS source implementation
 *
 * Implements the OBS source interface for receiving and displaying
 * video from AvoCam iOS devices via UDP/RTP.
 */

#include "avolocam-source.h"
#include "udp-receiver.h"
#include "jitter-buffer.h"
#include "rtp-depacketizer.h"
#include "access-unit-assembler.h"
#include "sync-state-machine.h"
#include "decoder/platform-decoder.h"
#include "mdns-discovery.h"
#include "timestamp-mapper.h"
#include "texture-output.h"
#include "gpu-converter.h"
#include "websocket-client.h"

#include <obs-module.h>
#include <graphics/graphics.h>
#include <util/platform.h>
#include <util/threading.h>
#include <memory>
#include <atomic>
#include <thread>
#include <mutex>
#include <deque>
#include <set>
#include <condition_variable>
#include <string>
#include <cstdio>

#ifdef _WIN32
#include <mfapi.h>
#endif

// Property keys
#define PROP_CAMERA_SELECT    "camera_select"
#define PROP_MANUAL_IP        "manual_ip"
#define PROP_MANUAL_PORT      "manual_port"
#define PROP_JITTER_MODE      "jitter_mode"
#define PROP_SHOW_LATENCY     "show_latency"
#define PROP_AUTH_TOKEN       "auth_token"
#define PROP_PREFER_ZERO_COPY "prefer_zero_copy"
#define PROP_DEBUG_MODE       "debug_mode"
#define PROP_DECODER_TYPE     "decoder_type"
#define PROP_PORT_WARNING     "port_warning"

// Jitter buffer modes
#define JITTER_ULTRA_LOW  0  // 0-8ms buffer
#define JITTER_STABLE     1  // 16-50ms buffer

// Decoder types (match DecoderType enum in platform-decoder.h)
#define DECODER_TYPE_AUTO             0
#define DECODER_TYPE_MEDIA_FOUNDATION 1
#define DECODER_TYPE_FFMPEG_D3D11VA   2
#define DECODER_TYPE_FFMPEG_SOFTWARE  3

// WebSocket port (same as HTTP API)
#define DEFAULT_WS_PORT 8888

namespace avolocam {

// Global mDNS discovery instance (shared across all sources)
static std::unique_ptr<MdnsDiscovery> g_discovery;
static std::mutex g_discovery_mutex;

// Global port registry: prevents multiple sources from binding the same UDP port
static std::set<uint16_t> g_bound_ports;
static std::mutex g_ports_mutex;

// Auto-incrementing default port for new sources
static std::atomic<uint16_t> g_next_default_port{5000};

// Port range for auto-assignment (avoids privileged and ephemeral ports)
static constexpr uint16_t PORT_RANGE_START = 5000;
static constexpr uint16_t PORT_RANGE_END   = 9999;

// Get next available auto-assigned port in valid range, avoiding collisions
static uint16_t allocate_next_port() {
    std::lock_guard<std::mutex> lock(g_ports_mutex);
    for (int attempts = 0; attempts < (PORT_RANGE_END - PORT_RANGE_START + 1); attempts++) {
        uint16_t port = g_next_default_port.fetch_add(1);
        // Wrap to valid range
        if (port > PORT_RANGE_END || port < PORT_RANGE_START) {
            g_next_default_port.store(PORT_RANGE_START + 1);
            port = PORT_RANGE_START;
        }
        if (g_bound_ports.count(port) == 0) {
            return port;
        }
    }
    blog(LOG_ERROR, "[avolocam] No available ports in range %d-%d", PORT_RANGE_START, PORT_RANGE_END);
    return PORT_RANGE_START;  // Fallback — will fail at bind time with clear error
}

/**
 * Source instance data
 */
struct SourceData {
    obs_source_t *source = nullptr;

    // Configuration
    std::string camera_ip;
    uint16_t camera_port = 5000;
    int jitter_mode = JITTER_STABLE;
    bool show_latency = false;
    std::string auth_token;
    bool prefer_zero_copy = true;
    bool debug_mode = false;
    int decoder_type = DECODER_TYPE_AUTO;

    // Pipeline components
    std::unique_ptr<UdpReceiver> receiver;
    std::unique_ptr<JitterBuffer> jitter_buffer;
    std::unique_ptr<RtpDepacketizer> depacketizer;
    std::unique_ptr<AccessUnitAssembler> assembler;
    std::unique_ptr<SyncStateMachine> sync_state;
    std::unique_ptr<PlatformDecoder> decoder;
    std::unique_ptr<MdnsDiscovery> discovery;
    std::unique_ptr<TimestampMapper> timestamp_mapper;
    std::unique_ptr<TextureOutput> texture_output;
    std::unique_ptr<WebSocketClient> ws_client;

    // Threading
    std::thread receive_thread;
    std::thread decode_thread;  // Separate decode thread for async pipeline
    std::atomic<bool> running{false};
    std::atomic<bool> visible{true};  // Visibility state for show/hide callbacks

    // Telemetry
    std::atomic<uint64_t> frames_received{0};
    std::atomic<uint64_t> frames_decoded{0};
    std::atomic<uint64_t> frames_dropped{0};
    std::atomic<uint64_t> decode_queue_drops{0};  // Drops due to queue overflow
    std::atomic<double> current_latency_ms{0.0};

    // Per-instance debug counters (avoid static to support multi-camera)
    int packet_count{0};
    int total_nals{0};
    int au_count{0};
    int output_count{0};

    // Tally state tracking
    std::atomic<bool> tally_program{false};
    std::atomic<bool> tally_preview{false};

    // Camera telemetry from WebSocket
    CameraTelemetry camera_telemetry;
    std::mutex telemetry_mutex;

    // Auto-port switching: track the last received flash port from WebSocket
    std::atomic<uint16_t> ws_reported_flash_port{0};

    // Bind result signaling: 0=pending, 1=success, -1=failure
    std::atomic<int> bind_result_{0};

    // Mutex for decoder output
    std::mutex frame_mutex;

    // ========== Async Decode Pipeline (Phase 3) ==========
    // Bounded queue for access units waiting to be decoded
    // Dynamic: 4 for hardware decode, 6 for software (more buffering needed)
    size_t max_decode_queue_size_ = 4;
    std::deque<AccessUnit> decode_queue_;
    std::mutex decode_queue_mutex_;
    std::condition_variable decode_queue_cv_;

    // Latest decoded frame - atomically swapped for render thread
    struct LatestFrame {
        std::vector<uint8_t> data;  // CPU buffer for frame data
        uint32_t width = 0;
        uint32_t height = 0;
        uint32_t y_stride = 0;
        uint32_t uv_stride = 0;
        uint64_t pts = 0;
        bool valid = false;
    };
    std::atomic<LatestFrame*> latest_frame_{nullptr};
    LatestFrame frame_buffer_a_;
    LatestFrame frame_buffer_b_;
    std::atomic<int> current_frame_buffer_{0};  // 0 = A, 1 = B

    // GPU output enabled flag
    bool use_gpu_decode_ = false;

    // Flash mode: ultra-low latency path (derived from jitter_mode == ULTRA_LOW)
    bool flash_mode_ = false;

    // GPUConverter for NV12→RGBA on decoder device (Phase 2 zero-copy)
#ifdef _WIN32
    std::unique_ptr<GPUConverter> gpu_converter_;
#endif
    bool gpu_converter_initialized_ = false;

    // GPU texture for sync video output (video_render callback)
    gs_texture_t *current_gpu_texture_ = nullptr;
    std::atomic<uint32_t> gpu_texture_width_{0};
    std::atomic<uint32_t> gpu_texture_height_{0};
    std::mutex gpu_texture_mutex_;
    bool has_new_gpu_frame_ = false;

    // GPU zero-copy rendering state (CUSTOM_DRAW path)
    std::atomic<void*> latest_shared_handle_{nullptr};
    void *cached_shared_handle_ = nullptr;
    gs_texture_t *obs_shared_texture_ = nullptr;
    bool use_gpu_render_ = false;

    // CPU fallback texture for CUSTOM_DRAW mode
    gs_texture_t *cpu_fallback_texture_ = nullptr;
    uint32_t cpu_fallback_width_ = 0;
    uint32_t cpu_fallback_height_ = 0;

    SourceData() = default;
    ~SourceData() {
        stop();
    }

    void start() {
        if (running.load()) return;
        if (camera_ip.empty()) {
            blog(LOG_WARNING, "[avolocam] No camera IP configured");
            return;
        }

        // Check port availability before starting
        {
            std::lock_guard<std::mutex> lock(g_ports_mutex);
            if (g_bound_ports.count(camera_port)) {
                blog(LOG_ERROR, "[avolocam] Port %d is already in use by another AvoCam source. "
                     "Each source must use a unique UDP port.", camera_port);
                return;
            }
        }

        blog(LOG_INFO, "[avolocam] Starting receiver for %s:%d",
             camera_ip.c_str(), camera_port);

        // Derive flash mode from jitter setting
        flash_mode_ = (jitter_mode == JITTER_ULTRA_LOW);

        // Initialize components
        receiver = std::make_unique<UdpReceiver>();
        receiver->set_expected_source(camera_ip);  // Filter packets to only accept from this camera
        jitter_buffer = std::make_unique<JitterBuffer>(
            jitter_mode == JITTER_ULTRA_LOW ? 8 : 50  // max_delay_ms
        );
        depacketizer = std::make_unique<RtpDepacketizer>();
        assembler = std::make_unique<AccessUnitAssembler>();
        sync_state = std::make_unique<SyncStateMachine>();
        timestamp_mapper = std::make_unique<TimestampMapper>();

        // Initialize texture output
        texture_output = std::make_unique<TextureOutput>();
        texture_output->initialize(source, prefer_zero_copy);

        // Create platform-specific decoder with configured type
        DecoderConfig decoder_config;
        decoder_config.prefer_hardware = prefer_zero_copy;
        decoder_config.low_latency = true;
        decoder_config.output_nv12 = true;
        decoder_config.decoder_type = static_cast<DecoderType>(decoder_type);

        decoder = PlatformDecoder::create(decoder_config);
        if (!decoder) {
            blog(LOG_ERROR, "[avolocam] Failed to create decoder");
            return;
        }

        // Note: GPU output will be enabled after decoder initialization in decode_frame_async
        // because supports_gpu_output() requires the D3D device to be created first
        use_gpu_decode_ = prefer_zero_copy;  // Store preference, will verify after init

        // Flash mode: minimal decode queue for lowest latency
        if (flash_mode_) {
            max_decode_queue_size_ = 1;
            blog(LOG_INFO, "[avolocam] Flash mode: decode queue = 1, jitter bypass ON");
        }

        // Initialize WebSocket client
        ws_client = std::make_unique<WebSocketClient>();

        // Set up WebSocket callbacks
        ws_client->set_frame_info_callback([this](const FrameTimingInfo &info) {
            if (timestamp_mapper) {
                timestamp_mapper->register_frame_info(info);
            }
        });

        ws_client->set_telemetry_callback([this](const CameraTelemetry &telemetry) {
            {
                std::lock_guard<std::mutex> lock(telemetry_mutex);
                camera_telemetry = telemetry;
            }

            // Store flash port for auto-switching
            if (telemetry.flash_udp_port > 0) {
                ws_reported_flash_port.store(telemetry.flash_udp_port);
            }
        });

        // Re-send tally + subscribe to frame_info on every (re)connect
        ws_client->set_connection_callback([this](WSState state) {
            if (state == WSState::CONNECTED) {
                // Subscribe to frame_info channel (only OBS needs it)
                ws_client->send_command(R"({"op":"subscribe","channels":["frame_info"]})");

                // Invalidate cached tally state to force re-send on reconnect
                tally_program.store(!obs_source_showing(source));
                tally_preview.store(true);  // Force mismatch
                send_tally_state();
                blog(LOG_INFO, "[avolocam] WS connected: subscribed to frame_info, tally re-sent");
            }
        });

        // Set up IDR request callback for sync state machine
        sync_state->set_idr_request_callback([this]() {
            if (ws_client && ws_client->is_connected()) {
                ws_client->request_idr();
            }
        });

        // Connect WebSocket
        char ws_url[256];
        snprintf(ws_url, sizeof(ws_url), "ws://%s:%d/ws", camera_ip.c_str(), DEFAULT_WS_PORT);
        ws_client->connect(ws_url, auth_token);

        // Reset async pipeline state
        {
            std::lock_guard<std::mutex> lock(decode_queue_mutex_);
            decode_queue_.clear();
        }
        latest_frame_.store(nullptr);
        frame_buffer_a_.valid = false;
        frame_buffer_b_.valid = false;
        current_frame_buffer_.store(0);
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
            blog(LOG_ERROR, "[avolocam] Bind to port %d failed — stopping source", camera_port);
            running.store(false);

            {
                std::lock_guard<std::mutex> lock(decode_queue_mutex_);
                decode_queue_cv_.notify_all();
            }

            if (decode_thread.joinable()) decode_thread.join();
            if (receive_thread.joinable()) receive_thread.join();

            receiver.reset();
            jitter_buffer.reset();
            depacketizer.reset();
            assembler.reset();
            sync_state.reset();
            decoder.reset();
            timestamp_mapper.reset();
            texture_output.reset();
            ws_client.reset();
        }
    }

    void stop() {
        if (!running.load()) return;

        blog(LOG_INFO, "[avolocam] Stopping receiver");
        running.store(false);

        // Disconnect WebSocket FIRST to stop its reconnect loop.
        // This must happen before joining source threads to avoid
        // the WS thread spinning uselessly during join waits.
        if (ws_client) {
            ws_client->disconnect();
        }

        // Note: port unregistration happens in receive_loop() exit, AFTER the
        // socket is actually closed, to avoid a TOCTOU window where another
        // source sees the port as free while the socket is still bound.

        // Wake up decode thread if waiting
        {
            std::lock_guard<std::mutex> lock(decode_queue_mutex_);
            decode_queue_cv_.notify_all();
        }

        if (decode_thread.joinable()) {
            decode_thread.join();
        }

        if (receive_thread.joinable()) {
            receive_thread.join();
        }

        // Release GPU rendering resources
#ifdef _WIN32
        gpu_converter_.reset();
#endif
        gpu_converter_initialized_ = false;
        use_gpu_render_ = false;
        latest_shared_handle_.store(nullptr);
        cached_shared_handle_ = nullptr;
        if (obs_shared_texture_) {
            obs_enter_graphics();
            gs_texture_destroy(obs_shared_texture_);
            obs_leave_graphics();
            obs_shared_texture_ = nullptr;
        }
        if (cpu_fallback_texture_) {
            obs_enter_graphics();
            gs_texture_destroy(cpu_fallback_texture_);
            obs_leave_graphics();
            cpu_fallback_texture_ = nullptr;
        }

        receiver.reset();
        jitter_buffer.reset();
        depacketizer.reset();
        assembler.reset();
        sync_state.reset();
        decoder.reset();
        timestamp_mapper.reset();
        texture_output.reset();
        ws_client.reset();

        // Clear decode queue
        {
            std::lock_guard<std::mutex> lock(decode_queue_mutex_);
            decode_queue_.clear();
        }
    }

    void receive_loop() {
        // Bind to UDP port
        if (!receiver->bind(camera_port)) {
            blog(LOG_ERROR, "[avolocam] Failed to bind to port %d - port may already be in use",
                 camera_port);
            bind_result_.store(-1);
            return;
        }

        // Register port in global registry
        {
            std::lock_guard<std::mutex> lock(g_ports_mutex);
            g_bound_ports.insert(camera_port);
        }

        bind_result_.store(1);  // Signal success to start()

        // Log actual receive buffer size for diagnostics
        int actual_rcvbuf = receiver->get_actual_rcvbuf();
        if (actual_rcvbuf > 0 && actual_rcvbuf < 2 * 1024 * 1024) {
            blog(LOG_WARNING, "[avolocam] UDP receive buffer is only %d bytes (requested 4MB). "
                 "This may cause packet drops with multiple cameras.", actual_rcvbuf);
        }

        blog(LOG_INFO, "[avolocam] Listening on UDP port %d (rcvbuf=%dKB)",
             camera_port, actual_rcvbuf / 1024);

        std::vector<uint8_t> packet_buffer(2048);

        // Tally polling: check every ~100ms (change detection)
        constexpr uint64_t TALLY_POLL_INTERVAL_NS = 100 * 1000 * 1000;  // 100ms in nanoseconds
        uint64_t last_tally_check = os_gettime_ns();

        // Tally heartbeat: unconditional re-send every 2s (guards against lost messages)
        constexpr uint64_t TALLY_HEARTBEAT_NS = 2000ULL * 1000 * 1000;  // 2s
        uint64_t last_tally_heartbeat = os_gettime_ns();

        // Track current bound port for auto-switching
        uint16_t current_bound_port = camera_port;

        while (running.load()) {
            // Check for auto-port switching (from WebSocket telemetry)
            uint16_t ws_port = ws_reported_flash_port.load();
            if (ws_port > 0 && ws_port != current_bound_port) {
                // Check port collision before attempting bind
                {
                    std::lock_guard<std::mutex> lock(g_ports_mutex);
                    if (g_bound_ports.count(ws_port)) {
                        blog(LOG_ERROR, "[avolocam] Cannot auto-switch to port %d — already in use "
                             "by another source. Staying on port %d.", ws_port, current_bound_port);
                        ws_reported_flash_port.store(current_bound_port);  // Suppress repeated attempts
                        goto skip_port_switch;
                    }
                }

                blog(LOG_INFO, "[avolocam] Auto-switching UDP port from %d to %d (from WebSocket)",
                     current_bound_port, ws_port);

                // Re-bind to new port
                if (receiver->bind(ws_port)) {
                    // Update port registry: remove old, add new
                    {
                        std::lock_guard<std::mutex> lock(g_ports_mutex);
                        g_bound_ports.erase(current_bound_port);
                        g_bound_ports.insert(ws_port);
                    }

                    // Flush the entire pipeline to avoid stale data from old stream
                    if (jitter_buffer) jitter_buffer->clear();
                    if (assembler) assembler->reset();
                    if (decoder) decoder->reset();

                    // Clear the decode queue
                    {
                        std::lock_guard<std::mutex> lock(decode_queue_mutex_);
                        decode_queue_.clear();
                    }

                    // Force resync: transition to OUT_OF_SYNC and request IDR
                    if (sync_state) sync_state->on_packet_loss(100);

                    current_bound_port = ws_port;
                    camera_port = ws_port;  // Update config for future reference
                    blog(LOG_INFO, "[avolocam] Successfully rebound to port %d (pipeline flushed, IDR requested)",
                         ws_port);
                } else {
                    blog(LOG_WARNING, "[avolocam] Failed to rebind to port %d, staying on %d",
                         ws_port, current_bound_port);
                }
            }
            skip_port_switch:

            // Receive UDP packet with timeout
            // Flash mode: 5ms timeout for fast wakeup; Stable: 100ms
            int recv_timeout = flash_mode_ ? 5 : 100;
            int received = receiver->receive(packet_buffer.data(),
                                             packet_buffer.size(),
                                             recv_timeout);

            // Check tally state periodically (change detection)
            uint64_t now = os_gettime_ns();
            if (now - last_tally_check >= TALLY_POLL_INTERVAL_NS) {
                send_tally_state();
                last_tally_check = now;
            }

            // Unconditional tally heartbeat every 2s (guards against lost messages)
            if (now - last_tally_heartbeat >= TALLY_HEARTBEAT_NS) {
                if (ws_client && ws_client->is_connected() && source) {
                    char json[128];
                    snprintf(json, sizeof(json),
                             R"({"op":"tally","program":%s,"preview":%s})",
                             tally_program.load() ? "true" : "false",
                             tally_preview.load() ? "true" : "false");
                    ws_client->send_command(json);
                }
                last_tally_heartbeat = now;
            }

            if (received <= 0) continue;

            frames_received.fetch_add(1, std::memory_order_relaxed);

            if (flash_mode_) {
                // Flash mode: bypass jitter buffer, feed directly to depacketizer
                process_packet_direct(packet_buffer.data(), received);

                // Drain all remaining packets in the socket (non-blocking)
                while (running.load()) {
                    int extra = receiver->receive(packet_buffer.data(),
                                                  packet_buffer.size(),
                                                  0);  // non-blocking
                    if (extra <= 0) break;
                    frames_received.fetch_add(1, std::memory_order_relaxed);
                    process_packet_direct(packet_buffer.data(), extra);
                }
            } else {
                // Stable mode: use jitter buffer for reordering
                jitter_buffer->add_packet(packet_buffer.data(), received,
                                          os_gettime_ns());
                process_jitter_buffer();
            }
        }

        // Unregister port from global registry when receive loop exits
        {
            std::lock_guard<std::mutex> lock(g_ports_mutex);
            g_bound_ports.erase(current_bound_port);
        }

        receiver->close();
    }

    /**
     * Process a raw UDP packet directly (bypassing jitter buffer)
     * Used in flash mode for minimum latency on stable LAN
     */
    void process_packet_direct(const uint8_t *data, int size) {
        if (size < 12) return;  // Minimum RTP header size

        packet_count++;

        auto nal_units = depacketizer->process(data, size);
        total_nals += nal_units.size();

        if (debug_mode && packet_count % 500 == 0) {
            blog(LOG_INFO, "[avolocam] Packets: %d, NALs: %d (flash mode)", packet_count, total_nals);
        }

        for (auto& nal : nal_units) {
            uint8_t nal_type = static_cast<uint8_t>(nal.type);

            if (debug_mode && (nal_type == 7 || nal_type == 8 || nal_type == 5)) {
                blog(LOG_INFO, "[avolocam] NAL type=%d (SPS=7/PPS=8/IDR=5), size=%zu, marker=%d",
                     nal_type, nal.data.size(), nal.marker);
            }

            if (!sync_state->can_decode(nal.type, nal.is_idr)) {
                frames_dropped.fetch_add(1, std::memory_order_relaxed);
                continue;
            }

            auto access_unit = assembler->add_nal(
                std::move(nal.data),
                nal.rtp_timestamp,
                nal.marker
            );

            if (access_unit) {
                push_to_decode_queue(std::move(*access_unit));
            }
        }
    }

    void process_jitter_buffer() {
        std::vector<uint8_t> packet;
        uint64_t recv_time;

        while (jitter_buffer->get_next_packet(packet, recv_time)) {
            packet_count++;

            // Parse RTP and extract NAL units
            auto nal_units = depacketizer->process(packet.data(), packet.size());
            total_nals += nal_units.size();

            // Log periodically (only in debug mode)
            if (debug_mode && packet_count % 500 == 0) {
                blog(LOG_INFO, "[avolocam] Packets: %d, NALs: %d", packet_count, total_nals);
            }

            for (auto& nal : nal_units) {
                uint8_t nal_type = static_cast<uint8_t>(nal.type);

                // Log SPS/PPS/IDR only in debug mode
                if (debug_mode && (nal_type == 7 || nal_type == 8 || nal_type == 5)) {
                    blog(LOG_INFO, "[avolocam] NAL type=%d (SPS=7/PPS=8/IDR=5), size=%zu, marker=%d",
                         nal_type, nal.data.size(), nal.marker);
                }

                // Check sync state
                if (!sync_state->can_decode(nal.type, nal.is_idr)) {
                    if (debug_mode && (nal_type == 7 || nal_type == 8 || nal_type == 5)) {
                        blog(LOG_WARNING, "[avolocam] Sync state rejected NAL type=%d", nal_type);
                    }
                    frames_dropped.fetch_add(1, std::memory_order_relaxed);
                    continue;
                }

                // Add NAL to assembler
                auto access_unit = assembler->add_nal(
                    std::move(nal.data),
                    nal.rtp_timestamp,
                    nal.marker
                );

                if (access_unit) {
                    // Push to decode queue (async pipeline)
                    push_to_decode_queue(std::move(*access_unit));
                }
            }
        }
    }

    /**
     * Push access unit to decode queue with drop policy
     * If queue is full, drop oldest frame (not the new one)
     */
    void push_to_decode_queue(AccessUnit&& au) {
        std::lock_guard<std::mutex> lock(decode_queue_mutex_);

        if (flash_mode_ && max_decode_queue_size_ == 1) {
            // Flash mode with queue=1: replace the existing element in-place
            // to avoid the overhead of pop_front + push_back
            if (!decode_queue_.empty()) {
                decode_queue_.front() = std::move(au);
                decode_queue_drops.fetch_add(1, std::memory_order_relaxed);
            } else {
                decode_queue_.push_back(std::move(au));
            }
        } else {
            // Standard mode: drop oldest if queue is full
            if (decode_queue_.size() >= max_decode_queue_size_) {
                decode_queue_.pop_front();
                decode_queue_drops.fetch_add(1, std::memory_order_relaxed);
            }
            decode_queue_.push_back(std::move(au));
        }
        decode_queue_cv_.notify_one();
    }

    /**
     * Decode thread main loop (Phase 3: async pipeline)
     * Pulls access units from queue and decodes them
     */
    void decode_loop() {
        blog(LOG_INFO, "[avolocam] Decode thread started");

        while (running.load()) {
            AccessUnit au;
            bool has_au = false;

            // Wait for work
            {
                std::unique_lock<std::mutex> lock(decode_queue_mutex_);
                if (decode_queue_.empty()) {
                    // Flash mode: 1ms wait with predicate for fastest wakeup
                    // Stable mode: 50ms wait (less CPU usage)
                    auto wait_ms = flash_mode_ ? 1 : 50;
                    decode_queue_cv_.wait_for(lock,
                        std::chrono::milliseconds(wait_ms),
                        [this]() { return !decode_queue_.empty() || !running.load(); });
                }

                if (!decode_queue_.empty()) {
                    au = std::move(decode_queue_.front());
                    decode_queue_.pop_front();
                    has_au = true;
                }
            }

            if (!has_au) continue;
            if (!running.load()) break;

            // Decode the access unit
            decode_frame_async(au);
        }

        blog(LOG_INFO, "[avolocam] Decode thread stopped");
    }

    /**
     * Decode a frame and store in latest_frame_ (async version)
     */
    void decode_frame_async(const AccessUnit& au) {
        au_count++;

        if (!decoder) {
            frames_dropped.fetch_add(1, std::memory_order_relaxed);
            return;
        }

        // Log decode timing stats every 300 frames
        if (debug_mode && au_count % 300 == 0 && decoder->is_initialized()) {
            const auto& stats = decoder->get_timing_stats();
            uint64_t queue_drops = decode_queue_drops.load();
            blog(LOG_INFO, "[avolocam] Decode timing (avg over %llu frames): "
                 "input=%.2fms output=%.2fms lock=%.2fms copy=%.2fms total=%.2fms | queue_drops=%llu",
                 (unsigned long long)stats.frame_count,
                 stats.avg_input_ms(),
                 stats.avg_output_ms(),
                 stats.avg_lock_ms(),
                 stats.avg_memcpy_ms(),
                 stats.avg_total_ms(),
                 (unsigned long long)queue_drops);
        }

        // Initialize decoder if needed
        if (!decoder->is_initialized()) {
            if (au.has_sps && au.has_pps) {
                std::vector<uint8_t> sps, pps;
                extract_parameter_sets(au.data, sps, pps);
                if (!sps.empty() && !pps.empty()) {
                    if (decoder->initialize(sps.data(), sps.size(), pps.data(), pps.size())) {
                        // Enable GPU output if decoder supports it AND
                        // exposes its D3D device (needed for GPUConverter NV12→RGBA).
                        // MF decoder exposes a D3D device but currently uses the CPU
                        // conversion path due to GPUConverter interop constraints.
                        // FFmpeg D3D11VA exposes a compatible device → full GPU zero-copy path.
                        if (prefer_zero_copy && decoder->supports_gpu_output()
                            && decoder->get_d3d_device()) {
                            decoder->set_gpu_output(true);
                            use_gpu_decode_ = true;
                            blog(LOG_INFO, "[avolocam] GPU decode enabled (CUSTOM_DRAW path)");
                        } else {
                            use_gpu_decode_ = false;
                        }

                        // Set decode queue size based on mode and decoder type:
                        // Flash mode: always 1 (minimum latency)
                        // Hardware decoders are fast → small queue (4)
                        // Software fallback is slower → larger queue (6) to absorb stalls
                        if (flash_mode_) {
                            max_decode_queue_size_ = 1;
                            blog(LOG_INFO, "[avolocam] Decoder initialized (%s), "
                                 "flash mode: decode queue size = 1",
                                 decoder->is_hardware() ? "hardware" : "software");
                        } else if (decoder->is_hardware()) {
                            max_decode_queue_size_ = 4;
                            blog(LOG_INFO, "[avolocam] Decoder initialized (hardware), "
                                 "decode queue size = 4");
                        } else {
                            max_decode_queue_size_ = 6;
                            blog(LOG_INFO, "[avolocam] Decoder initialized (software fallback), "
                                 "decode queue size = 6");
                        }
                    }
                }
            }
            if (!decoder->is_initialized()) {
                frames_dropped.fetch_add(1, std::memory_order_relaxed);
                return;
            }
        }

        // Decode
        DecodedFrame frame;
        if (!decoder->decode(au.data.data(), au.data.size(), frame)) {
            frames_dropped.fetch_add(1, std::memory_order_relaxed);
            return;
        }

        frames_decoded.fetch_add(1, std::memory_order_relaxed);

        // GPU path: use shared RGBA texture handle for zero-copy CUSTOM_DRAW
#ifdef _WIN32
        if (frame.has_gpu_texture && frame.gpu_texture && use_gpu_decode_) {
            // Initialize GPUConverter once with decoder's D3D11 device
            if (!gpu_converter_initialized_ && decoder) {
                void *dev = decoder->get_d3d_device();
                void *ctx = decoder->get_d3d_context();
                if (dev && ctx) {
                    gpu_converter_ = std::make_unique<GPUConverter>();
                    if (gpu_converter_->initialize(
                            static_cast<ID3D11Device*>(dev),
                            static_cast<ID3D11DeviceContext*>(ctx))) {
                        gpu_converter_initialized_ = true;
                        blog(LOG_INFO, "[avolocam] GPUConverter initialized for CUSTOM_DRAW path");
                    } else {
                        gpu_converter_.reset();
                        blog(LOG_WARNING, "[avolocam] GPUConverter init failed, using CPU path");
                    }
                }
            }

            // Convert NV12 shared texture → RGBA shared texture via GPUConverter
            if (gpu_converter_initialized_ && gpu_converter_) {
                GPUDecodedFrame gpu_input;
                gpu_input.texture = static_cast<ID3D11Texture2D*>(frame.gpu_texture);
                gpu_input.subresource = 0;
                gpu_input.width = frame.width;
                gpu_input.height = frame.height;
                gpu_input.pts = 0;

                ConvertedFrame converted;
                if (gpu_converter_->convert(gpu_input, converted)) {
                    // Flush decoder device to ensure GPU commands are submitted
                    auto *ctx = static_cast<ID3D11DeviceContext*>(decoder->get_d3d_context());
                    if (ctx) ctx->Flush();

                    // Store dimensions first, then handle with release so
                    // the render thread's acquire load sees consistent values.
                    gpu_texture_width_.store(frame.width, std::memory_order_relaxed);
                    gpu_texture_height_.store(frame.height, std::memory_order_relaxed);
                    latest_shared_handle_.store(converted.shared_handle, std::memory_order_release);
                    use_gpu_render_ = true;

                    output_count++;
                    if (output_count == 1) {
                        blog(LOG_INFO, "[avolocam] First GPU frame (CUSTOM_DRAW): %ux%u, handle=%p",
                             frame.width, frame.height, converted.shared_handle);
                    }

                    // Release the converted frame back to pool (handle stays valid)
                    gpu_converter_->release_frame(converted);
                    return;
                }
                blog(LOG_WARNING, "[avolocam] GPU conversion failed, falling back to CPU");
            }
            // Fall through to CPU path
        }
#endif

        // CPU path - existing code
        if (!frame.y_plane) {
            frames_dropped.fetch_add(1, std::memory_order_relaxed);
            return;
        }

        // Store in latest frame buffer (double buffering)
        // Use current_frame_buffer_ to select which buffer to write to
        int write_idx = 1 - current_frame_buffer_.load();  // Write to the other buffer
        LatestFrame* write_buf = (write_idx == 0) ? &frame_buffer_a_ : &frame_buffer_b_;

        // Copy frame data to buffer
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
        current_frame_buffer_.store(write_idx);
        latest_frame_.store(write_buf);

        // Also output immediately (for async video source compatibility)
        output_latest_frame();
    }

    /**
     * Output the latest decoded frame to OBS
     */
    void output_latest_frame() {
        LatestFrame* frame = latest_frame_.load();
        if (!frame || !frame->valid) return;
        if (!source) return;

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
            blog(LOG_INFO, "[avolocam] First frame output: %ux%u", frame->width, frame->height);
        } else if (debug_mode && output_count % 300 == 0) {
            blog(LOG_INFO, "[avolocam] Output frame #%d: %ux%u",
                 output_count, frame->width, frame->height);
        }
    }

    // Get current latency for overlay display
    double get_display_latency() const {
        return current_latency_ms.load(std::memory_order_relaxed);
    }

    /**
     * Send tally state to iOS device via WebSocket
     *
     * Checks if source is in Program (showing on output) or Preview.
     * Only sends when state changes to avoid spamming.
     */
    void send_tally_state() {
        if (!ws_client || !ws_client->is_connected()) return;
        if (!source) return;

        // obs_source_showing() returns true if the source is visible on the final output (Program)
        // obs_source_active() returns true if the source is active (either Program OR Preview)
        bool is_program = obs_source_showing(source);
        bool is_preview = obs_source_active(source) && !is_program;

        // Only send if state changed
        if (is_program == tally_program.load() && is_preview == tally_preview.load())
            return;

        tally_program.store(is_program);
        tally_preview.store(is_preview);

        char json[128];
        snprintf(json, sizeof(json),
                 R"({"op":"tally","program":%s,"preview":%s})",
                 is_program ? "true" : "false",
                 is_preview ? "true" : "false");

        ws_client->send_command(json);

        if (debug_mode) {
            blog(LOG_INFO, "[avolocam] Tally state sent: program=%s, preview=%s",
                 is_program ? "true" : "false",
                 is_preview ? "true" : "false");
        }
    }

    // Extract SPS and PPS from Annex B formatted data
    void extract_parameter_sets(const std::vector<uint8_t>& data,
                                 std::vector<uint8_t>& sps,
                                 std::vector<uint8_t>& pps) {
        sps.clear();
        pps.clear();

        size_t i = 0;
        while (i < data.size()) {
            // Find start code
            size_t start_code_len = 0;
            if (i + 3 <= data.size() && data[i] == 0 && data[i+1] == 0) {
                if (data[i+2] == 1) {
                    start_code_len = 3;
                } else if (i + 4 <= data.size() && data[i+2] == 0 && data[i+3] == 1) {
                    start_code_len = 4;
                }
            }

            if (start_code_len == 0) {
                i++;
                continue;
            }

            size_t nal_start = i + start_code_len;
            if (nal_start >= data.size()) break;

            // Find end of NAL (next start code or end of data)
            size_t nal_end = data.size();
            for (size_t j = nal_start; j + 2 < data.size(); j++) {
                if (data[j] == 0 && data[j+1] == 0 &&
                    (data[j+2] == 1 || (j + 3 < data.size() && data[j+2] == 0 && data[j+3] == 1))) {
                    nal_end = j;
                    break;
                }
            }

            // Extract NAL type
            uint8_t nal_type = data[nal_start] & 0x1F;

            if (nal_type == 7 && sps.empty()) {
                // SPS - copy without start code
                sps.assign(data.begin() + nal_start, data.begin() + nal_end);
            } else if (nal_type == 8 && pps.empty()) {
                // PPS - copy without start code
                pps.assign(data.begin() + nal_start, data.begin() + nal_end);
            }

            i = nal_end;

            // Early exit if we have both
            if (!sps.empty() && !pps.empty()) break;
        }
    }
};

// ============================================================================
// OBS Source Callbacks
// ============================================================================

static const char *avolocam_get_name(void *)
{
    return "AvoCam Flash Source";
}

static void *avolocam_create(obs_data_t *settings, obs_source_t *source)
{
    auto *data = new SourceData();
    data->source = source;

    // Load settings
    data->camera_ip = obs_data_get_string(settings, PROP_MANUAL_IP);
    data->camera_port = (uint16_t)obs_data_get_int(settings, PROP_MANUAL_PORT);
    data->jitter_mode = (int)obs_data_get_int(settings, PROP_JITTER_MODE);
    data->show_latency = obs_data_get_bool(settings, PROP_SHOW_LATENCY);
    data->auth_token = obs_data_get_string(settings, PROP_AUTH_TOKEN);
    data->prefer_zero_copy = obs_data_get_bool(settings, PROP_PREFER_ZERO_COPY);
    data->debug_mode = obs_data_get_bool(settings, PROP_DEBUG_MODE);
    data->decoder_type = (int)obs_data_get_int(settings, PROP_DECODER_TYPE);

    if (data->camera_port == 0) {
        data->camera_port = allocate_next_port();
        blog(LOG_INFO, "[avolocam] Auto-assigned UDP port %d", data->camera_port);
    }

    blog(LOG_INFO, "[avolocam] Source created (decoder_type=%d, port=%d)",
         data->decoder_type, data->camera_port);
    return data;
}

static void avolocam_destroy(void *data)
{
    auto *src = static_cast<SourceData *>(data);
    delete src;
    blog(LOG_INFO, "[avolocam] Source destroyed");
}

static void avolocam_update(void *data, obs_data_t *settings)
{
    auto *src = static_cast<SourceData *>(data);

    // Check if a camera was selected from the dropdown
    std::string camera_select = obs_data_get_string(settings, PROP_CAMERA_SELECT);
    std::string new_ip = obs_data_get_string(settings, PROP_MANUAL_IP);
    uint16_t new_port = (uint16_t)obs_data_get_int(settings, PROP_MANUAL_PORT);

    // If a camera was selected from dropdown, use it as the IP
    // Note: Port is NOT from dropdown - it must be set manually to match Tauri assignment
    if (!camera_select.empty()) {
        new_ip = camera_select;
        blog(LOG_INFO, "[avolocam] Selected camera from dropdown: %s (port from manual field: %d)",
             new_ip.c_str(), new_port);
    }

    int new_jitter = (int)obs_data_get_int(settings, PROP_JITTER_MODE);
    std::string new_token = obs_data_get_string(settings, PROP_AUTH_TOKEN);
    bool new_zero_copy = obs_data_get_bool(settings, PROP_PREFER_ZERO_COPY);
    bool new_debug_mode = obs_data_get_bool(settings, PROP_DEBUG_MODE);
    int new_decoder_type = (int)obs_data_get_int(settings, PROP_DECODER_TYPE);

    if (new_port == 0) {
        new_port = allocate_next_port();
        blog(LOG_INFO, "[avolocam] Auto-assigned UDP port %d on update", new_port);
    }

    // Check if we need to restart
    bool needs_restart = (new_ip != src->camera_ip ||
                          new_port != src->camera_port ||
                          new_jitter != src->jitter_mode ||
                          new_token != src->auth_token ||
                          new_zero_copy != src->prefer_zero_copy ||
                          new_decoder_type != src->decoder_type);

    src->camera_ip = new_ip;
    src->camera_port = new_port;
    src->jitter_mode = new_jitter;
    src->show_latency = obs_data_get_bool(settings, PROP_SHOW_LATENCY);
    src->auth_token = new_token;
    src->prefer_zero_copy = new_zero_copy;
    src->debug_mode = new_debug_mode;
    src->decoder_type = new_decoder_type;

    if (needs_restart && src->running.load()) {
        src->stop();
        src->start();
    }
}

static void avolocam_activate(void *data)
{
    auto *src = static_cast<SourceData *>(data);
    blog(LOG_INFO, "[avolocam] Source activated");
    src->start();
}

static void avolocam_deactivate(void *data)
{
    auto *src = static_cast<SourceData *>(data);
    blog(LOG_INFO, "[avolocam] Source deactivated (keeping decoder running for fast switching)");
    // Don't stop the decoder here - keep it running for instant scene switching
    // The decoder will be stopped when the source is destroyed
}

static void avolocam_show(void *data)
{
    auto *src = static_cast<SourceData *>(data);
    src->visible.store(true);
    blog(LOG_INFO, "[avolocam] Source shown");
}

static void avolocam_hide(void *data)
{
    auto *src = static_cast<SourceData *>(data);
    src->visible.store(false);
    blog(LOG_INFO, "[avolocam] Source hidden");
}

// Callback to auto-fill IP when camera is selected from dropdown
// Port is ALWAYS visible since it must be set manually per Tauri assignment
static bool camera_select_changed(obs_properties_t *props, obs_property_t *,
                                   obs_data_t *settings)
{
    const char *selected = obs_data_get_string(settings, PROP_CAMERA_SELECT);

    // Auto-fill the IP field if a camera was selected
    if (selected && selected[0] != '\0') {
        obs_data_set_string(settings, PROP_MANUAL_IP, selected);
    }

    // IP and Port fields are ALWAYS visible
    // - IP is auto-filled from dropdown but can be edited
    // - Port must always be set manually to match Tauri Controller assignment
    (void)props;  // Fields always visible, no need to modify

    return true;  // Refresh properties UI
}

// Callback to check port collision when user changes port value
static bool port_changed_callback(void *priv, obs_properties_t *props,
                                   obs_property_t *, obs_data_t *settings)
{
    uint16_t port = (uint16_t)obs_data_get_int(settings, PROP_MANUAL_PORT);
    obs_property_t *warning = obs_properties_get(props, PROP_PORT_WARNING);
    if (!warning) return false;

    // Exclude this source's own currently-bound port from collision check
    auto *src = static_cast<SourceData *>(priv);
    uint16_t own_port = (src && src->running.load()) ? src->camera_port : 0;

    bool collision = false;
    if (port > 0) {
        std::lock_guard<std::mutex> lock(g_ports_mutex);
        collision = g_bound_ports.count(port) > 0 && port != own_port;
    }

    obs_property_set_visible(warning, collision);
    return true;  // Refresh properties UI
}

static obs_properties_t *avolocam_get_properties(void *data)
{
    obs_properties_t *props = obs_properties_create();

    // Camera selection dropdown (populated by mDNS discovery)
    obs_property_t *camera_list = obs_properties_add_list(
        props, PROP_CAMERA_SELECT, "Camera",
        OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_STRING);
    obs_property_list_add_string(camera_list, "(Manual Entry)", "");

    // Add discovered cameras from global discovery
    // Note: Only store IP, NOT port - port is assigned by Tauri Controller per-camera
    {
        std::lock_guard<std::mutex> lock(g_discovery_mutex);
        if (g_discovery) {
            for (const auto& cam : g_discovery->get_cameras()) {
                std::string label = cam.alias.empty() ? cam.name : cam.alias;
                label += " (" + cam.ip + ")";
                // Store only IP - user must set port manually to match Tauri assignment
                obs_property_list_add_string(camera_list, label.c_str(), cam.ip.c_str());
            }
        }
    }

    // Set callback to auto-fill IP when camera is selected
    obs_property_set_modified_callback(camera_list, camera_select_changed);

    // Camera IP - auto-filled from dropdown but editable
    obs_property_t *ip_prop = obs_properties_add_text(props, PROP_MANUAL_IP, "Camera IP",
                            OBS_TEXT_DEFAULT);
    obs_property_set_visible(ip_prop, true);

    // UDP Port - ALWAYS visible, must match Tauri Controller assignment (5000 + camera_index)
    obs_property_t *port_prop = obs_properties_add_int(props, PROP_MANUAL_PORT, "UDP Port (from Tauri)",
                           1024, 65535, 1);
    obs_property_set_visible(port_prop, true);
    obs_property_set_long_description(port_prop,
        "Must match the port assigned by Tauri Controller (5000 for first camera, 5001 for second, etc.)");
    obs_property_set_modified_callback2(port_prop, port_changed_callback, data);

    // Port collision warning (hidden by default, shown by port_changed_callback)
    obs_property_t *port_warn = obs_properties_add_text(props, PROP_PORT_WARNING,
        "WARNING: This port is already in use by another AvoCam source!",
        OBS_TEXT_INFO);
    obs_property_set_visible(port_warn, false);

    // Authentication token
    obs_properties_add_text(props, PROP_AUTH_TOKEN, "Auth Token",
                            OBS_TEXT_PASSWORD);

    // Jitter buffer mode
    obs_property_t *jitter = obs_properties_add_list(
        props, PROP_JITTER_MODE, "Jitter Buffer",
        OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_INT);
    obs_property_list_add_int(jitter, "Ultra-Low (0-8ms)", JITTER_ULTRA_LOW);
    obs_property_list_add_int(jitter, "Stable (16-50ms)", JITTER_STABLE);

    // Show latency overlay
    obs_properties_add_bool(props, PROP_SHOW_LATENCY, "Show Latency Overlay");

    // GPU zero-copy option
    obs_properties_add_bool(props, PROP_PREFER_ZERO_COPY,
                            "Prefer GPU Zero-Copy (requires compatible GPU)");

    // Decoder type selection
    obs_property_t *decoder = obs_properties_add_list(
        props, PROP_DECODER_TYPE, "Decoder",
        OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_INT);
    obs_property_list_add_int(decoder, "Auto (Recommended)", DECODER_TYPE_AUTO);
    obs_property_list_add_int(decoder, "Media Foundation (D3D11VA)", DECODER_TYPE_MEDIA_FOUNDATION);
#ifdef HAVE_FFMPEG_D3D11VA
    obs_property_list_add_int(decoder, "FFmpeg D3D11VA (Low Latency)", DECODER_TYPE_FFMPEG_D3D11VA);
#endif
    obs_property_set_long_description(decoder,
        "Decoder selection:\n"
        "- Auto: Uses Media Foundation (proven stable)\n"
        "- Media Foundation: Windows built-in hardware decoder\n"
        "- FFmpeg D3D11VA: Alternative low-latency decoder (experimental)");

    // Debug mode
    obs_properties_add_bool(props, PROP_DEBUG_MODE, "Enable debug logging");

    return props;
}

static void avolocam_get_defaults(obs_data_t *settings)
{
    obs_data_set_default_string(settings, PROP_MANUAL_IP, "");
    obs_data_set_default_int(settings, PROP_MANUAL_PORT, 5000);
    obs_data_set_default_int(settings, PROP_JITTER_MODE, JITTER_STABLE);
    obs_data_set_default_bool(settings, PROP_SHOW_LATENCY, false);
    obs_data_set_default_string(settings, PROP_AUTH_TOKEN, "");
    obs_data_set_default_bool(settings, PROP_PREFER_ZERO_COPY, true);
    obs_data_set_default_bool(settings, PROP_DEBUG_MODE, false);
    obs_data_set_default_int(settings, PROP_DECODER_TYPE, DECODER_TYPE_AUTO);
}

// video_tick: open/update shared texture for CUSTOM_DRAW (called on render thread)
static void avolocam_video_tick(void *data, float seconds)
{
    UNUSED_PARAMETER(seconds);
    auto *src = static_cast<SourceData *>(data);

    if (src->use_gpu_render_) {
        // GPU PATH: open the shared RGBA texture on OBS device (cached)
        void *h = src->latest_shared_handle_.load(std::memory_order_acquire);
        if (h && h != src->cached_shared_handle_) {
            obs_enter_graphics();
            if (src->obs_shared_texture_) {
                gs_texture_destroy(src->obs_shared_texture_);
                src->obs_shared_texture_ = nullptr;
            }
            // Legacy DXGI shared handles (D3D11_RESOURCE_MISC_SHARED) are
            // kernel object indices that fit in 32 bits even on x64.
            // gs_texture_open_shared() takes uint32_t matching this convention.
            src->obs_shared_texture_ = gs_texture_open_shared(
                static_cast<uint32_t>(reinterpret_cast<uintptr_t>(h)));
            obs_leave_graphics();

            if (src->obs_shared_texture_) {
                src->cached_shared_handle_ = h;
            } else {
                blog(LOG_WARNING, "[avolocam] gs_texture_open_shared failed for handle %p", h);
            }
        }
    } else {
        // CPU FALLBACK: upload NV12 frame data into a BGRX texture
        SourceData::LatestFrame *frame = src->latest_frame_.load(std::memory_order_acquire);
        if (frame && frame->valid) {
            // CPU fallback uses ASYNC_VIDEO mode via obs_source_output_video
            // (called in decode_frame_async), so no texture upload is needed here.
        }
    }
}

// video_render: draw the GPU or CPU texture (called on render thread)
static void avolocam_video_render(void *data, gs_effect_t *effect)
{
    UNUSED_PARAMETER(effect);
    auto *src = static_cast<SourceData *>(data);

    if (src->use_gpu_render_ && src->obs_shared_texture_) {
        // GPU zero-copy path: draw shared RGBA texture
        // Use OBS_EFFECT_OPAQUE (no alpha) + gs_effect_loop pattern (like game-capture)
        effect = obs_get_base_effect(OBS_EFFECT_OPAQUE);
        while (gs_effect_loop(effect, "Draw")) {
            obs_source_draw(src->obs_shared_texture_, 0, 0, 0, 0, false);
        }
    }
    // CPU fallback: do nothing here — OBS's async video pipeline
    // (obs_source_output_video) renders the frame independently.
    // NOTE: obs_source_default_render MUST NOT be called from within
    // video_render on the same source — it causes infinite recursion.
}

static uint32_t avolocam_get_width(void *data)
{
    auto *src = static_cast<SourceData *>(data);
    uint32_t w = src->gpu_texture_width_.load(std::memory_order_relaxed);
    if (w > 0)
        return w;
    if (src->decoder)
        return src->decoder->get_width();
    return 1920;
}

static uint32_t avolocam_get_height(void *data)
{
    auto *src = static_cast<SourceData *>(data);
    uint32_t h = src->gpu_texture_height_.load(std::memory_order_relaxed);
    if (h > 0)
        return h;
    if (src->decoder)
        return src->decoder->get_height();
    return 1080;
}

} // namespace avolocam

// ============================================================================
// Public API
// ============================================================================

void avolocam_source_register(void)
{
    // Start global mDNS discovery
    {
        std::lock_guard<std::mutex> lock(avolocam::g_discovery_mutex);
        avolocam::g_discovery = std::make_unique<avolocam::MdnsDiscovery>();
        if (avolocam::g_discovery->start([](avolocam::DiscoveryEvent event, const avolocam::DiscoveredCamera& cam) {
            const char* event_str = (event == avolocam::DiscoveryEvent::Added) ? "discovered" :
                                    (event == avolocam::DiscoveryEvent::Updated) ? "updated" : "removed";
            blog(LOG_INFO, "[avolocam] Camera %s: %s (%s:%d)",
                 event_str, cam.alias.c_str(), cam.ip.c_str(), cam.flash_udp_port);
        })) {
            blog(LOG_INFO, "[avolocam] mDNS discovery started");
        } else {
            blog(LOG_WARNING, "[avolocam] Failed to start mDNS discovery");
        }
    }

    struct obs_source_info info = {};

    info.id = "avolocam_source";
    info.type = OBS_SOURCE_TYPE_INPUT;
    // CUSTOM_DRAW + ASYNC_VIDEO: GPU zero-copy when available, CPU async fallback
    info.output_flags = OBS_SOURCE_ASYNC_VIDEO | OBS_SOURCE_VIDEO
                      | OBS_SOURCE_CUSTOM_DRAW;
    info.get_name = avolocam::avolocam_get_name;
    info.create = avolocam::avolocam_create;
    info.destroy = avolocam::avolocam_destroy;
    info.update = avolocam::avolocam_update;
    info.activate = avolocam::avolocam_activate;
    info.deactivate = avolocam::avolocam_deactivate;
    info.show = avolocam::avolocam_show;
    info.hide = avolocam::avolocam_hide;
    info.get_properties = avolocam::avolocam_get_properties;
    info.get_defaults = avolocam::avolocam_get_defaults;
    info.video_tick = avolocam::avolocam_video_tick;
    info.video_render = avolocam::avolocam_video_render;
    info.get_width = avolocam::avolocam_get_width;
    info.get_height = avolocam::avolocam_get_height;

    obs_register_source(&info);
    blog(LOG_INFO, "[avolocam] Source type registered");
}
