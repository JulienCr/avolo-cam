/**
 * websocket-client.h - WebSocket client for iOS camera communication
 *
 * Connects to the AvoCam iOS app WebSocket endpoint for:
 * - Receiving frame timing info (for latency calculation)
 * - Sending IDR requests (for sync recovery)
 * - Receiving telemetry updates
 */

#pragma once

#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "timestamp-mapper.h"

namespace avolocam {

/**
 * Telemetry data received from iOS device
 */
struct CameraTelemetry {
    double fps;              // Current frame rate
    double bitrate;          // Current bitrate in bps
    double battery;          // Battery level (0.0-1.0)
    double temp_c;           // Device temperature in Celsius
    int wifi_rssi;           // WiFi signal strength in dBm
    std::string ndi_state;   // "streaming" or "idle"
    double queue_ms;         // Encoder queue depth in milliseconds
    uint64_t dropped_frames; // Total dropped frame count
    std::string charging_state; // "charging", "full", or "unplugged"
    uint16_t flash_udp_port; // Active Flash UDP port (0 = not streaming Flash)
};

/**
 * WebSocket connection state
 */
enum class WSState {
    DISCONNECTED,
    CONNECTING,
    CONNECTED,
    RECONNECTING,
    ERRORED  // Note: 'ERROR' conflicts with Windows macro
};

/**
 * Callbacks for WebSocket events
 */
using FrameInfoCallback = std::function<void(const FrameTimingInfo &info)>;
using TelemetryCallback = std::function<void(const CameraTelemetry &telemetry)>;
using ConnectionCallback = std::function<void(WSState state)>;

/**
 * WebSocket client for AvoCam iOS communication
 *
 * Thread-safe implementation with automatic reconnection.
 */
class WebSocketClient {
public:
    WebSocketClient();
    ~WebSocketClient();

    // Non-copyable
    WebSocketClient(const WebSocketClient&) = delete;
    WebSocketClient& operator=(const WebSocketClient&) = delete;

    /**
     * Connect to WebSocket endpoint
     * @param url WebSocket URL (e.g., "ws://192.168.1.100:8888/ws")
     * @param auth_token Bearer authentication token
     * @return true if connection initiated (not necessarily connected yet)
     */
    bool connect(const std::string &url, const std::string &auth_token = "");

    /**
     * Disconnect from WebSocket
     */
    void disconnect();

    /**
     * Check if connected
     */
    bool is_connected() const;

    /**
     * Get current connection state
     */
    WSState state() const { return state_.load(); }

    /**
     * Set callback for frame timing info
     */
    void set_frame_info_callback(FrameInfoCallback callback);

    /**
     * Set callback for telemetry updates
     */
    void set_telemetry_callback(TelemetryCallback callback);

    /**
     * Set callback for connection state changes
     */
    void set_connection_callback(ConnectionCallback callback);

    /**
     * Request IDR frame from camera
     *
     * Called by SyncStateMachine when resync is needed.
     */
    void request_idr();

    /**
     * Send camera control command
     * @param command JSON command string
     */
    void send_command(const std::string &command);

    /**
     * Enable/disable auto-reconnect
     */
    void set_auto_reconnect(bool enable, int max_attempts = 5);

    /**
     * Set reconnect delay parameters
     * @param initial_delay_ms Initial delay before first reconnect
     * @param max_delay_ms Maximum delay (exponential backoff cap)
     */
    void set_reconnect_delays(int initial_delay_ms, int max_delay_ms);

    /**
     * Get statistics
     */
    uint64_t messages_received() const { return messages_received_; }
    uint64_t messages_sent() const { return messages_sent_; }
    uint64_t reconnect_attempts() const { return reconnect_attempts_; }

private:
    std::string url_;
    std::string auth_token_;

    std::atomic<WSState> state_{WSState::DISCONNECTED};
    std::atomic<bool> running_{false};
    std::atomic<bool> auto_reconnect_{true};
    int max_reconnect_attempts_ = 5;
    int initial_reconnect_delay_ms_ = 500;
    int max_reconnect_delay_ms_ = 10000;

    // Socket handle (platform-specific)
#ifdef _WIN32
    uintptr_t socket_ = (uintptr_t)~0;  // INVALID_SOCKET
#else
    int socket_ = -1;
#endif

    // Threading
    std::thread recv_thread_;
    std::mutex send_mutex_;

    // Callbacks
    FrameInfoCallback frame_info_callback_;
    TelemetryCallback telemetry_callback_;
    ConnectionCallback connection_callback_;
    std::mutex callback_mutex_;

    // Statistics
    std::atomic<uint64_t> messages_received_{0};
    std::atomic<uint64_t> messages_sent_{0};
    std::atomic<uint64_t> reconnect_attempts_{0};

    // Internal methods
    bool do_connect();
    bool do_connect_socket();  // Connect socket without starting thread
    void do_disconnect();
    void receive_loop();
    bool send_raw(const std::vector<uint8_t> &data);
    bool send_text(const std::string &message);

    // WebSocket frame handling
    bool perform_handshake();
    bool read_frame(std::vector<uint8_t> &payload, uint8_t &opcode);
    bool send_frame(uint8_t opcode, const uint8_t *data, size_t len);

    // Message parsing
    void handle_message(const std::string &message);
    bool parse_frame_info(const std::string &json, FrameTimingInfo &info);
    bool parse_telemetry(const std::string &json, CameraTelemetry &telemetry);

    // State management
    void set_state(WSState new_state);
    void attempt_reconnect();

    // Utility
    static std::string generate_websocket_key();
    static std::string base64_encode(const uint8_t *data, size_t len);
    static bool parse_url(const std::string &url, std::string &host,
                          uint16_t &port, std::string &path);
};

/**
 * Get human-readable name for WebSocket state
 */
const char *ws_state_name(WSState state);

} // namespace avolocam
