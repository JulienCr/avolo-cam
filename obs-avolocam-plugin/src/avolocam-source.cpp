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
#include <cstring>

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


/**
 * Source instance data
 */
struct SourceData {
    obs_source_t *source = nullptr;

    // Configuration (thread-safe: atomics for simple types, config_mutex_ for strings)
    std::string camera_ip;               // protected by config_mutex_
    std::atomic<uint16_t> camera_port{5000};
    std::atomic<int> jitter_mode{JITTER_STABLE};
    std::atomic<bool> show_latency{false};
    std::string auth_token;              // protected by config_mutex_
    std::atomic<bool> prefer_zero_copy{true};
    std::atomic<bool> debug_mode{false};
    std::atomic<int> decoder_type{DECODER_TYPE_AUTO};
    std::mutex config_mutex_;            // protects camera_ip, auth_token

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
    std::thread ws_connect_thread_;  // WebSocket connect thread (joinable, not detached)
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
    std::atomic<bool> use_gpu_decode_{false};

    // Flash mode: ultra-low latency path (derived from jitter_mode == ULTRA_LOW)
    std::atomic<bool> flash_mode_{false};

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
    std::atomic<bool> use_gpu_render_{false};

    // CPU fallback texture for CUSTOM_DRAW mode
    gs_texture_t *cpu_fallback_texture_ = nullptr;
    uint32_t cpu_fallback_width_ = 0;
    uint32_t cpu_fallback_height_ = 0;

    // "No signal" test pattern
    gs_texture_t *test_pattern_texture_ = nullptr;
    bool test_pattern_created_ = false;
    std::string test_pattern_ip_;   // IP baked into current test pattern
    std::string test_pattern_name_; // source name baked into current test pattern
    static constexpr uint32_t TEST_PATTERN_WIDTH = 1920;
    static constexpr uint32_t TEST_PATTERN_HEIGHT = 1080;

    SourceData() = default;
    ~SourceData() {
        stop();
        if (test_pattern_texture_) {
            obs_enter_graphics();
            gs_texture_destroy(test_pattern_texture_);
            obs_leave_graphics();
            test_pattern_texture_ = nullptr;
        }
    }

    void start() {
        if (running.load()) return;

        // Snapshot config under lock
        std::string ip_copy, token_copy;
        {
            std::lock_guard<std::mutex> lock(config_mutex_);
            ip_copy = camera_ip;
            token_copy = auth_token;
        }
        uint16_t port_copy = camera_port.load();
        int jitter_copy = jitter_mode.load();
        bool zero_copy = prefer_zero_copy.load();
        int dec_type = decoder_type.load();

        if (ip_copy.empty()) {
            blog(LOG_WARNING, "[avolocam] No camera IP configured");
            return;
        }

        // Check port availability before starting
        {
            std::lock_guard<std::mutex> lock(g_ports_mutex);
            if (g_bound_ports.count(port_copy)) {
                blog(LOG_ERROR, "[avolocam] Port %d is already in use by another AvoCam source. "
                     "Each source must use a unique UDP port.", port_copy);
                return;
            }
        }

        blog(LOG_INFO, "[avolocam] Starting receiver for %s:%d",
             ip_copy.c_str(), port_copy);

        // Derive flash mode from jitter setting
        flash_mode_.store(jitter_copy == JITTER_ULTRA_LOW);

        // Initialize components
        receiver = std::make_unique<UdpReceiver>();
        receiver->set_expected_source(ip_copy);  // Filter packets to only accept from this camera
        jitter_buffer = std::make_unique<JitterBuffer>(
            jitter_copy == JITTER_ULTRA_LOW ? 8 : 50  // max_delay_ms
        );
        depacketizer = std::make_unique<RtpDepacketizer>();
        depacketizer->set_packet_loss_callback([this](int missing) {
            if (sync_state) sync_state->on_packet_loss(missing);
        });
        assembler = std::make_unique<AccessUnitAssembler>();
        sync_state = std::make_unique<SyncStateMachine>();
        timestamp_mapper = std::make_unique<TimestampMapper>();

        // Initialize texture output
        texture_output = std::make_unique<TextureOutput>();
        texture_output->initialize(source, zero_copy);

        // Create platform-specific decoder with configured type
        DecoderConfig decoder_config;
        decoder_config.prefer_hardware = zero_copy;
        decoder_config.low_latency = true;
        decoder_config.output_nv12 = true;
        decoder_config.decoder_type = static_cast<DecoderType>(dec_type);

        decoder = PlatformDecoder::create(decoder_config);
        if (!decoder) {
            blog(LOG_ERROR, "[avolocam] Failed to create decoder");
            return;
        }

        // Note: GPU output will be enabled after decoder initialization in decode_frame_async
        // because supports_gpu_output() requires the D3D device to be created first
        use_gpu_decode_.store(zero_copy);  // Store preference, will verify after init

        // Flash mode: minimal decode queue for lowest latency
        if (flash_mode_.load()) {
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
        });

        // Re-send tally + subscribe to frame_info on every (re)connect
        ws_client->set_connection_callback([this](WSState state) {
            if (state == WSState::CONNECTED) {
                // Subscribe to frame_info channel (only OBS needs it)
                ws_client->send_command(R"({"op":"subscribe","channels":["frame_info"]})");

                // Invalidate cached tally state to force re-send on reconnect
                tally_program.store(!tally_program.load());
                tally_preview.store(!tally_preview.load());
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

        // Connect WebSocket in background — ws_client->connect() can block for
        // up to 21 seconds on TCP timeout when the camera is unreachable, and
        // start() runs on the OBS video thread (via activate callback).
        // Blocking here freezes ALL video_tick/video_render for every source.
        // Thread is stored (not detached) so stop() can join it safely.
        {
            std::string ws_url_str = "ws://" + ip_copy + ":"
                                     + std::to_string(DEFAULT_WS_PORT) + "/ws";
            auto ws = ws_client.get();
            ws_connect_thread_ = std::thread([ws, url = std::move(ws_url_str),
                         token = std::move(token_copy)]() {
                ws->connect(url, token);
            });
        }

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
            blog(LOG_ERROR, "[avolocam] Bind to port %d failed — stopping source", port_copy);
            running.store(false);

            // Two-phase WS shutdown (see stop() comment for rationale)
            if (ws_client) ws_client->disconnect();
            if (ws_connect_thread_.joinable()) ws_connect_thread_.join();
            if (ws_client) ws_client->disconnect();

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

        // Shut down WebSocket: two-phase disconnect.
        // Phase 1: close the socket to unblock ::connect() in ws_connect_thread_.
        // Phase 2 (after join): disconnect again because connect() may have
        // succeeded between phase 1 and join, re-creating socket + recv_thread_.
        if (ws_client) {
            ws_client->disconnect();
        }
        if (ws_connect_thread_.joinable()) {
            ws_connect_thread_.join();
        }
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
        use_gpu_render_.store(false);
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

        // Reset frame state so test pattern shows on next start
        latest_frame_.store(nullptr);
        frame_buffer_a_.valid = false;
        frame_buffer_b_.valid = false;

        // Clear OBS async video cache (otherwise last frame stays displayed)
        if (source) {
            obs_source_output_video(source, nullptr);
        }
    }

    void receive_loop() {
        uint16_t port = camera_port.load();

        // Bind to UDP port
        if (!receiver->bind(port)) {
            blog(LOG_ERROR, "[avolocam] Failed to bind to port %d - port may already be in use",
                 port);
            bind_result_.store(-1);
            return;
        }

        // Register port in global registry
        {
            std::lock_guard<std::mutex> lock(g_ports_mutex);
            g_bound_ports.insert(port);
        }

        bind_result_.store(1);  // Signal success to start()

        // Log actual receive buffer size for diagnostics
        int actual_rcvbuf = receiver->get_actual_rcvbuf();
        if (actual_rcvbuf > 0 && actual_rcvbuf < 2 * 1024 * 1024) {
            blog(LOG_WARNING, "[avolocam] UDP receive buffer is only %d bytes (requested 4MB). "
                 "This may cause packet drops with multiple cameras.", actual_rcvbuf);
        }

        blog(LOG_INFO, "[avolocam] Listening on UDP port %d (rcvbuf=%dKB)",
             port, actual_rcvbuf / 1024);

        std::vector<uint8_t> packet_buffer(2048);

        // Tally polling: check every ~100ms (change detection)
        constexpr uint64_t TALLY_POLL_INTERVAL_NS = 100 * 1000 * 1000;  // 100ms in nanoseconds
        uint64_t last_tally_check = os_gettime_ns();

        // Tally heartbeat: unconditional re-send every 2s (guards against lost messages)
        constexpr uint64_t TALLY_HEARTBEAT_NS = 2000ULL * 1000 * 1000;  // 2s
        uint64_t last_tally_heartbeat = os_gettime_ns();

        while (running.load()) {
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
            g_bound_ports.erase(port);
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
                        if (prefer_zero_copy.load() && decoder->supports_gpu_output()
                            && decoder->get_d3d_device()) {
                            decoder->set_gpu_output(true);
                            use_gpu_decode_.store(true);
                            blog(LOG_INFO, "[avolocam] GPU decode enabled (CUSTOM_DRAW path)");
                        } else {
                            use_gpu_decode_.store(false);
                        }

                        // Set decode queue size based on mode and decoder type:
                        // Flash mode: always 1 (minimum latency)
                        // Hardware decoders are fast → small queue (4)
                        // Software fallback is slower → larger queue (6) to absorb stalls
                        if (flash_mode_.load()) {
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
            if (sync_state) sync_state->on_decode_error();
            frames_dropped.fetch_add(1, std::memory_order_relaxed);
            return;
        }

        frames_decoded.fetch_add(1, std::memory_order_relaxed);

        // GPU path: use shared RGBA texture handle for zero-copy CUSTOM_DRAW
#ifdef _WIN32
        if (frame.has_gpu_texture && frame.gpu_texture && use_gpu_decode_.load()) {
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
                    use_gpu_render_.store(true);

                    output_count++;
                    if (output_count == 1) {
                        blog(LOG_INFO, "[avolocam] First GPU frame (CUSTOM_DRAW): %ux%u, handle=%p",
                             frame.width, frame.height, converted.shared_handle);
                    }

                    // Release the converted frame back to pool (handle stays valid)
                    gpu_converter_->release_frame(converted);
                    // Release IMFSample (MF decoder keeps texture alive via sample ref)
                    if (frame.platform_handle) {
                        static_cast<IUnknown*>(frame.platform_handle)->Release();
                        frame.platform_handle = nullptr;
                    }
                    return;
                }
                blog(LOG_WARNING, "[avolocam] GPU conversion failed, falling back to CPU");
            }
            // Fall through to CPU path — release IMFSample since GPU didn't consume it
            if (frame.platform_handle) {
                static_cast<IUnknown*>(frame.platform_handle)->Release();
                frame.platform_handle = nullptr;
            }
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

        blog(LOG_INFO, "[avolocam] Tally sent: program=%s, preview=%s (ws=%s)",
             is_program ? "true" : "false",
             is_preview ? "true" : "false",
             ws_client->is_connected() ? "connected" : "disconnected");
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
// "No Signal" SMPTE Test Pattern Generator
// ============================================================================

// Bitmap font: 5x7 pixel glyphs covering A-Z, 0-9, and common punctuation
// Each character is represented as 7 rows of 5-bit patterns
struct BitmapGlyph {
    uint8_t rows[7];
};

// ASCII-indexed font table (32..127). Index with: g_font[ch - 32]
// Lowercase a-z maps to uppercase via get_glyph(), so those entries are unused.
static const BitmapGlyph g_font[96] = {
    // 32 ' ' (space)
    {{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 }},
    // 33 '!'
    {{ 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00000, 0b00100 }},
    // 34 '"'
    {{ 0b01010, 0b01010, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 }},
    // 35 '#'
    {{ 0b01010, 0b11111, 0b01010, 0b01010, 0b11111, 0b01010, 0b00000 }},
    // 36 '$'
    {{ 0b00100, 0b01111, 0b10100, 0b01110, 0b00101, 0b11110, 0b00100 }},
    // 37 '%'
    {{ 0b11001, 0b11010, 0b00100, 0b00100, 0b01011, 0b10011, 0b00000 }},
    // 38 '&'
    {{ 0b01100, 0b10010, 0b01100, 0b10110, 0b10001, 0b10010, 0b01101 }},
    // 39 '\''
    {{ 0b00100, 0b00100, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 }},
    // 40 '('
    {{ 0b00010, 0b00100, 0b01000, 0b01000, 0b01000, 0b00100, 0b00010 }},
    // 41 ')'
    {{ 0b01000, 0b00100, 0b00010, 0b00010, 0b00010, 0b00100, 0b01000 }},
    // 42 '*'
    {{ 0b00000, 0b00100, 0b10101, 0b01110, 0b10101, 0b00100, 0b00000 }},
    // 43 '+'
    {{ 0b00000, 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0b00000 }},
    // 44 ','
    {{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00100, 0b01000 }},
    // 45 '-'
    {{ 0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000 }},
    // 46 '.'
    {{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00100 }},
    // 47 '/'
    {{ 0b00001, 0b00010, 0b00100, 0b00100, 0b01000, 0b10000, 0b00000 }},
    // 48 '0'
    {{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 }},
    // 49 '1'
    {{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 }},
    // 50 '2'
    {{ 0b01110, 0b10001, 0b00001, 0b00110, 0b01000, 0b10000, 0b11111 }},
    // 51 '3'
    {{ 0b01110, 0b10001, 0b00001, 0b00110, 0b00001, 0b10001, 0b01110 }},
    // 52 '4'
    {{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 }},
    // 53 '5'
    {{ 0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110 }},
    // 54 '6'
    {{ 0b01110, 0b10000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 }},
    // 55 '7'
    {{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 }},
    // 56 '8'
    {{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 }},
    // 57 '9'
    {{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001, 0b01110 }},
    // 58 ':'
    {{ 0b00000, 0b00000, 0b00100, 0b00000, 0b00000, 0b00100, 0b00000 }},
    // 59 ';'
    {{ 0b00000, 0b00000, 0b00100, 0b00000, 0b00000, 0b00100, 0b01000 }},
    // 60 '<'
    {{ 0b00010, 0b00100, 0b01000, 0b10000, 0b01000, 0b00100, 0b00010 }},
    // 61 '='
    {{ 0b00000, 0b00000, 0b11111, 0b00000, 0b11111, 0b00000, 0b00000 }},
    // 62 '>'
    {{ 0b10000, 0b01000, 0b00100, 0b00010, 0b00100, 0b01000, 0b10000 }},
    // 63 '?'
    {{ 0b01110, 0b10001, 0b00001, 0b00110, 0b00100, 0b00000, 0b00100 }},
    // 64 '@'
    {{ 0b01110, 0b10001, 0b10111, 0b10101, 0b10110, 0b10000, 0b01110 }},
    // 65 'A'
    {{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 }},
    // 66 'B'
    {{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110 }},
    // 67 'C'
    {{ 0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110 }},
    // 68 'D'
    {{ 0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110 }},
    // 69 'E'
    {{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 }},
    // 70 'F'
    {{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000 }},
    // 71 'G'
    {{ 0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01110 }},
    // 72 'H'
    {{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 }},
    // 73 'I'
    {{ 0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 }},
    // 74 'J'
    {{ 0b00111, 0b00010, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100 }},
    // 75 'K'
    {{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 }},
    // 76 'L'
    {{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 }},
    // 77 'M'
    {{ 0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001 }},
    // 78 'N'
    {{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001 }},
    // 79 'O'
    {{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 }},
    // 80 'P'
    {{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 }},
    // 81 'Q'
    {{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 }},
    // 82 'R'
    {{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 }},
    // 83 'S'
    {{ 0b01110, 0b10001, 0b10000, 0b01110, 0b00001, 0b10001, 0b01110 }},
    // 84 'T'
    {{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 }},
    // 85 'U'
    {{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 }},
    // 86 'V'
    {{ 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b01010, 0b00100 }},
    // 87 'W'
    {{ 0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b11011, 0b10001 }},
    // 88 'X'
    {{ 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b01010, 0b10001 }},
    // 89 'Y'
    {{ 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 }},
    // 90 'Z'
    {{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111 }},
    // 91 '['
    {{ 0b01110, 0b01000, 0b01000, 0b01000, 0b01000, 0b01000, 0b01110 }},
    // 92 '\'
    {{ 0b10000, 0b01000, 0b00100, 0b00100, 0b00010, 0b00001, 0b00000 }},
    // 93 ']'
    {{ 0b01110, 0b00010, 0b00010, 0b00010, 0b00010, 0b00010, 0b01110 }},
    // 94 '^'
    {{ 0b00100, 0b01010, 0b10001, 0b00000, 0b00000, 0b00000, 0b00000 }},
    // 95 '_'
    {{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b11111 }},
    // 96 '`'
    {{ 0b01000, 0b00100, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 }},
    // 97-122: lowercase a-z (rendered same as uppercase)
    {{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 }}, // a=A
    {{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110 }}, // b=B
    {{ 0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110 }}, // c=C
    {{ 0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110 }}, // d=D
    {{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 }}, // e=E
    {{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000 }}, // f=F
    {{ 0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01110 }}, // g=G
    {{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 }}, // h=H
    {{ 0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 }}, // i=I
    {{ 0b00111, 0b00010, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100 }}, // j=J
    {{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 }}, // k=K
    {{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 }}, // l=L
    {{ 0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001 }}, // m=M
    {{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001 }}, // n=N
    {{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 }}, // o=O
    {{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 }}, // p=P
    {{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 }}, // q=Q
    {{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 }}, // r=R
    {{ 0b01110, 0b10001, 0b10000, 0b01110, 0b00001, 0b10001, 0b01110 }}, // s=S
    {{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 }}, // t=T
    {{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 }}, // u=U
    {{ 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b01010, 0b00100 }}, // v=V
    {{ 0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b11011, 0b10001 }}, // w=W
    {{ 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b01010, 0b10001 }}, // x=X
    {{ 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 }}, // y=Y
    {{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111 }}, // z=Z
    // 123 '{'
    {{ 0b00110, 0b00100, 0b01000, 0b01000, 0b01000, 0b00100, 0b00110 }},
    // 124 '|'
    {{ 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 }},
    // 125 '}'
    {{ 0b01100, 0b00100, 0b00010, 0b00010, 0b00010, 0b00100, 0b01100 }},
    // 126 '~'
    {{ 0b00000, 0b00000, 0b01000, 0b10101, 0b00010, 0b00000, 0b00000 }},
    // 127 DEL (blank)
    {{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 }},
};

static const int GLYPH_W = 5;
static const int GLYPH_H = 7;
static const int CHAR_SPACING = 1;  // 1 pixel gap between characters (at glyph scale)

// Get glyph for a character, returns space glyph for unsupported chars.
// Lowercase a-z is rendered as uppercase A-Z.
static const BitmapGlyph &get_glyph(char ch)
{
    if (ch >= 'a' && ch <= 'z')
        ch = ch - 'a' + 'A';
    if (ch >= 32 && ch <= 127)
        return g_font[ch - 32];
    return g_font[0]; // space
}

// Measure text width in pixels at given scale
static int measure_text(const char *text, int scale)
{
    int len = (int)strlen(text);
    if (len == 0) return 0;
    return (len * GLYPH_W + (len - 1) * CHAR_SPACING) * scale;
}

// Draw text into an RGBA pixel buffer
static void draw_text_rgba(std::vector<uint8_t> &pixels, uint32_t width, uint32_t height,
                           const char *text, int x0, int y0, int scale,
                           uint8_t r, uint8_t g, uint8_t b)
{
    int len = (int)strlen(text);
    for (int ci = 0; ci < len; ci++) {
        const BitmapGlyph &glyph = get_glyph(text[ci]);
        int cx = x0 + ci * (GLYPH_W + CHAR_SPACING) * scale;

        for (int gy = 0; gy < GLYPH_H; gy++) {
            uint8_t row = glyph.rows[gy];
            for (int gx = 0; gx < GLYPH_W; gx++) {
                if (row & (1 << (GLYPH_W - 1 - gx))) {
                    for (int sy = 0; sy < scale; sy++) {
                        for (int sx = 0; sx < scale; sx++) {
                            int px = cx + gx * scale + sx;
                            int py = y0 + gy * scale + sy;
                            if (px >= 0 && px < (int)width && py >= 0 && py < (int)height) {
                                uint32_t idx = ((uint32_t)py * width + (uint32_t)px) * 4;
                                pixels[idx + 0] = r;
                                pixels[idx + 1] = g;
                                pixels[idx + 2] = b;
                                pixels[idx + 3] = 255;
                            }
                        }
                    }
                }
            }
        }
    }
}

// Draw a filled rectangle into an RGBA pixel buffer
static void fill_rect_rgba(std::vector<uint8_t> &pixels, uint32_t width, uint32_t height,
                           int rx, int ry, int rw, int rh,
                           uint8_t r, uint8_t g, uint8_t b)
{
    for (int y = ry; y < ry + rh; y++) {
        for (int x = rx; x < rx + rw; x++) {
            if (x >= 0 && x < (int)width && y >= 0 && y < (int)height) {
                uint32_t idx = ((uint32_t)y * width + (uint32_t)x) * 4;
                pixels[idx + 0] = r;
                pixels[idx + 1] = g;
                pixels[idx + 2] = b;
                pixels[idx + 3] = 255;
            }
        }
    }
}

/**
 * Generate a classic SMPTE-style test pattern in RGBA with camera info.
 *
 * Layout:
 *   Top 2/3:    7 color bars at 75% with camera name in black rect overlay
 *   Mid strip:  Castellations (blue, black, magenta, black, cyan, black, white)
 *   Bottom 1/4: Dark gray background with "NO SIGNAL" + optional IP
 */
static std::vector<uint8_t> generate_test_pattern_rgba(uint32_t width, uint32_t height,
                                                       const std::string &camera_name,
                                                       const std::string &camera_ip)
{
    std::vector<uint8_t> pixels(width * height * 4);

    // 75% SMPTE color bars (R, G, B)
    const uint8_t bars[7][3] = {
        {191, 191, 191},  // White 75%
        {191, 191,   0},  // Yellow
        {  0, 191, 191},  // Cyan
        {  0, 191,   0},  // Green
        {191,   0, 191},  // Magenta
        {191,   0,   0},  // Red
        {  0,   0, 191},  // Blue
    };

    // Castellation row colors (reverse/complement bars)
    const uint8_t cast[7][3] = {
        {  0,   0, 191},  // Blue
        {  0,   0,   0},  // Black
        {191,   0, 191},  // Magenta
        {  0,   0,   0},  // Black
        {  0, 191, 191},  // Cyan
        {  0,   0,   0},  // Black
        {191, 191, 191},  // White
    };

    uint32_t bar_bottom = height * 2 / 3;
    uint32_t cast_bottom = bar_bottom + height / 12;

    auto set_pixel = [&](uint32_t x, uint32_t y, uint8_t r, uint8_t g, uint8_t b) {
        uint32_t idx = (y * width + x) * 4;
        pixels[idx + 0] = r;
        pixels[idx + 1] = g;
        pixels[idx + 2] = b;
        pixels[idx + 3] = 255;
    };

    for (uint32_t y = 0; y < height; y++) {
        for (uint32_t x = 0; x < width; x++) {
            if (y < bar_bottom) {
                int bar_idx = (int)(x * 7 / width);
                if (bar_idx > 6) bar_idx = 6;
                set_pixel(x, y, bars[bar_idx][0], bars[bar_idx][1], bars[bar_idx][2]);
            } else if (y < cast_bottom) {
                int bar_idx = (int)(x * 7 / width);
                if (bar_idx > 6) bar_idx = 6;
                set_pixel(x, y, cast[bar_idx][0], cast[bar_idx][1], cast[bar_idx][2]);
            } else {
                set_pixel(x, y, 40, 40, 40);
            }
        }
    }

    // --- Camera name overlay in top bar area (truncate to fit) ---
    if (!camera_name.empty()) {
        const int name_scale = 4;
        const int max_name_chars = (int)width / ((GLYPH_W + CHAR_SPACING) * name_scale);
        std::string truncated_name = camera_name.length() > (size_t)max_name_chars
            ? camera_name.substr(0, max_name_chars - 1) + "~"
            : camera_name;
        int name_w = measure_text(truncated_name.c_str(), name_scale);
        int name_h = GLYPH_H * name_scale;
        int pad = 10;
        int rect_w = name_w + pad * 2;
        int rect_h = name_h + pad * 2;
        int rect_x = ((int)width - rect_w) / 2;
        int rect_y = (int)(bar_bottom / 4) - rect_h / 2;  // ~25% from top
        if (rect_y < 0) rect_y = 4;

        fill_rect_rgba(pixels, width, height, rect_x, rect_y, rect_w, rect_h, 0, 0, 0);
        draw_text_rgba(pixels, width, height, truncated_name.c_str(),
                       rect_x + pad, rect_y + pad, name_scale, 255, 255, 255);
    }

    // --- "NO SIGNAL" text centered in bottom section ---
    {
        const char *no_signal = "NO SIGNAL";
        const int ns_scale = 6;
        int ns_w = measure_text(no_signal, ns_scale);
        int ns_h = GLYPH_H * ns_scale;
        int bottom_top = (int)cast_bottom;
        int bottom_h = (int)height - bottom_top;

        // Vertical layout: center "NO SIGNAL" (+ optional IP) as a group
        int total_h = ns_h;
        int ip_scale = 3;
        int ip_h = 0;
        int gap = 8;
        if (!camera_ip.empty()) {
            ip_h = GLYPH_H * ip_scale;
            total_h += gap + ip_h;
        }

        int group_y0 = bottom_top + (bottom_h - total_h) / 2;
        int ns_x = ((int)width - ns_w) / 2;
        draw_text_rgba(pixels, width, height, no_signal, ns_x, group_y0, ns_scale,
                       255, 255, 255);

        // IP address below "NO SIGNAL" in light gray
        if (!camera_ip.empty()) {
            int ip_w = measure_text(camera_ip.c_str(), ip_scale);
            int ip_x = ((int)width - ip_w) / 2;
            int ip_y = group_y0 + ns_h + gap;
            draw_text_rgba(pixels, width, height, camera_ip.c_str(),
                           ip_x, ip_y, ip_scale, 160, 160, 160);
        }
    }

    return pixels;
}

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

    // Load settings (single-threaded construction, but use store() for atomics)
    data->camera_ip = obs_data_get_string(settings, PROP_MANUAL_IP);
    data->camera_port.store((uint16_t)obs_data_get_int(settings, PROP_MANUAL_PORT));
    data->jitter_mode.store((int)obs_data_get_int(settings, PROP_JITTER_MODE));
    data->show_latency.store(obs_data_get_bool(settings, PROP_SHOW_LATENCY));
    data->auth_token = obs_data_get_string(settings, PROP_AUTH_TOKEN);
    data->prefer_zero_copy.store(obs_data_get_bool(settings, PROP_PREFER_ZERO_COPY));
    data->debug_mode.store(obs_data_get_bool(settings, PROP_DEBUG_MODE));
    data->decoder_type.store((int)obs_data_get_int(settings, PROP_DECODER_TYPE));

    blog(LOG_INFO, "[avolocam] Source created (decoder_type=%d, port=%d)",
         data->decoder_type.load(), data->camera_port.load());
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

    // Snapshot current string values under lock for comparison
    std::string old_ip, old_token;
    {
        std::lock_guard<std::mutex> lock(src->config_mutex_);
        old_ip = src->camera_ip;
        old_token = src->auth_token;
    }

    // Check if we need to restart
    bool needs_restart = (new_ip != old_ip ||
                          new_port != src->camera_port.load() ||
                          new_jitter != src->jitter_mode.load() ||
                          new_token != old_token ||
                          new_zero_copy != src->prefer_zero_copy.load() ||
                          new_decoder_type != src->decoder_type.load());

    // Update string fields under lock
    {
        std::lock_guard<std::mutex> lock(src->config_mutex_);
        src->camera_ip = new_ip;
        src->auth_token = new_token;
    }
    // Update atomic fields
    src->camera_port.store(new_port);
    src->jitter_mode.store(new_jitter);
    src->show_latency.store(obs_data_get_bool(settings, PROP_SHOW_LATENCY));
    src->prefer_zero_copy.store(new_zero_copy);
    src->debug_mode.store(new_debug_mode);
    src->decoder_type.store(new_decoder_type);

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
    uint16_t own_port = (src && src->running.load()) ? src->camera_port.load() : 0;

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

    // UDP Port - must match the port configured in Tauri Controller
    obs_property_t *port_prop = obs_properties_add_int(props, PROP_MANUAL_PORT, "UDP Port",
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

    // Cache source name once per tick (avoid repeated obs_source_get_name calls)
    const char *name_ptr = obs_source_get_name(src->source);
    std::string cur_name = name_ptr ? name_ptr : "";

    // Snapshot camera_ip under lock for test pattern comparison
    std::string ip_snapshot;
    {
        std::lock_guard<std::mutex> lock(src->config_mutex_);
        ip_snapshot = src->camera_ip;
    }

    // Invalidate test pattern if camera IP or source name changed
    if (src->test_pattern_created_ &&
        (ip_snapshot != src->test_pattern_ip_ || cur_name != src->test_pattern_name_)) {
        obs_enter_graphics();
        if (src->test_pattern_texture_) {
            gs_texture_destroy(src->test_pattern_texture_);
            src->test_pattern_texture_ = nullptr;
        }
        obs_leave_graphics();
        src->test_pattern_created_ = false;
    }

    // Lazy-init test pattern texture (on graphics thread)
    if (!src->test_pattern_created_) {
        blog(LOG_INFO, "[avolocam] Creating test pattern texture %ux%u (name='%s', ip='%s')",
             SourceData::TEST_PATTERN_WIDTH, SourceData::TEST_PATTERN_HEIGHT,
             cur_name.c_str(), ip_snapshot.c_str());
        auto pixels = generate_test_pattern_rgba(
            SourceData::TEST_PATTERN_WIDTH, SourceData::TEST_PATTERN_HEIGHT,
            cur_name, ip_snapshot);
        const uint8_t *ptr = pixels.data();
        obs_enter_graphics();
        src->test_pattern_texture_ = gs_texture_create(
            SourceData::TEST_PATTERN_WIDTH, SourceData::TEST_PATTERN_HEIGHT,
            GS_RGBA, 1, &ptr, 0);
        obs_leave_graphics();
        src->test_pattern_created_ = true;
        src->test_pattern_ip_ = ip_snapshot;
        src->test_pattern_name_ = cur_name;
        blog(LOG_INFO, "[avolocam] Test pattern texture %s",
             src->test_pattern_texture_ ? "created OK" : "FAILED");
    }

    if (src->use_gpu_render_.load()) {
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

    // GPU path: camera frame available via shared texture
    if (src->use_gpu_render_.load() && src->obs_shared_texture_) {
        effect = obs_get_base_effect(OBS_EFFECT_OPAQUE);
        while (gs_effect_loop(effect, "Draw")) {
            obs_source_draw(src->obs_shared_texture_, 0, 0, 0, 0, false);
        }
        return;
    }

    // CPU path: OBS ASYNC_VIDEO renders if a frame has been submitted
    SourceData::LatestFrame *frame = src->latest_frame_.load(std::memory_order_acquire);
    if (frame && frame->valid)
        return;

    // No camera frame available — draw the "NO SIGNAL" test pattern
    if (src->test_pattern_texture_) {
        effect = obs_get_base_effect(OBS_EFFECT_OPAQUE);
        while (gs_effect_loop(effect, "Draw")) {
            obs_source_draw(src->test_pattern_texture_, 0, 0, 0, 0, false);
        }
    }
}

static uint32_t avolocam_get_width(void *data)
{
    auto *src = static_cast<SourceData *>(data);
    uint32_t w = src->gpu_texture_width_.load(std::memory_order_relaxed);
    if (w > 0)
        return w;
    if (src->decoder) {
        w = src->decoder->get_width();
        if (w > 0) return w;
    }
    return SourceData::TEST_PATTERN_WIDTH;
}

static uint32_t avolocam_get_height(void *data)
{
    auto *src = static_cast<SourceData *>(data);
    uint32_t h = src->gpu_texture_height_.load(std::memory_order_relaxed);
    if (h > 0)
        return h;
    if (src->decoder) {
        h = src->decoder->get_height();
        if (h > 0) return h;
    }
    return SourceData::TEST_PATTERN_HEIGHT;
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
