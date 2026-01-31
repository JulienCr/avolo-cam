/**
 * rtp-depacketizer.cpp - RFC 6184 H.264/RTP depacketizer implementation
 */

#include "rtp-depacketizer.h"
#include <cstring>

namespace avolocam {

// H.264 NAL start code (4 bytes for SPS/PPS/IDR, 3 bytes for others)
static const uint8_t START_CODE_4[] = {0x00, 0x00, 0x00, 0x01};
static const uint8_t START_CODE_3[] = {0x00, 0x00, 0x01};

RtpDepacketizer::RtpDepacketizer() = default;
RtpDepacketizer::~RtpDepacketizer() = default;

void RtpDepacketizer::reset() {
    fua_states_.clear();
}

std::optional<RtpDepacketizer::RtpHeader> RtpDepacketizer::parse_rtp_header(
    const uint8_t *data, size_t size)
{
    if (size < 12) return std::nullopt;

    RtpHeader hdr = {};

    // First byte: V(2) | P(1) | X(1) | CC(4)
    hdr.version = (data[0] >> 6) & 0x03;
    hdr.padding = (data[0] >> 5) & 0x01;
    hdr.extension = (data[0] >> 4) & 0x01;
    hdr.cc = data[0] & 0x0F;

    if (hdr.version != 2) return std::nullopt;

    // Second byte: M(1) | PT(7)
    hdr.marker = (data[1] >> 7) & 0x01;
    hdr.payload_type = data[1] & 0x7F;

    // Bytes 2-3: Sequence number (big endian)
    hdr.sequence = (static_cast<uint16_t>(data[2]) << 8) | data[3];

    // Bytes 4-7: Timestamp (big endian)
    hdr.timestamp = (static_cast<uint32_t>(data[4]) << 24) |
                    (static_cast<uint32_t>(data[5]) << 16) |
                    (static_cast<uint32_t>(data[6]) << 8) |
                    data[7];

    // Bytes 8-11: SSRC (big endian)
    hdr.ssrc = (static_cast<uint32_t>(data[8]) << 24) |
               (static_cast<uint32_t>(data[9]) << 16) |
               (static_cast<uint32_t>(data[10]) << 8) |
               data[11];

    // Calculate header size (12 + 4*CC + extension)
    hdr.header_size = 12 + 4 * hdr.cc;

    if (hdr.extension && size >= hdr.header_size + 4) {
        // Skip extension header
        uint16_t ext_length = (static_cast<uint16_t>(data[hdr.header_size + 2]) << 8) |
                              data[hdr.header_size + 3];
        hdr.header_size += 4 + ext_length * 4;
    }

    if (size < hdr.header_size) return std::nullopt;

    return hdr;
}

NalUnit RtpDepacketizer::create_nal(const uint8_t *data, size_t size,
                                     const RtpHeader &rtp)
{
    NalUnit nal;
    nal.rtp_timestamp = rtp.timestamp;
    nal.sequence = rtp.sequence;
    nal.marker = rtp.marker;

    // Determine NAL type from first byte
    uint8_t nal_header = data[0];
    uint8_t nal_type = nal_header & 0x1F;
    nal.type = static_cast<NalType>(nal_type);
    nal.is_idr = (nal_type == 5);

    // Use 4-byte start code for SPS, PPS, IDR; 3-byte for others
    bool use_long_start = (nal_type == 5 || nal_type == 7 || nal_type == 8);

    if (use_long_start) {
        nal.data.reserve(4 + size);
        nal.data.insert(nal.data.end(), START_CODE_4, START_CODE_4 + 4);
    } else {
        nal.data.reserve(3 + size);
        nal.data.insert(nal.data.end(), START_CODE_3, START_CODE_3 + 3);
    }
    nal.data.insert(nal.data.end(), data, data + size);

    return nal;
}

std::vector<NalUnit> RtpDepacketizer::process(const uint8_t *data, size_t size) {
    std::vector<NalUnit> result;

    auto hdr_opt = parse_rtp_header(data, size);
    if (!hdr_opt) {
        return result;
    }

    const RtpHeader &rtp = *hdr_opt;
    const uint8_t *payload = data + rtp.header_size;
    size_t payload_size = size - rtp.header_size;

    if (payload_size == 0) {
        return result;
    }

    // Check NAL unit type (first byte of payload)
    uint8_t nal_type = payload[0] & 0x1F;

    if (nal_type >= 1 && nal_type <= 23) {
        // Single NAL unit packet
        result = handle_single_nal(payload, payload_size, rtp);
    } else if (nal_type == 24) {
        // STAP-A (aggregation)
        result = handle_stap_a(payload, payload_size, rtp);
    } else if (nal_type == 28) {
        // FU-A (fragmentation)
        result = handle_fu_a(payload, payload_size, rtp);
    }
    // Types 25-27 and 29 are less common, not implemented

    nal_units_output_ += result.size();
    return result;
}

std::vector<NalUnit> RtpDepacketizer::handle_single_nal(
    const uint8_t *payload, size_t size, const RtpHeader &rtp)
{
    std::vector<NalUnit> result;
    result.push_back(create_nal(payload, size, rtp));
    return result;
}

std::vector<NalUnit> RtpDepacketizer::handle_stap_a(
    const uint8_t *payload, size_t size, const RtpHeader &rtp)
{
    std::vector<NalUnit> result;

    // Skip STAP-A header (1 byte)
    size_t offset = 1;

    while (offset + 2 < size) {
        // Read NAL unit size (2 bytes, big endian)
        uint16_t nal_size = (static_cast<uint16_t>(payload[offset]) << 8) |
                            payload[offset + 1];
        offset += 2;

        if (offset + nal_size > size) {
            break;  // Truncated packet
        }

        result.push_back(create_nal(payload + offset, nal_size, rtp));
        offset += nal_size;
    }

    return result;
}

std::vector<NalUnit> RtpDepacketizer::handle_fu_a(
    const uint8_t *payload, size_t size, const RtpHeader &rtp)
{
    std::vector<NalUnit> result;

    if (size < 2) {
        return result;
    }

    fragments_received_++;

    // FU indicator (byte 0): F(1) | NRI(2) | Type=28(5)
    uint8_t fu_indicator = payload[0];
    uint8_t nri = fu_indicator & 0x60;  // Preserve NRI

    // FU header (byte 1): S(1) | E(1) | R(1) | Type(5)
    uint8_t fu_header = payload[1];
    bool start_bit = (fu_header >> 7) & 0x01;
    bool end_bit = (fu_header >> 6) & 0x01;
    uint8_t nal_type = fu_header & 0x1F;

    // Get or create FU-A state for this SSRC
    FuaState &state = fua_states_[rtp.ssrc];

    if (start_bit) {
        // Start of fragmented NAL unit
        state.buffer.clear();
        state.timestamp = rtp.timestamp;
        state.expected_seq = rtp.sequence;
        state.in_progress = true;

        // Reconstruct NAL header: F=0 | NRI | Type
        state.nal_header = nri | nal_type;
        state.buffer.push_back(state.nal_header);
    }

    if (!state.in_progress) {
        // Got middle/end fragment without start
        fragments_dropped_++;
        return result;
    }

    // Check sequence continuity
    int16_t seq_diff = static_cast<int16_t>(rtp.sequence - state.expected_seq);
    if (seq_diff != 0 && !start_bit) {
        // Missing packets, abort fragmentation
        state.in_progress = false;
        state.buffer.clear();
        fragments_dropped_++;
        return result;
    }
    state.expected_seq = rtp.sequence + 1;

    // Append fragment data (skip FU indicator and header)
    const uint8_t *fragment_data = payload + 2;
    size_t fragment_size = size - 2;
    state.buffer.insert(state.buffer.end(), fragment_data,
                        fragment_data + fragment_size);

    if (end_bit) {
        // Complete NAL unit
        NalUnit nal;
        nal.rtp_timestamp = state.timestamp;
        nal.sequence = rtp.sequence;
        nal.marker = rtp.marker;
        nal.type = static_cast<NalType>(nal_type);
        nal.is_idr = (nal_type == 5);

        // Add start code
        bool use_long_start = (nal_type == 5 || nal_type == 7 || nal_type == 8);
        if (use_long_start) {
            nal.data.insert(nal.data.end(), START_CODE_4, START_CODE_4 + 4);
        } else {
            nal.data.insert(nal.data.end(), START_CODE_3, START_CODE_3 + 3);
        }
        nal.data.insert(nal.data.end(), state.buffer.begin(), state.buffer.end());

        result.push_back(std::move(nal));

        state.in_progress = false;
        state.buffer.clear();
    }

    return result;
}

} // namespace avolocam
