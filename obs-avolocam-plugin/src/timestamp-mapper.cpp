/**
 * timestamp-mapper.cpp - RTP timestamp to frame timing mapper implementation
 */

#include "timestamp-mapper.h"
#include <obs-module.h>
#include "logging.h"
#include <algorithm>
#include <cmath>

namespace avolocam {

TimestampMapper::TimestampMapper()
{
    ALOG(LOG_DEBUG, "TimestampMapper created");
}

TimestampMapper::~TimestampMapper()
{
    ALOG(LOG_DEBUG, "TimestampMapper destroyed, stats: added=%llu lookups=%llu hits=%llu misses=%llu",
         (unsigned long long)total_added_,
         (unsigned long long)total_lookups_,
         (unsigned long long)lookup_hits_,
         (unsigned long long)lookup_misses_);
}

void TimestampMapper::register_frame_info(const FrameTimingInfo &info)
{
    std::lock_guard<std::mutex> lock(mutex_);

    // Check if we need to clean up
    if (mappings_.size() >= MAX_ENTRIES) {
        // Remove oldest quarter of entries
        auto it = mappings_.begin();
        for (size_t i = 0; i < MAX_ENTRIES / 4 && it != mappings_.end(); i++) {
            it = mappings_.erase(it);
        }
    }

    mappings_[info.rtp_ts] = info;
    total_added_++;
}

double TimestampMapper::calculate_latency(uint32_t rtp_timestamp, uint64_t recv_time_ns)
{
    LatencyInfo info = get_latency_info(rtp_timestamp, recv_time_ns);
    return info.valid ? info.total_latency_ms : -1.0;
}

LatencyInfo TimestampMapper::get_latency_info(uint32_t rtp_timestamp, uint64_t recv_time_ns)
{
    std::lock_guard<std::mutex> lock(mutex_);

    total_lookups_++;

    LatencyInfo result = {};
    result.valid = false;

    // Exact match first
    auto it = mappings_.find(rtp_timestamp);
    if (it == mappings_.end()) {
        // Try to find closest match within a small range
        // This handles minor timing discrepancies
        auto lower = mappings_.lower_bound(rtp_timestamp);
        auto upper = lower;

        if (lower != mappings_.begin()) {
            --lower;
        }

        // Find closest within 90000 ticks (1 second at 90kHz)
        const uint32_t max_diff = 90000;
        uint32_t best_diff = max_diff + 1;

        for (auto check = lower; check != mappings_.end(); ++check) {
            uint32_t diff = (uint32_t)std::abs(timestamp_diff(check->first, rtp_timestamp));
            if (diff < best_diff) {
                best_diff = diff;
                it = check;
            }
            // Stop if we've gone too far past the target
            if (timestamp_diff(check->first, rtp_timestamp) > (int32_t)max_diff) {
                break;
            }
        }

        if (best_diff > max_diff) {
            lookup_misses_++;
            return result;
        }
    }

    lookup_hits_++;

    const FrameTimingInfo &frame = it->second;

    // Calculate latency components
    // Note: encode_ts_ns and capture_ts_ns are relative to iOS boot time
    // recv_time_ns is relative to local system time
    // We use clock_offset_ns_ to adjust

    // Encode latency (on iOS device)
    int64_t encode_latency_ns = frame.encode_ts_ns - frame.capture_ts_ns;
    result.capture_to_encode_ms = encode_latency_ns / 1000000.0;

    // Network + decode latency estimate
    // Adjust receive time by clock offset
    int64_t adjusted_recv_ns = (int64_t)recv_time_ns - clock_offset_ns_;

    // Network latency = local receive time - remote encode time
    int64_t network_latency_ns = adjusted_recv_ns - frame.encode_ts_ns;

    // Handle clock sync issues - if network latency is negative,
    // our clock offset estimate is wrong
    if (network_latency_ns < 0) {
        // Use a minimum reasonable network latency
        network_latency_ns = 1000000; // 1ms minimum
    }

    result.encode_to_receive_ms = network_latency_ns / 1000000.0;

    // Total latency
    result.total_latency_ms = result.capture_to_encode_ms + result.encode_to_receive_ms;
    result.valid = true;

    return result;
}

void TimestampMapper::cleanup_old_entries(uint32_t current_rtp_ts)
{
    std::lock_guard<std::mutex> lock(mutex_);

    // Remove entries that are more than 5 seconds old (450000 ticks at 90kHz)
    const uint32_t max_age = 450000;

    auto it = mappings_.begin();
    while (it != mappings_.end()) {
        if (is_older(it->first, current_rtp_ts) &&
            timestamp_diff(current_rtp_ts, it->first) > (int32_t)max_age) {
            it = mappings_.erase(it);
        } else {
            ++it;
        }
    }
}

void TimestampMapper::set_clock_offset(int64_t offset_ns)
{
    std::lock_guard<std::mutex> lock(mutex_);
    clock_offset_ns_ = offset_ns;
}

int64_t TimestampMapper::get_clock_offset() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return clock_offset_ns_;
}

void TimestampMapper::reset()
{
    std::lock_guard<std::mutex> lock(mutex_);
    mappings_.clear();
}

size_t TimestampMapper::mapping_count() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return mappings_.size();
}

bool TimestampMapper::is_older(uint32_t ts_a, uint32_t ts_b)
{
    // Handle wraparound: ts_a is older than ts_b if
    // (ts_b - ts_a) < half the range (treating as unsigned)
    return (ts_b - ts_a) < TIMESTAMP_HALF_RANGE;
}

int32_t TimestampMapper::timestamp_diff(uint32_t ts_a, uint32_t ts_b)
{
    // Return signed difference (ts_a - ts_b) handling wraparound
    uint32_t diff = ts_a - ts_b;
    if (diff < TIMESTAMP_HALF_RANGE) {
        return (int32_t)diff;
    } else {
        return (int32_t)(diff - 0x100000000ULL);
    }
}

} // namespace avolocam
