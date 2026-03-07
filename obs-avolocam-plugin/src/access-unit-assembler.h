/**
 * access-unit-assembler.h - Groups NAL units into access units (frames)
 *
 * An Access Unit (AU) contains all NAL units for a single frame,
 * typically: AUD (optional) + SPS + PPS + SEI (optional) + slices
 */

#pragma once

#include <cstdint>
#include <map>
#include <optional>
#include <vector>

#include "rtp-depacketizer.h"

namespace avolocam {

/**
 * Complete access unit (frame) ready for decoding
 */
struct AccessUnit {
    std::vector<uint8_t> data;   // Concatenated NALs with start codes
    uint32_t rtp_timestamp;       // RTP timestamp (90kHz)
    bool is_idr;                  // Contains IDR slice (keyframe)
    bool has_sps;                 // Contains SPS
    bool has_pps;                 // Contains PPS
    size_t nal_count;             // Number of NAL units
};

/**
 * Assembles NAL units into complete access units
 *
 * Groups NALs by RTP timestamp and outputs when marker bit is received.
 */
class AccessUnitAssembler {
public:
    AccessUnitAssembler();
    ~AccessUnitAssembler();

    // Non-copyable
    AccessUnitAssembler(const AccessUnitAssembler&) = delete;
    AccessUnitAssembler& operator=(const AccessUnitAssembler&) = delete;

    /**
     * Add a NAL unit to assembly
     * @param nal_data NAL data including start code
     * @param rtp_timestamp RTP timestamp
     * @param marker RTP marker bit (true = last NAL of frame)
     * @return Complete access unit if frame is complete, nullopt otherwise
     */
    std::optional<AccessUnit> add_nal(std::vector<uint8_t> nal_data,
                                       uint32_t rtp_timestamp,
                                       bool marker);

    /**
     * Flush any pending incomplete access unit
     * @return Pending AU if any
     */
    std::optional<AccessUnit> flush();

    /**
     * Reset state (call on stream discontinuity)
     */
    void reset();

    /**
     * Get cached SPS/PPS (needed for decoder init)
     */
    const std::vector<uint8_t>& get_sps() const { return cached_sps_; }
    const std::vector<uint8_t>& get_pps() const { return cached_pps_; }
    bool has_parameter_sets() const { return !cached_sps_.empty() && !cached_pps_.empty(); }

private:
    struct PendingAU {
        std::vector<uint8_t> data;
        uint32_t timestamp;
        bool has_idr = false;
        bool has_sps = false;
        bool has_pps = false;
        size_t nal_count = 0;
    };

    std::map<uint32_t, PendingAU> pending_;  // Keyed by RTP timestamp

    // Cached parameter sets for decoder reinitialization
    std::vector<uint8_t> cached_sps_;
    std::vector<uint8_t> cached_pps_;

    // Maximum pending AUs before cleanup
    static constexpr size_t MAX_PENDING_AUS = 16;

    AccessUnit finalize_au(PendingAU& pending);
    void cleanup_old_pending(uint32_t current_timestamp);
};

} // namespace avolocam
