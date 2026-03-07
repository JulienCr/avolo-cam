#pragma once

#include <cstdint>
#include <vector>

namespace test_helpers {

// Build a complete RTP packet with given parameters
inline std::vector<uint8_t> build_rtp_packet(
    uint16_t seq, uint32_t ts, uint32_t ssrc,
    bool marker, const std::vector<uint8_t>& payload,
    uint8_t pt = 96)
{
    std::vector<uint8_t> pkt;
    pkt.reserve(12 + payload.size());

    // Byte 0: V=2, P=0, X=0, CC=0
    pkt.push_back(0x80);
    // Byte 1: M | PT
    pkt.push_back((marker ? 0x80 : 0x00) | (pt & 0x7F));
    // Bytes 2-3: sequence (big endian)
    pkt.push_back(static_cast<uint8_t>(seq >> 8));
    pkt.push_back(static_cast<uint8_t>(seq & 0xFF));
    // Bytes 4-7: timestamp (big endian)
    pkt.push_back(static_cast<uint8_t>((ts >> 24) & 0xFF));
    pkt.push_back(static_cast<uint8_t>((ts >> 16) & 0xFF));
    pkt.push_back(static_cast<uint8_t>((ts >> 8) & 0xFF));
    pkt.push_back(static_cast<uint8_t>(ts & 0xFF));
    // Bytes 8-11: SSRC (big endian)
    pkt.push_back(static_cast<uint8_t>((ssrc >> 24) & 0xFF));
    pkt.push_back(static_cast<uint8_t>((ssrc >> 16) & 0xFF));
    pkt.push_back(static_cast<uint8_t>((ssrc >> 8) & 0xFF));
    pkt.push_back(static_cast<uint8_t>(ssrc & 0xFF));

    pkt.insert(pkt.end(), payload.begin(), payload.end());
    return pkt;
}

// Make a single NAL payload (just the NAL header + body)
inline std::vector<uint8_t> make_single_nal(uint8_t nal_type, uint8_t nri = 0x60,
                                             const std::vector<uint8_t>& body = {0xAA, 0xBB})
{
    std::vector<uint8_t> payload;
    payload.push_back(nri | (nal_type & 0x1F));
    payload.insert(payload.end(), body.begin(), body.end());
    return payload;
}

// Make FU-A start fragment
inline std::vector<uint8_t> make_fua_start(uint8_t nri, uint8_t nal_type,
                                            const std::vector<uint8_t>& data)
{
    std::vector<uint8_t> payload;
    // FU indicator: NRI | type=28
    payload.push_back(nri | 28);
    // FU header: S=1, E=0, R=0, Type
    payload.push_back(0x80 | (nal_type & 0x1F));
    payload.insert(payload.end(), data.begin(), data.end());
    return payload;
}

// Make FU-A middle fragment
inline std::vector<uint8_t> make_fua_middle(uint8_t nri, uint8_t nal_type,
                                             const std::vector<uint8_t>& data)
{
    std::vector<uint8_t> payload;
    // FU indicator: NRI | type=28
    payload.push_back(nri | 28);
    // FU header: S=0, E=0, R=0, Type
    payload.push_back(nal_type & 0x1F);
    payload.insert(payload.end(), data.begin(), data.end());
    return payload;
}

// Make FU-A end fragment
inline std::vector<uint8_t> make_fua_end(uint8_t nri, uint8_t nal_type,
                                          const std::vector<uint8_t>& data)
{
    std::vector<uint8_t> payload;
    // FU indicator: NRI | type=28
    payload.push_back(nri | 28);
    // FU header: S=0, E=1, R=0, Type
    payload.push_back(0x40 | (nal_type & 0x1F));
    payload.insert(payload.end(), data.begin(), data.end());
    return payload;
}

// Make STAP-A payload from a list of NAL payloads
inline std::vector<uint8_t> make_stap_a(const std::vector<std::vector<uint8_t>>& nals)
{
    std::vector<uint8_t> payload;
    // STAP-A header: F=0 | NRI=0x60 | Type=24
    payload.push_back(0x78); // 0x60 | 24
    for (const auto& nal : nals) {
        uint16_t size = static_cast<uint16_t>(nal.size());
        payload.push_back(static_cast<uint8_t>(size >> 8));
        payload.push_back(static_cast<uint8_t>(size & 0xFF));
        payload.insert(payload.end(), nal.begin(), nal.end());
    }
    return payload;
}

} // namespace test_helpers
