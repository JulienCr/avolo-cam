/**
 * jitter-buffer.cpp - Time-based jitter buffer implementation
 */

#include "jitter-buffer.h"
#include <algorithm>

namespace avolocam {

JitterBuffer::JitterBuffer(uint32_t max_delay_ms)
    : max_delay_ms_(max_delay_ms)
{
}

JitterBuffer::~JitterBuffer() = default;

uint16_t JitterBuffer::get_sequence(const uint8_t *data, size_t size) {
    // RTP sequence number is at bytes 2-3 (big endian)
    if (size < 4) return 0;
    return (static_cast<uint16_t>(data[2]) << 8) | data[3];
}

void JitterBuffer::add_packet(const uint8_t *data, size_t size, uint64_t recv_time_ns) {
    if (size < 12) return;  // Minimum RTP header size

    std::lock_guard<std::mutex> lock(mutex_);

    packets_received_++;

    // Initialize timing on first packet
    if (first_packet_time_ns_ == 0) {
        first_packet_time_ns_ = recv_time_ns;
    }

    // Create buffered packet
    BufferedPacket pkt;
    pkt.data.assign(data, data + size);
    pkt.recv_time_ns = recv_time_ns;
    pkt.sequence = get_sequence(data, size);

    // Insert in sequence order (handle wrap-around)
    // Simple insertion sort since most packets arrive in order
    auto it = buffer_.end();
    while (it != buffer_.begin()) {
        auto prev = std::prev(it);
        // Handle 16-bit sequence wrap-around
        int16_t diff = static_cast<int16_t>(pkt.sequence - prev->sequence);
        if (diff > 0) {
            // pkt comes after prev
            break;
        }
        it = prev;
    }
    buffer_.insert(it, std::move(pkt));

    // Drop packets that arrived too late (older than max_delay_ms from head)
    uint64_t max_delay_ns = static_cast<uint64_t>(max_delay_ms_) * 1000000;
    while (buffer_.size() > 1) {
        auto &oldest = buffer_.front();
        auto &newest = buffer_.back();

        if (newest.recv_time_ns - oldest.recv_time_ns > max_delay_ns * 2) {
            // Oldest packet is too stale, drop it
            buffer_.pop_front();
            packets_dropped_++;
        } else {
            break;
        }
    }
}

bool JitterBuffer::get_next_packet(std::vector<uint8_t> &out_data, uint64_t &out_recv_time) {
    std::lock_guard<std::mutex> lock(mutex_);

    if (buffer_.empty()) {
        return false;
    }

    // Check if enough time has passed (delay by max_delay_ms)
    // This creates the jitter buffer delay
    uint64_t now_ns = 0;

    // Get current time (platform-specific, but we can estimate from packet times)
    // In practice, this should use os_gettime_ns() or similar
    // For now, always return if we have packets (caller handles timing)

    // Determine threshold based on latency mode:
    // - Low latency mode (Windows default): threshold of 1 for immediate output
    // - Stable mode: threshold of 2 to smooth jitter
    size_t threshold = low_latency_mode_ ? 1 : 2;

    // Also use immediate output if max_delay is ultra-low (<=8ms)
    if (max_delay_ms_ <= 8) {
        threshold = 1;
    }

    if (buffer_.size() >= threshold) {
        out_data = std::move(buffer_.front().data);
        out_recv_time = buffer_.front().recv_time_ns;
        buffer_.pop_front();
        return true;
    }

    return false;
}

size_t JitterBuffer::size() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return buffer_.size();
}

double JitterBuffer::fill_level_ms() const {
    std::lock_guard<std::mutex> lock(mutex_);

    if (buffer_.size() < 2) {
        return 0.0;
    }

    uint64_t span = buffer_.back().recv_time_ns - buffer_.front().recv_time_ns;
    return static_cast<double>(span) / 1000000.0;
}

} // namespace avolocam
