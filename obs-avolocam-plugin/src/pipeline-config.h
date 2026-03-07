/**
 * pipeline-config.h - Named constants for pipeline tuning parameters
 *
 * Replaces magic numbers scattered across pipeline, receive, and decode code.
 */

#pragma once
#include <cstddef>
#include <cstdint>

namespace avolocam {
    // Jitter buffer configuration
    constexpr uint32_t JITTER_DELAY_ULTRA_LOW_MS = 8;
    constexpr uint32_t JITTER_DELAY_STABLE_MS = 50;

    // UDP receive timeouts
    constexpr int UDP_RECV_TIMEOUT_FLASH_MS = 5;
    constexpr int UDP_RECV_TIMEOUT_STABLE_MS = 100;

    // Tally intervals
    constexpr uint64_t TALLY_POLL_INTERVAL_NS  = 100ULL * 1000 * 1000;
    constexpr uint64_t TALLY_HEARTBEAT_NS      = 2000ULL * 1000 * 1000;

    // Decode queue sizes
    constexpr size_t DECODE_QUEUE_FLASH = 1;
    constexpr size_t DECODE_QUEUE_HW    = 4;
    constexpr size_t DECODE_QUEUE_SW    = 6;

    // Condition variable wait timeouts
    constexpr int DECODE_CV_WAIT_FLASH_MS  = 1;
    constexpr int DECODE_CV_WAIT_STABLE_MS = 50;

    // UDP buffer
    constexpr int UDP_RCVBUF_SIZE = 4 * 1024 * 1024;
    constexpr size_t UDP_PACKET_BUFFER_SIZE = 65536;

    // WebSocket default port
    constexpr uint16_t DEFAULT_WS_PORT = 8888;
}
