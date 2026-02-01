/**
 * access-unit-assembler.cpp - Access unit assembly implementation
 */

#include "access-unit-assembler.h"

namespace avolocam {

AccessUnitAssembler::AccessUnitAssembler() = default;
AccessUnitAssembler::~AccessUnitAssembler() = default;

void AccessUnitAssembler::reset() {
    pending_.clear();
    // Keep cached SPS/PPS for potential resync
}

std::optional<AccessUnit> AccessUnitAssembler::add_nal(
    std::vector<uint8_t> nal_data,
    uint32_t rtp_timestamp,
    bool marker)
{
    // Get NAL type from data (after start code)
    // Start code is 3 or 4 bytes
    size_t nal_offset = 3;
    if (nal_data.size() >= 4 && nal_data[0] == 0 && nal_data[1] == 0 &&
        nal_data[2] == 0 && nal_data[3] == 1) {
        nal_offset = 4;
    }

    if (nal_data.size() <= nal_offset) {
        return std::nullopt;
    }

    uint8_t nal_type = nal_data[nal_offset] & 0x1F;

    // Cache SPS/PPS
    if (nal_type == 7) {
        cached_sps_ = nal_data;
    } else if (nal_type == 8) {
        cached_pps_ = nal_data;
    }

    // Get or create pending AU for this timestamp
    auto& pending = pending_[rtp_timestamp];
    if (pending.nal_count == 0) {
        pending.timestamp = rtp_timestamp;
    }

    // Track what's in this AU
    if (nal_type == 5) pending.has_idr = true;
    if (nal_type == 7) pending.has_sps = true;
    if (nal_type == 8) pending.has_pps = true;

    // Append NAL data
    pending.data.insert(pending.data.end(), nal_data.begin(), nal_data.end());
    pending.nal_count++;

    // Complete AU on marker bit
    if (marker) {
        AccessUnit au = finalize_au(pending);
        pending_.erase(rtp_timestamp);

        // Cleanup old pending AUs
        cleanup_old_pending(rtp_timestamp);

        return au;
    }

    return std::nullopt;
}

std::optional<AccessUnit> AccessUnitAssembler::flush() {
    if (pending_.empty()) {
        return std::nullopt;
    }

    // Return the oldest pending AU
    auto it = pending_.begin();
    AccessUnit au = finalize_au(it->second);
    pending_.erase(it);
    return au;
}

AccessUnit AccessUnitAssembler::finalize_au(PendingAU& pending) {
    AccessUnit au;
    au.data = std::move(pending.data);
    au.rtp_timestamp = pending.timestamp;
    au.is_idr = pending.has_idr;
    au.has_sps = pending.has_sps;
    au.has_pps = pending.has_pps;
    au.nal_count = pending.nal_count;
    return au;
}

void AccessUnitAssembler::cleanup_old_pending(uint32_t current_timestamp) {
    // Remove pending AUs that are too old (likely never completed)
    // Use timestamp difference accounting for wrap-around

    while (pending_.size() > MAX_PENDING_AUS) {
        // Remove oldest
        pending_.erase(pending_.begin());
    }

    // Also remove AUs with timestamps too far from current
    // (assuming 90kHz clock, 1 second = 90000 ticks)
    const uint32_t max_age = 90000 * 2;  // 2 seconds

    auto it = pending_.begin();
    while (it != pending_.end()) {
        int32_t age = static_cast<int32_t>(current_timestamp - it->first);
        if (age > static_cast<int32_t>(max_age)) {
            it = pending_.erase(it);
        } else {
            ++it;
        }
    }
}

} // namespace avolocam
