/**
 * avolocam-source-data.h - SourceData struct definition
 *
 * Internal header exposing the SourceData struct so it can be
 * shared across multiple .cpp files that implement different
 * aspects of the OBS source (pipeline, decode, tally, etc.).
 */

#pragma once

#include <atomic>
#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include <obs-module.h>
#include <graphics/graphics.h>
#include <util/platform.h>

#include "access-unit-assembler.h"
#include "decoder/platform-decoder.h"
#include "gpu-converter.h"
#include "logging.h"
#include "mdns-discovery.h"
#include "source-error.h"
#include "rtp-depacketizer.h"
#include "sync-state-machine.h"
#include "texture-output.h"
#include "timestamp-mapper.h"
#include "udp-receiver.h"
#include "websocket-client.h"

#ifdef _WIN32
#include <util/windows/ComPtr.hpp>
#endif

// Property keys
#define PROP_CAMERA_SELECT    "camera_select"
#define PROP_MANUAL_IP        "manual_ip"
#define PROP_MANUAL_PORT      "manual_port"
#define PROP_SHOW_LATENCY     "show_latency"
#define PROP_AUTH_TOKEN       "auth_token"
#define PROP_PREFER_ZERO_COPY "prefer_zero_copy"
#define PROP_DEBUG_MODE       "debug_mode"
#define PROP_PORT_WARNING     "port_warning"

namespace avolocam {

// Global mDNS discovery instance (shared across all sources)
extern std::unique_ptr<MdnsDiscovery> g_discovery;
extern std::mutex g_discovery_mutex;

// Global port registry: prevents multiple sources from binding the same UDP port
extern std::set<uint16_t> g_bound_ports;
extern std::mutex g_ports_mutex;

/**
 * Source instance data
 */
struct SourceData {
    obs_source_t *source = nullptr;

    // --- Config: User-facing settings (thread-safe) ---
    struct Config {
        std::string camera_ip;               // protected by mutex
        std::atomic<uint16_t> camera_port{5000};
        std::atomic<bool> show_latency{false};
        std::string auth_token;              // protected by mutex
        std::atomic<bool> prefer_zero_copy{true};
        std::atomic<bool> debug_mode{false};
        std::mutex mutex;                    // protects camera_ip, auth_token
    };
    Config config;

    // --- Pipeline: Codec/network components ---
    struct Pipeline {
        std::unique_ptr<UdpReceiver> receiver;
        std::unique_ptr<RtpDepacketizer> depacketizer;
        std::unique_ptr<AccessUnitAssembler> assembler;
        std::unique_ptr<SyncStateMachine> sync_state;
        std::unique_ptr<PlatformDecoder> decoder;
        std::unique_ptr<TimestampMapper> timestamp_mapper;
        std::unique_ptr<TextureOutput> texture_output;
        std::unique_ptr<WebSocketClient> ws_client;
    };
    Pipeline pipeline;

    // --- DecodeQueue: Async decode pipeline + double buffering ---
    struct DecodeQueue {
        std::deque<AccessUnit> queue;
        std::mutex mutex;
        std::condition_variable cv;

        struct Frame {
            std::vector<uint8_t> data;
            uint32_t width = 0;
            uint32_t height = 0;
            uint32_t y_stride = 0;
            uint32_t uv_stride = 0;
            uint64_t pts = 0;
            bool valid = false;
        };
        std::atomic<Frame*> latest{nullptr};
        Frame buffer_a;
        Frame buffer_b;
        std::atomic<int> current_buffer{0};  // 0 = A, 1 = B
    };
    DecodeQueue decode_queue;

    // --- GpuState: GPU zero-copy + textures ---
    struct GpuState {
        std::atomic<bool> use_gpu_decode{false};
        std::atomic<bool> use_gpu_render{false};
#ifdef _WIN32
        std::unique_ptr<GPUConverter> converter;
#endif
        bool converter_initialized = false;

        // GPU frame dimensions (written by decode thread, read by render thread)
        std::atomic<uint32_t> texture_width{0};
        std::atomic<uint32_t> texture_height{0};

        // Zero-copy shared handle (CUSTOM_DRAW)
        std::atomic<void*> latest_shared_handle{nullptr};
        void *cached_shared_handle = nullptr;
        gs_texture_t *obs_shared_texture = nullptr;

        // CPU fallback
        gs_texture_t *cpu_fallback_texture = nullptr;
    };
    GpuState gpu;

    // --- TestPattern: "No Signal" pattern ---
    struct TestPattern {
        gs_texture_t *texture = nullptr;
        bool created = false;
        std::string baked_ip;
        std::string baked_name;
        static constexpr uint32_t WIDTH = 1920;
        static constexpr uint32_t HEIGHT = 1080;
    };
    TestPattern test_pattern;

    // Threading
    std::thread receive_thread;
    std::thread decode_thread;
    std::thread ws_connect_thread_;
    std::atomic<bool> running{false};
    std::atomic<bool> visible{true};

    // Telemetry
    std::atomic<uint64_t> frames_received{0};
    std::atomic<uint64_t> frames_decoded{0};
    std::atomic<uint64_t> frames_dropped{0};
    std::atomic<uint64_t> decode_queue_drops{0};
    std::atomic<double> current_latency_ms{0.0};

    // Per-instance debug counters
    int packet_count{0};
    int total_nals{0};
    int au_count{0};
    int output_count{0};

    // Tally state tracking
    std::atomic<bool> tally_program{false};
    std::atomic<bool> tally_preview{false};

    // Tally timer state (used by tick_tally in receive loop)
    struct TallyTimers {
        uint64_t last_poll_ns = 0;
        uint64_t last_heartbeat_ns = 0;
        bool started = false;
    };
    TallyTimers tally_timers;

    // Camera telemetry from WebSocket
    CameraTelemetry camera_telemetry;
    std::mutex telemetry_mutex;

    // Bind result signaling: 0=pending, 1=success, -1=failure
    std::atomic<int> bind_result_{0};

    // Mutex for decoder output
    std::mutex frame_mutex;

    // --- Construction / destruction ---
    SourceData() = default;
    ~SourceData();  // defined in avolocam-source.cpp (uses OBS graphics)

    // --- Lifecycle methods ---
    Result<void> init_pipeline(const std::string& ip, bool zero_copy);
    void init_websocket(const std::string& ip, std::string token);
    void start_threads(uint16_t port);
    Result<void> start();
    void shutdown_websocket();
    void cleanup_gpu_state();
    void reset_pipeline();
    void stop();

    // --- Receive thread ---
    void receive_loop();
    void process_packet_direct(const uint8_t *data, int size);
    void process_nal_units(std::vector<NalUnit>& nal_units);
    void push_to_decode_queue(AccessUnit&& au);

    // --- Decode thread ---
    void decode_loop();
    bool init_decoder(const AccessUnit& au);
    void decode_frame_async(const AccessUnit& au);
#ifdef _WIN32
    bool decode_gpu_frame(DecodedFrame& frame);
#endif
    void store_cpu_frame(const DecodedFrame& frame);
    void output_latest_frame();

    // --- Utility ---
    double get_display_latency() const;
    void tick_tally(uint64_t now_ns);
    void send_tally_state();
    void send_tally_heartbeat();
    void extract_parameter_sets(const std::vector<uint8_t>& data,
                                 std::vector<uint8_t>& sps,
                                 std::vector<uint8_t>& pps);
};

} // namespace avolocam
