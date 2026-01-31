/**
 * timestamp-mapper.h - RTP timestamp to frame timing mapper
 *
 * Correlates RTP timestamps (90kHz) with frame timing information
 * received via WebSocket from the iOS device.
 *
 * Used to calculate end-to-end latency and synchronize multiple sources.
 */

#pragma once

#include <cstdint>
#include <map>
#include <mutex>

namespace avolocam {

/**
 * Frame timing information received via WebSocket
 */
struct FrameTimingInfo {
    int64_t frame_idx;         // Sequential frame index
    uint32_t rtp_ts;           // RTP timestamp (90kHz clock)
    int64_t capture_ts_ns;     // Capture timestamp on iOS (nanoseconds since boot)
    int64_t encode_ts_ns;      // Encode completion timestamp (nanoseconds since boot)
};

/**
 * Calculated latency breakdown
 */
struct LatencyInfo {
    double capture_to_encode_ms;  // Time to encode on iOS
    double encode_to_receive_ms;  // Network transit time
    double total_latency_ms;      // Total glass-to-glass estimate
    bool valid;                   // True if mapping was found
};

/**
 * Maps RTP timestamps to frame timing info for latency calculation
 *
 * Thread-safe for concurrent access from WebSocket and decode threads.
 */
class TimestampMapper {
public:
    TimestampMapper();
    ~TimestampMapper();

    // Non-copyable
    TimestampMapper(const TimestampMapper&) = delete;
    TimestampMapper& operator=(const TimestampMapper&) = delete;

    /**
     * Register frame timing info received via WebSocket
     *
     * @param info Frame timing information from iOS
     */
    void register_frame_info(const FrameTimingInfo &info);

    /**
     * Calculate latency for a given RTP timestamp
     *
     * @param rtp_timestamp RTP timestamp from decoded frame
     * @param recv_time_ns Local receive time in nanoseconds
     * @return Calculated latency in milliseconds, or -1.0 if no mapping found
     */
    double calculate_latency(uint32_t rtp_timestamp, uint64_t recv_time_ns);

    /**
     * Get detailed latency breakdown
     *
     * @param rtp_timestamp RTP timestamp from decoded frame
     * @param recv_time_ns Local receive time in nanoseconds
     * @return Latency breakdown structure
     */
    LatencyInfo get_latency_info(uint32_t rtp_timestamp, uint64_t recv_time_ns);

    /**
     * Clean up old mappings to prevent memory growth
     *
     * Should be called periodically with the current RTP timestamp.
     *
     * @param current_rtp_ts Current RTP timestamp
     */
    void cleanup_old_entries(uint32_t current_rtp_ts);

    /**
     * Set the base time offset for clock synchronization
     *
     * The iOS device and OBS machine have different clocks.
     * This offset adjusts for the difference.
     *
     * @param offset_ns Offset in nanoseconds (local - remote)
     */
    void set_clock_offset(int64_t offset_ns);

    /**
     * Get current clock offset
     */
    int64_t get_clock_offset() const;

    /**
     * Reset all mappings
     */
    void reset();

    /**
     * Get number of active mappings
     */
    size_t mapping_count() const;

    /**
     * Get statistics
     */
    uint64_t total_mappings_added() const { return total_added_; }
    uint64_t total_lookups() const { return total_lookups_; }
    uint64_t lookup_hits() const { return lookup_hits_; }
    uint64_t lookup_misses() const { return lookup_misses_; }

private:
    mutable std::mutex mutex_;

    // Map from RTP timestamp to frame timing info
    std::map<uint32_t, FrameTimingInfo> mappings_;

    // Clock offset between local and remote clocks
    int64_t clock_offset_ns_ = 0;

    // Configuration
    static constexpr size_t MAX_ENTRIES = 256;

    // RTP timestamp wraparound handling
    // RTP uses 32-bit timestamp, at 90kHz it wraps every ~13.3 hours
    static constexpr uint32_t TIMESTAMP_HALF_RANGE = 0x80000000;

    // Statistics
    uint64_t total_added_ = 0;
    uint64_t total_lookups_ = 0;
    uint64_t lookup_hits_ = 0;
    uint64_t lookup_misses_ = 0;

    // Check if ts_a is older than ts_b (handles wraparound)
    static bool is_older(uint32_t ts_a, uint32_t ts_b);

    // Calculate timestamp difference (handles wraparound)
    static int32_t timestamp_diff(uint32_t ts_a, uint32_t ts_b);
};

} // namespace avolocam
