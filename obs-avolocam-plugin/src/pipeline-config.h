/**
 * pipeline-config.h - Named constants for pipeline tuning parameters
 *
 * Replaces magic numbers scattered across pipeline, receive, and decode code.
 */

#pragma once
#include <cstddef>
#include <cstdint>

namespace avolocam {
    // UDP receive timeout (5ms for fast wakeup)
    constexpr int UDP_RECV_TIMEOUT_MS = 5;

    // Tally intervals
    constexpr uint64_t TALLY_POLL_INTERVAL_NS  = 100ULL * 1000 * 1000;
    constexpr uint64_t TALLY_HEARTBEAT_NS      = 2000ULL * 1000 * 1000;

    // UDP buffer
    constexpr int UDP_RCVBUF_SIZE = 4 * 1024 * 1024;
    constexpr size_t UDP_PACKET_BUFFER_SIZE = 65536;

    // WebSocket default port
    constexpr uint16_t DEFAULT_WS_PORT = 8888;
}
