/**
 * websocket-client.cpp - WebSocket client implementation
 *
 * Minimal WebSocket client using raw sockets and RFC 6455 framing.
 * Platform-independent implementation for macOS and Windows.
 */

#include "websocket-client.h"
#include <obs-module.h>

#include <cstring>
#include <cstdlib>
#include <sstream>
#include <algorithm>
#include <chrono>
#include <random>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
#define SOCKET_ERROR_CODE WSAGetLastError()
#define INVALID_SOCK INVALID_SOCKET
#define CLOSE_SOCKET closesocket
typedef int socklen_t;
#else
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#define SOCKET_ERROR_CODE errno
#define INVALID_SOCK -1
#define CLOSE_SOCKET close
#endif

namespace avolocam {

// WebSocket opcodes
static constexpr uint8_t WS_OPCODE_CONTINUATION = 0x00;
static constexpr uint8_t WS_OPCODE_TEXT = 0x01;
static constexpr uint8_t WS_OPCODE_BINARY = 0x02;
static constexpr uint8_t WS_OPCODE_CLOSE = 0x08;
static constexpr uint8_t WS_OPCODE_PING = 0x09;
static constexpr uint8_t WS_OPCODE_PONG = 0x0A;

// Simple JSON parsing helpers
static bool json_get_string(const std::string &json, const std::string &key, std::string &value)
{
    std::string search = "\"" + key + "\"";
    size_t pos = json.find(search);
    if (pos == std::string::npos) return false;

    pos = json.find(':', pos);
    if (pos == std::string::npos) return false;

    pos = json.find('"', pos);
    if (pos == std::string::npos) return false;
    pos++;

    size_t end = json.find('"', pos);
    if (end == std::string::npos) return false;

    value = json.substr(pos, end - pos);
    return true;
}

static bool json_get_number(const std::string &json, const std::string &key, double &value)
{
    std::string search = "\"" + key + "\"";
    size_t pos = json.find(search);
    if (pos == std::string::npos) return false;

    pos = json.find(':', pos);
    if (pos == std::string::npos) return false;
    pos++;

    // Skip whitespace
    while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\t')) pos++;

    // Parse number
    char *end = nullptr;
    value = strtod(json.c_str() + pos, &end);
    return end != json.c_str() + pos;
}

static bool json_get_int64(const std::string &json, const std::string &key, int64_t &value)
{
    double d;
    if (!json_get_number(json, key, d)) return false;
    value = (int64_t)d;
    return true;
}

static bool json_get_uint32(const std::string &json, const std::string &key, uint32_t &value)
{
    double d;
    if (!json_get_number(json, key, d)) return false;
    value = (uint32_t)d;
    return true;
}

static bool json_get_uint64(const std::string &json, const std::string &key, uint64_t &value)
{
    double d;
    if (!json_get_number(json, key, d)) return false;
    value = (uint64_t)d;
    return true;
}

WebSocketClient::WebSocketClient()
{
#ifdef _WIN32
    // Initialize Winsock
    WSADATA wsa_data;
    WSAStartup(MAKEWORD(2, 2), &wsa_data);
#endif
}

WebSocketClient::~WebSocketClient()
{
    disconnect();

#ifdef _WIN32
    WSACleanup();
#endif
}

bool WebSocketClient::connect(const std::string &url, const std::string &auth_token)
{
    if (state_ != WSState::DISCONNECTED) {
        blog(LOG_WARNING, "[avolocam-ws] Already connected or connecting");
        return false;
    }

    url_ = url;
    auth_token_ = auth_token;

    return do_connect();
}

bool WebSocketClient::do_connect()
{
    set_state(WSState::CONNECTING);

    // Parse URL
    std::string host;
    uint16_t port;
    std::string path;
    if (!parse_url(url_, host, port, path)) {
        blog(LOG_ERROR, "[avolocam-ws] Invalid URL: %s", url_.c_str());
        set_state(WSState::ERRORED);
        return false;
    }

    blog(LOG_INFO, "[avolocam-ws] Connecting to %s:%d%s", host.c_str(), port, path.c_str());

    // Resolve hostname
    struct addrinfo hints = {};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;

    struct addrinfo *result = nullptr;
    char port_str[16];
    snprintf(port_str, sizeof(port_str), "%d", port);

    int res = getaddrinfo(host.c_str(), port_str, &hints, &result);
    if (res != 0 || !result) {
        blog(LOG_ERROR, "[avolocam-ws] Failed to resolve host: %s", host.c_str());
        set_state(WSState::ERRORED);
        return false;
    }

    // Create socket
#ifdef _WIN32
    socket_ = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (socket_ == INVALID_SOCKET) {
#else
    socket_ = socket(AF_INET, SOCK_STREAM, 0);
    if (socket_ < 0) {
#endif
        blog(LOG_ERROR, "[avolocam-ws] Failed to create socket");
        freeaddrinfo(result);
        set_state(WSState::ERRORED);
        return false;
    }

    // Connect
    if (::connect(socket_, result->ai_addr, (socklen_t)result->ai_addrlen) != 0) {
        blog(LOG_ERROR, "[avolocam-ws] Failed to connect: error %d", SOCKET_ERROR_CODE);
        CLOSE_SOCKET(socket_);
#ifdef _WIN32
        socket_ = INVALID_SOCKET;
#else
        socket_ = -1;
#endif
        freeaddrinfo(result);
        set_state(WSState::ERRORED);
        return false;
    }

    freeaddrinfo(result);

    // Set socket timeout
    struct timeval tv;
    tv.tv_sec = 5;
    tv.tv_usec = 0;
    setsockopt(socket_, SOL_SOCKET, SO_RCVTIMEO, (const char *)&tv, sizeof(tv));
    setsockopt(socket_, SOL_SOCKET, SO_SNDTIMEO, (const char *)&tv, sizeof(tv));

    // Perform WebSocket handshake
    if (!perform_handshake()) {
        blog(LOG_ERROR, "[avolocam-ws] WebSocket handshake failed");
        do_disconnect();
        return false;
    }

    blog(LOG_INFO, "[avolocam-ws] Connected successfully");
    set_state(WSState::CONNECTED);

    // Start receive thread
    running_ = true;
    recv_thread_ = std::thread(&WebSocketClient::receive_loop, this);

    return true;
}

void WebSocketClient::disconnect()
{
    running_ = false;

    do_disconnect();

    if (recv_thread_.joinable()) {
        recv_thread_.join();
    }
}

void WebSocketClient::do_disconnect()
{
#ifdef _WIN32
    if (socket_ != INVALID_SOCKET) {
        // Send close frame
        send_frame(WS_OPCODE_CLOSE, nullptr, 0);
        shutdown(socket_, SD_BOTH);
        CLOSE_SOCKET(socket_);
        socket_ = INVALID_SOCKET;
    }
#else
    if (socket_ >= 0) {
        send_frame(WS_OPCODE_CLOSE, nullptr, 0);
        shutdown(socket_, SHUT_RDWR);
        CLOSE_SOCKET(socket_);
        socket_ = -1;
    }
#endif

    set_state(WSState::DISCONNECTED);
}

bool WebSocketClient::is_connected() const
{
    return state_.load() == WSState::CONNECTED;
}

void WebSocketClient::set_frame_info_callback(FrameInfoCallback callback)
{
    std::lock_guard<std::mutex> lock(callback_mutex_);
    frame_info_callback_ = std::move(callback);
}

void WebSocketClient::set_telemetry_callback(TelemetryCallback callback)
{
    std::lock_guard<std::mutex> lock(callback_mutex_);
    telemetry_callback_ = std::move(callback);
}

void WebSocketClient::set_connection_callback(ConnectionCallback callback)
{
    std::lock_guard<std::mutex> lock(callback_mutex_);
    connection_callback_ = std::move(callback);
}

void WebSocketClient::request_idr()
{
    if (!is_connected()) return;

    std::string msg = R"({"op":"request_idr"})";
    send_text(msg);
    blog(LOG_INFO, "[avolocam-ws] Requested IDR frame");
}

void WebSocketClient::send_command(const std::string &command)
{
    if (!is_connected()) return;
    send_text(command);
}

void WebSocketClient::set_auto_reconnect(bool enable, int max_attempts)
{
    auto_reconnect_ = enable;
    max_reconnect_attempts_ = max_attempts;
}

void WebSocketClient::set_reconnect_delays(int initial_delay_ms, int max_delay_ms)
{
    initial_reconnect_delay_ms_ = initial_delay_ms;
    max_reconnect_delay_ms_ = max_delay_ms;
}

bool WebSocketClient::perform_handshake()
{
    std::string host;
    uint16_t port;
    std::string path;
    if (!parse_url(url_, host, port, path)) {
        return false;
    }

    // Generate WebSocket key
    std::string ws_key = generate_websocket_key();

    // Build HTTP upgrade request
    std::stringstream request;
    request << "GET " << path << " HTTP/1.1\r\n";
    request << "Host: " << host << ":" << port << "\r\n";
    request << "Upgrade: websocket\r\n";
    request << "Connection: Upgrade\r\n";
    request << "Sec-WebSocket-Key: " << ws_key << "\r\n";
    request << "Sec-WebSocket-Version: 13\r\n";
    if (!auth_token_.empty()) {
        request << "Authorization: Bearer " << auth_token_ << "\r\n";
    }
    request << "\r\n";

    std::string req_str = request.str();

    // Send request
    if (send(socket_, req_str.c_str(), (int)req_str.size(), 0) <= 0) {
        return false;
    }

    // Read response
    char response[2048];
    int received = recv(socket_, response, sizeof(response) - 1, 0);
    if (received <= 0) {
        return false;
    }
    response[received] = '\0';

    // Check for 101 Switching Protocols
    if (strstr(response, "101") == nullptr ||
        strstr(response, "Upgrade") == nullptr) {
        blog(LOG_ERROR, "[avolocam-ws] Invalid handshake response: %s", response);
        return false;
    }

    return true;
}

void WebSocketClient::receive_loop()
{
    blog(LOG_INFO, "[avolocam-ws] Receive thread started");

    std::vector<uint8_t> payload;
    uint8_t opcode;

    while (running_.load()) {
        if (!is_connected()) {
            if (auto_reconnect_ && running_.load()) {
                attempt_reconnect();
            }
            continue;
        }

        if (!read_frame(payload, opcode)) {
            if (running_.load()) {
                blog(LOG_WARNING, "[avolocam-ws] Read error, disconnecting");
                set_state(WSState::DISCONNECTED);
            }
            continue;
        }

        messages_received_++;

        switch (opcode) {
        case WS_OPCODE_TEXT: {
            std::string message(payload.begin(), payload.end());
            handle_message(message);
            break;
        }
        case WS_OPCODE_BINARY:
            // Binary messages not used currently
            break;
        case WS_OPCODE_PING:
            // Send pong
            send_frame(WS_OPCODE_PONG, payload.data(), payload.size());
            break;
        case WS_OPCODE_PONG:
            // Ignore pong
            break;
        case WS_OPCODE_CLOSE:
            blog(LOG_INFO, "[avolocam-ws] Server sent close frame");
            set_state(WSState::DISCONNECTED);
            break;
        default:
            break;
        }
    }

    blog(LOG_INFO, "[avolocam-ws] Receive thread exiting");
}

bool WebSocketClient::read_frame(std::vector<uint8_t> &payload, uint8_t &opcode)
{
    payload.clear();

    // Read first 2 bytes (FIN + opcode + mask + payload length)
    uint8_t header[2];
    int received = recv(socket_, (char *)header, 2, 0);
    if (received != 2) {
        return false;
    }

    bool fin = (header[0] & 0x80) != 0;
    opcode = header[0] & 0x0F;
    bool masked = (header[1] & 0x80) != 0;
    uint64_t payload_len = header[1] & 0x7F;

    // Extended payload length
    if (payload_len == 126) {
        uint8_t ext[2];
        if (recv(socket_, (char *)ext, 2, 0) != 2) return false;
        payload_len = ((uint64_t)ext[0] << 8) | ext[1];
    } else if (payload_len == 127) {
        uint8_t ext[8];
        if (recv(socket_, (char *)ext, 8, 0) != 8) return false;
        payload_len = 0;
        for (int i = 0; i < 8; i++) {
            payload_len = (payload_len << 8) | ext[i];
        }
    }

    // Read masking key if present
    uint8_t mask_key[4] = {0};
    if (masked) {
        if (recv(socket_, (char *)mask_key, 4, 0) != 4) return false;
    }

    // Read payload
    if (payload_len > 0) {
        if (payload_len > 10 * 1024 * 1024) {  // 10MB max
            return false;
        }
        payload.resize((size_t)payload_len);
        size_t total = 0;
        while (total < payload_len) {
            received = recv(socket_, (char *)payload.data() + total,
                           (int)(payload_len - total), 0);
            if (received <= 0) return false;
            total += received;
        }

        // Unmask if needed
        if (masked) {
            for (size_t i = 0; i < payload.size(); i++) {
                payload[i] ^= mask_key[i % 4];
            }
        }
    }

    (void)fin;  // We don't handle fragmentation currently
    return true;
}

bool WebSocketClient::send_frame(uint8_t opcode, const uint8_t *data, size_t len)
{
    std::lock_guard<std::mutex> lock(send_mutex_);

    std::vector<uint8_t> frame;

    // FIN + opcode
    frame.push_back(0x80 | opcode);

    // Payload length + mask bit (clients must mask)
    if (len < 126) {
        frame.push_back(0x80 | (uint8_t)len);
    } else if (len < 65536) {
        frame.push_back(0x80 | 126);
        frame.push_back((len >> 8) & 0xFF);
        frame.push_back(len & 0xFF);
    } else {
        frame.push_back(0x80 | 127);
        for (int i = 7; i >= 0; i--) {
            frame.push_back((len >> (i * 8)) & 0xFF);
        }
    }

    // Generate random mask key
    uint8_t mask_key[4];
    std::random_device rd;
    for (int i = 0; i < 4; i++) {
        mask_key[i] = (uint8_t)(rd() & 0xFF);
    }
    frame.insert(frame.end(), mask_key, mask_key + 4);

    // Masked payload
    if (data && len > 0) {
        for (size_t i = 0; i < len; i++) {
            frame.push_back(data[i] ^ mask_key[i % 4]);
        }
    }

    // Send
    int sent = send(socket_, (const char *)frame.data(), (int)frame.size(), 0);
    if (sent != (int)frame.size()) {
        return false;
    }

    messages_sent_++;
    return true;
}

bool WebSocketClient::send_text(const std::string &message)
{
    return send_frame(WS_OPCODE_TEXT, (const uint8_t *)message.data(), message.size());
}

void WebSocketClient::handle_message(const std::string &message)
{
    // Determine message type
    std::string msg_type;
    if (!json_get_string(message, "type", msg_type)) {
        // Try to detect by content
        if (message.find("frame_idx") != std::string::npos) {
            msg_type = "frame_info";
        } else if (message.find("fps") != std::string::npos &&
                   message.find("battery") != std::string::npos) {
            msg_type = "telemetry";
        }
    }

    if (msg_type == "frame_info") {
        FrameTimingInfo info;
        if (parse_frame_info(message, info)) {
            std::lock_guard<std::mutex> lock(callback_mutex_);
            if (frame_info_callback_) {
                frame_info_callback_(info);
            }
        }
    } else if (msg_type == "telemetry") {
        CameraTelemetry telemetry;
        if (parse_telemetry(message, telemetry)) {
            std::lock_guard<std::mutex> lock(callback_mutex_);
            if (telemetry_callback_) {
                telemetry_callback_(telemetry);
            }
        }
    }
}

bool WebSocketClient::parse_frame_info(const std::string &json, FrameTimingInfo &info)
{
    if (!json_get_int64(json, "frame_idx", info.frame_idx)) return false;
    if (!json_get_uint32(json, "rtp_ts", info.rtp_ts)) return false;
    json_get_int64(json, "capture_ts_ns", info.capture_ts_ns);
    json_get_int64(json, "encode_ts_ns", info.encode_ts_ns);
    return true;
}

bool WebSocketClient::parse_telemetry(const std::string &json, CameraTelemetry &telemetry)
{
    json_get_number(json, "fps", telemetry.fps);
    json_get_number(json, "bitrate", telemetry.bitrate);
    json_get_number(json, "battery", telemetry.battery);
    json_get_number(json, "temp_c", telemetry.temp_c);

    double rssi;
    if (json_get_number(json, "wifi_rssi", rssi)) {
        telemetry.wifi_rssi = (int)rssi;
    }

    json_get_string(json, "ndi_state", telemetry.ndi_state);
    json_get_number(json, "queue_ms", telemetry.queue_ms);
    json_get_uint64(json, "dropped_frames", telemetry.dropped_frames);
    json_get_string(json, "charging_state", telemetry.charging_state);

    // Parse Flash UDP port for auto-discovery
    double port;
    if (json_get_number(json, "flash_udp_port", port)) {
        telemetry.flash_udp_port = (uint16_t)port;
    } else {
        telemetry.flash_udp_port = 0;
    }

    return true;
}

void WebSocketClient::set_state(WSState new_state)
{
    WSState old_state = state_.exchange(new_state);
    if (old_state != new_state) {
        blog(LOG_INFO, "[avolocam-ws] State: %s -> %s",
             ws_state_name(old_state), ws_state_name(new_state));

        std::lock_guard<std::mutex> lock(callback_mutex_);
        if (connection_callback_) {
            connection_callback_(new_state);
        }
    }
}

void WebSocketClient::attempt_reconnect()
{
    if (!auto_reconnect_ || reconnect_attempts_ >= (uint64_t)max_reconnect_attempts_) {
        set_state(WSState::ERRORED);
        return;
    }

    set_state(WSState::RECONNECTING);
    reconnect_attempts_++;

    // Exponential backoff
    int delay = initial_reconnect_delay_ms_ * (1 << (reconnect_attempts_ - 1));
    if (delay > max_reconnect_delay_ms_) {
        delay = max_reconnect_delay_ms_;
    }

    blog(LOG_INFO, "[avolocam-ws] Reconnect attempt %llu in %d ms",
         (unsigned long long)reconnect_attempts_.load(), delay);

    std::this_thread::sleep_for(std::chrono::milliseconds(delay));

    if (running_.load() && do_connect()) {
        reconnect_attempts_ = 0;
    }
}

std::string WebSocketClient::generate_websocket_key()
{
    // Generate 16 random bytes and base64 encode
    uint8_t random_bytes[16];
    std::random_device rd;
    for (int i = 0; i < 16; i++) {
        random_bytes[i] = (uint8_t)(rd() & 0xFF);
    }
    return base64_encode(random_bytes, 16);
}

std::string WebSocketClient::base64_encode(const uint8_t *data, size_t len)
{
    static const char alphabet[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    std::string result;
    result.reserve((len + 2) / 3 * 4);

    for (size_t i = 0; i < len; i += 3) {
        uint32_t n = (uint32_t)data[i] << 16;
        if (i + 1 < len) n |= (uint32_t)data[i + 1] << 8;
        if (i + 2 < len) n |= (uint32_t)data[i + 2];

        result.push_back(alphabet[(n >> 18) & 0x3F]);
        result.push_back(alphabet[(n >> 12) & 0x3F]);
        result.push_back((i + 1 < len) ? alphabet[(n >> 6) & 0x3F] : '=');
        result.push_back((i + 2 < len) ? alphabet[n & 0x3F] : '=');
    }

    return result;
}

bool WebSocketClient::parse_url(const std::string &url, std::string &host,
                                 uint16_t &port, std::string &path)
{
    // Expected format: ws://host:port/path or ws://host/path
    std::string str = url;

    // Remove ws:// or wss:// prefix
    if (str.substr(0, 5) == "ws://") {
        str = str.substr(5);
    } else if (str.substr(0, 6) == "wss://") {
        str = str.substr(6);  // Note: TLS not implemented
    } else {
        return false;
    }

    // Find path
    size_t path_pos = str.find('/');
    if (path_pos != std::string::npos) {
        path = str.substr(path_pos);
        str = str.substr(0, path_pos);
    } else {
        path = "/";
    }

    // Find port
    size_t port_pos = str.find(':');
    if (port_pos != std::string::npos) {
        host = str.substr(0, port_pos);
        port = (uint16_t)atoi(str.substr(port_pos + 1).c_str());
    } else {
        host = str;
        port = 80;  // Default HTTP port
    }

    return !host.empty();
}

const char *ws_state_name(WSState state)
{
    switch (state) {
    case WSState::DISCONNECTED: return "DISCONNECTED";
    case WSState::CONNECTING: return "CONNECTING";
    case WSState::CONNECTED: return "CONNECTED";
    case WSState::RECONNECTING: return "RECONNECTING";
    case WSState::ERRORED: return "ERROR";
    default: return "UNKNOWN";
    }
}

} // namespace avolocam
