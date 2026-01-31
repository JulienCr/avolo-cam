/**
 * jitter-buffer.h - Time-based jitter buffer for RTP packets
 */

#pragma once

#include <cstdint>
#include <vector>
#include <deque>
#include <mutex>

namespace avolocam {

/**
 * Jitter buffer that holds packets briefly to smooth network timing variations.
 *
 * Two modes:
 * - Ultra-low (0-8ms): Minimal buffering for stable networks
 * - Stable (16-50ms): More buffer for WiFi / variable latency
 *
 * Never waits for missing packets - drops late arrivals silently.
 */
class JitterBuffer {
public:
    /**
     * Create a jitter buffer with specified maximum delay
     * @param max_delay_ms Maximum time to hold packets (8 for ultra-low, 50 for stable)
     */
    explicit JitterBuffer(uint32_t max_delay_ms);
    ~JitterBuffer();

    // Non-copyable
    JitterBuffer(const JitterBuffer&) = delete;
    JitterBuffer& operator=(const JitterBuffer&) = delete;

    /**
     * Add a packet to the buffer
     * @param data Packet data
     * @param size Packet size in bytes
     * @param recv_time_ns Receive timestamp (nanoseconds)
     */
    void add_packet(const uint8_t *data, size_t size, uint64_t recv_time_ns);

    /**
     * Get the next packet ready for processing
     * @param out_data Output: packet data
     * @param out_recv_time Output: original receive time
     * @return true if a packet was available
     */
    bool get_next_packet(std::vector<uint8_t> &out_data, uint64_t &out_recv_time);

    /**
     * Get number of packets currently buffered
     */
    size_t size() const;

    /**
     * Get buffer fill level in milliseconds
     */
    double fill_level_ms() const;

    /**
     * Statistics
     */
    uint64_t packets_received() const { return packets_received_; }
    uint64_t packets_dropped() const { return packets_dropped_; }

private:
    struct BufferedPacket {
        std::vector<uint8_t> data;
        uint64_t recv_time_ns;
        uint16_t sequence;  // RTP sequence number for reordering
    };

    mutable std::mutex mutex_;
    std::deque<BufferedPacket> buffer_;
    uint32_t max_delay_ms_;
    uint64_t first_packet_time_ns_ = 0;

    // Statistics
    uint64_t packets_received_ = 0;
    uint64_t packets_dropped_ = 0;

    // Extract RTP sequence number from packet
    static uint16_t get_sequence(const uint8_t *data, size_t size);
};

} // namespace avolocam
