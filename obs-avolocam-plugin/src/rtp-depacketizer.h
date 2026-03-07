/**
 * rtp-depacketizer.h - RFC 6184 H.264/RTP depacketizer
 *
 * Handles:
 * - Single NAL Unit packets (types 1-23)
 * - FU-A fragmented packets (type 28)
 * - STAP-A aggregated packets (type 24)
 */

#pragma once

#include <cstdint>
#include <vector>
#include <optional>
#include <map>
#include <functional>

namespace avolocam {

/**
 * NAL unit types
 */
enum class NalType : uint8_t {
    SLICE_NON_IDR = 1,
    SLICE_A = 2,
    SLICE_B = 3,
    SLICE_C = 4,
    SLICE_IDR = 5,
    SEI = 6,
    SPS = 7,
    PPS = 8,
    AUD = 9,

    // RTP packetization types
    STAP_A = 24,
    STAP_B = 25,
    MTAP_16 = 26,
    MTAP_24 = 27,
    FU_A = 28,
    FU_B = 29,
};

/**
 * Depacketized NAL unit output
 */
struct NalUnit {
    std::vector<uint8_t> data;    // NAL data with start code
    NalType type;                  // NAL unit type
    uint32_t rtp_timestamp;        // RTP timestamp (90kHz)
    uint16_t sequence;             // RTP sequence number
    bool marker;                   // RTP marker bit (last packet of frame)
    bool is_idr;                   // Is IDR frame (keyframe)
};

/**
 * RFC 6184 H.264/RTP depacketizer
 *
 * Reassembles fragmented NAL units and unpacks aggregated packets.
 */
class RtpDepacketizer {
public:
    RtpDepacketizer();
    ~RtpDepacketizer();

    // Non-copyable
    RtpDepacketizer(const RtpDepacketizer&) = delete;
    RtpDepacketizer& operator=(const RtpDepacketizer&) = delete;

    /**
     * Process an RTP packet
     * @param data RTP packet data
     * @param size Packet size
     * @return Vector of complete NAL units (may be empty or have multiple)
     */
    std::vector<NalUnit> process(const uint8_t *data, size_t size);

    /**
     * Reset state (call on stream discontinuity)
     */
    void reset();

    /**
     * Set callback for packet loss detection (called from handle_fu_a on gap)
     */
    using PacketLossCallback = std::function<void(int)>;
    void set_packet_loss_callback(PacketLossCallback callback);

    /**
     * Get statistics
     */
    uint64_t nal_units_output() const { return nal_units_output_; }
    uint64_t fragments_received() const { return fragments_received_; }
    uint64_t fragments_dropped() const { return fragments_dropped_; }

private:
    // FU-A reassembly state per SSRC
    struct FuaState {
        std::vector<uint8_t> buffer;
        uint32_t timestamp;
        uint16_t expected_seq;
        bool in_progress;
        uint8_t nal_header;  // First byte of original NAL
    };

    std::map<uint32_t, FuaState> fua_states_;  // Keyed by SSRC

    // Packet loss callback
    PacketLossCallback packet_loss_callback_;

    // Statistics
    uint64_t nal_units_output_ = 0;
    uint64_t fragments_received_ = 0;
    uint64_t fragments_dropped_ = 0;

    // Parse RTP header
    struct RtpHeader {
        uint8_t version;
        bool padding;
        bool extension;
        uint8_t cc;  // CSRC count
        bool marker;
        uint8_t payload_type;
        uint16_t sequence;
        uint32_t timestamp;
        uint32_t ssrc;
        size_t header_size;
    };

    static std::optional<RtpHeader> parse_rtp_header(const uint8_t *data, size_t size);

    // Handle different packet types
    std::vector<NalUnit> handle_single_nal(const uint8_t *payload, size_t size,
                                           const RtpHeader &rtp);
    std::vector<NalUnit> handle_stap_a(const uint8_t *payload, size_t size,
                                        const RtpHeader &rtp);
    std::vector<NalUnit> handle_fu_a(const uint8_t *payload, size_t size,
                                      const RtpHeader &rtp);

    // Helper to create NAL with start code
    static NalUnit create_nal(const uint8_t *data, size_t size,
                              const RtpHeader &rtp);
};

} // namespace avolocam
