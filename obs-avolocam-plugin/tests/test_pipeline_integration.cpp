#include <gtest/gtest.h>

#include "rtp-depacketizer.h"
#include "access-unit-assembler.h"
#include "rtp_test_helpers.h"

using namespace avolocam;
using namespace test_helpers;

class PipelineIntegrationTest : public ::testing::Test {
protected:
    RtpDepacketizer depack_;
    AccessUnitAssembler assembler_;

    static constexpr uint32_t SSRC = 0x12345678;
    static constexpr uint32_t TS_INCREMENT = 3000; // 90kHz / 30fps

    // Feed an RTP packet through depacketizer and then assembler.
    // Returns completed access units (may be empty).
    std::vector<AccessUnit> feed_packet(const std::vector<uint8_t>& rtp_packet)
    {
        std::vector<AccessUnit> aus;
        auto nals = depack_.process(rtp_packet.data(), rtp_packet.size());
        for (auto& nal : nals) {
            auto au = assembler_.add_nal(
                std::move(nal.data), nal.rtp_timestamp, nal.marker);
            if (au.has_value()) {
                aus.push_back(std::move(*au));
            }
        }
        return aus;
    }

    // Build a single-NAL RTP packet for a non-IDR slice
    std::vector<uint8_t> make_slice_packet(uint16_t seq, uint32_t ts, bool marker)
    {
        auto payload = make_single_nal(1, 0x60, {0xDE, 0xAD});
        return build_rtp_packet(seq, ts, SSRC, marker, payload);
    }

    // Build a single-NAL RTP packet for an IDR slice
    std::vector<uint8_t> make_idr_packet(uint16_t seq, uint32_t ts, bool marker)
    {
        auto payload = make_single_nal(5, 0x60, {0xBE, 0xEF});
        return build_rtp_packet(seq, ts, SSRC, marker, payload);
    }

    // Build SPS packet
    std::vector<uint8_t> make_sps_packet(uint16_t seq, uint32_t ts, bool marker)
    {
        auto payload = make_single_nal(7, 0x60, {0x42, 0x00, 0x1E});
        return build_rtp_packet(seq, ts, SSRC, marker, payload);
    }

    // Build PPS packet
    std::vector<uint8_t> make_pps_packet(uint16_t seq, uint32_t ts, bool marker)
    {
        auto payload = make_single_nal(8, 0x60, {0xCE, 0x3C, 0x80});
        return build_rtp_packet(seq, ts, SSRC, marker, payload);
    }
};

// --- Full pipeline: single NAL per frame ---

TEST_F(PipelineIntegrationTest, SingleNalFrame) {
    auto pkt = make_slice_packet(1, 9000, /*marker=*/true);
    auto aus = feed_packet(pkt);

    ASSERT_EQ(aus.size(), 1u);
    EXPECT_EQ(aus[0].rtp_timestamp, 9000u);
    EXPECT_EQ(aus[0].nal_count, 1u);
    EXPECT_FALSE(aus[0].is_idr);
}

// --- SPS + PPS + IDR keyframe ---

TEST_F(PipelineIntegrationTest, KeyframeWithParameterSets) {
    uint32_t ts = 9000;

    auto aus1 = feed_packet(make_sps_packet(1, ts, false));
    EXPECT_TRUE(aus1.empty());

    auto aus2 = feed_packet(make_pps_packet(2, ts, false));
    EXPECT_TRUE(aus2.empty());

    auto aus3 = feed_packet(make_idr_packet(3, ts, true));
    ASSERT_EQ(aus3.size(), 1u);
    EXPECT_TRUE(aus3[0].is_idr);
    EXPECT_TRUE(aus3[0].has_sps);
    EXPECT_TRUE(aus3[0].has_pps);
    EXPECT_EQ(aus3[0].nal_count, 3u);
    EXPECT_EQ(aus3[0].rtp_timestamp, ts);
}

// --- Multiple frames in sequence ---

TEST_F(PipelineIntegrationTest, MultipleFramesSequential) {
    std::vector<AccessUnit> all_aus;

    for (int i = 0; i < 5; i++) {
        uint16_t seq = static_cast<uint16_t>(i + 1);
        uint32_t ts = 9000 + i * TS_INCREMENT;
        auto pkt = make_slice_packet(seq, ts, true);
        auto aus = feed_packet(pkt);
        all_aus.insert(all_aus.end(), aus.begin(), aus.end());
    }

    ASSERT_EQ(all_aus.size(), 5u);
    for (int i = 0; i < 5; i++) {
        EXPECT_EQ(all_aus[i].rtp_timestamp, 9000u + i * TS_INCREMENT);
    }
}

// --- FU-A fragmented NAL through full pipeline ---

TEST_F(PipelineIntegrationTest, FragmentedNal_FuA) {
    uint32_t ts = 9000;
    uint8_t nri = 0x60;
    uint8_t nal_type = 5; // IDR

    // Fragment a large NAL into 3 FU-A packets
    auto frag1 = make_fua_start(nri, nal_type, {0x01, 0x02, 0x03});
    auto frag2 = make_fua_middle(nri, nal_type, {0x04, 0x05, 0x06});
    auto frag3 = make_fua_end(nri, nal_type, {0x07, 0x08, 0x09});

    auto pkt1 = build_rtp_packet(1, ts, SSRC, false, frag1);
    auto pkt2 = build_rtp_packet(2, ts, SSRC, false, frag2);
    auto pkt3 = build_rtp_packet(3, ts, SSRC, true, frag3);

    auto aus1 = feed_packet(pkt1);
    EXPECT_TRUE(aus1.empty());

    auto aus2 = feed_packet(pkt2);
    EXPECT_TRUE(aus2.empty());

    auto aus3 = feed_packet(pkt3);
    ASSERT_EQ(aus3.size(), 1u);
    EXPECT_TRUE(aus3[0].is_idr);
    EXPECT_EQ(aus3[0].rtp_timestamp, ts);
}

// --- STAP-A aggregated packet ---

TEST_F(PipelineIntegrationTest, StapA_SpsAndPps) {
    uint32_t ts = 9000;

    // SPS and PPS in a single STAP-A
    auto sps_body = make_single_nal(7, 0x60, {0x42, 0x00, 0x1E});
    auto pps_body = make_single_nal(8, 0x60, {0xCE, 0x3C, 0x80});
    auto stap = make_stap_a({sps_body, pps_body});

    auto stap_pkt = build_rtp_packet(1, ts, SSRC, false, stap);
    auto aus1 = feed_packet(stap_pkt);
    EXPECT_TRUE(aus1.empty()); // No marker yet

    // Follow with IDR
    auto idr_pkt = make_idr_packet(2, ts, true);
    auto aus2 = feed_packet(idr_pkt);

    ASSERT_EQ(aus2.size(), 1u);
    EXPECT_TRUE(aus2[0].is_idr);
    EXPECT_TRUE(aus2[0].has_sps);
    EXPECT_TRUE(aus2[0].has_pps);
    EXPECT_GE(aus2[0].nal_count, 3u); // SPS + PPS + IDR
}

// --- Packet loss simulation ---

TEST_F(PipelineIntegrationTest, PacketLoss_SkippedSequenceNumber) {
    // Frame 1: seq=1, complete
    auto pkt1 = make_slice_packet(1, 9000, true);
    auto aus1 = feed_packet(pkt1);
    ASSERT_EQ(aus1.size(), 1u);

    // Frame 2: seq=2 is LOST, seq=3 arrives
    // This is a different timestamp, so assembler should handle it
    auto pkt3 = make_slice_packet(3, 12000, true);
    auto aus3 = feed_packet(pkt3);
    ASSERT_EQ(aus3.size(), 1u);
    EXPECT_EQ(aus3[0].rtp_timestamp, 12000u);
}

TEST_F(PipelineIntegrationTest, PacketLoss_FuAMiddleFragment) {
    uint32_t ts = 9000;
    uint8_t nri = 0x60;
    uint8_t nal_type = 5;

    // Start fragment
    auto frag_start = make_fua_start(nri, nal_type, {0x01, 0x02});
    auto pkt1 = build_rtp_packet(1, ts, SSRC, false, frag_start);
    feed_packet(pkt1);

    // Middle fragment LOST (seq=2)

    // End fragment arrives with seq=3 (gap detected)
    auto frag_end = make_fua_end(nri, nal_type, {0x07, 0x08});
    auto pkt3 = build_rtp_packet(3, ts, SSRC, true, frag_end);
    auto aus = feed_packet(pkt3);

    // Fragment should be dropped due to sequence gap
    // Assembler may or may not produce an AU depending on implementation
    // But if it does, it should not crash
    // The depacketizer tracks dropped fragments
    EXPECT_GT(depack_.fragments_dropped(), 0u);
}

// --- Out-of-order packets ---

TEST_F(PipelineIntegrationTest, OutOfOrder_DifferentFrames) {
    // Frame 2 arrives before frame 1
    auto pkt2 = make_slice_packet(2, 12000, true);
    auto aus2 = feed_packet(pkt2);
    ASSERT_EQ(aus2.size(), 1u);
    EXPECT_EQ(aus2[0].rtp_timestamp, 12000u);

    auto pkt1 = make_slice_packet(1, 9000, true);
    auto aus1 = feed_packet(pkt1);
    ASSERT_EQ(aus1.size(), 1u);
    EXPECT_EQ(aus1[0].rtp_timestamp, 9000u);
}

TEST_F(PipelineIntegrationTest, OutOfOrder_MultiNalFrame) {
    uint32_t ts = 9000;

    // PPS arrives before SPS (unlikely but possible)
    auto pps_pkt = make_pps_packet(2, ts, false);
    auto aus1 = feed_packet(pps_pkt);
    EXPECT_TRUE(aus1.empty());

    auto sps_pkt = make_sps_packet(1, ts, false);
    auto aus2 = feed_packet(sps_pkt);
    EXPECT_TRUE(aus2.empty());

    auto idr_pkt = make_idr_packet(3, ts, true);
    auto aus3 = feed_packet(idr_pkt);
    ASSERT_EQ(aus3.size(), 1u);
    EXPECT_TRUE(aus3[0].is_idr);
    EXPECT_EQ(aus3[0].nal_count, 3u);
}

// --- Large sequence of keyframes and P-frames ---

TEST_F(PipelineIntegrationTest, RealisticStreamPattern) {
    // Simulates: keyframe every 30 frames, P-frames in between
    std::vector<AccessUnit> all_aus;
    uint16_t seq = 0;

    for (int frame = 0; frame < 60; frame++) {
        uint32_t ts = 9000 + frame * TS_INCREMENT;
        bool is_key = (frame % 30 == 0);

        if (is_key) {
            // SPS + PPS + IDR
            auto aus1 = feed_packet(make_sps_packet(seq++, ts, false));
            auto aus2 = feed_packet(make_pps_packet(seq++, ts, false));
            auto aus3 = feed_packet(make_idr_packet(seq++, ts, true));
            all_aus.insert(all_aus.end(), aus3.begin(), aus3.end());
        } else {
            // Single slice
            auto aus = feed_packet(make_slice_packet(seq++, ts, true));
            all_aus.insert(all_aus.end(), aus.begin(), aus.end());
        }
    }

    EXPECT_EQ(all_aus.size(), 60u);

    // First and 31st frames should be IDR
    EXPECT_TRUE(all_aus[0].is_idr);
    EXPECT_TRUE(all_aus[30].is_idr);

    // Other frames should not be IDR
    EXPECT_FALSE(all_aus[1].is_idr);
    EXPECT_FALSE(all_aus[29].is_idr);
}

// --- Empty and minimal packets ---

TEST_F(PipelineIntegrationTest, TooSmallRtpPacket) {
    // RTP packet too small to contain a valid header
    std::vector<uint8_t> tiny = {0x80, 0x60};
    auto nals = depack_.process(tiny.data(), tiny.size());
    EXPECT_TRUE(nals.empty());
}

// --- Pipeline reset mid-stream ---

TEST_F(PipelineIntegrationTest, ResetMidStream) {
    // Start a frame
    auto pkt1 = make_sps_packet(1, 9000, false);
    feed_packet(pkt1);

    // Reset both components
    depack_.reset();
    assembler_.reset();

    // New frame after reset should work cleanly
    auto pkt2 = make_slice_packet(100, 18000, true);
    auto aus = feed_packet(pkt2);
    ASSERT_EQ(aus.size(), 1u);
    EXPECT_EQ(aus[0].rtp_timestamp, 18000u);
}

// --- Flush after incomplete frame ---

TEST_F(PipelineIntegrationTest, FlushIncompleteFrame) {
    auto pkt = make_sps_packet(1, 9000, false);
    feed_packet(pkt); // no marker, so pending in assembler

    auto flushed = assembler_.flush();
    ASSERT_TRUE(flushed.has_value());
    EXPECT_EQ(flushed->rtp_timestamp, 9000u);
}

// --- Sequence number wraparound (uint16) ---

TEST_F(PipelineIntegrationTest, SequenceNumberWraparound) {
    // Frame near max seq
    auto pkt1 = make_slice_packet(65534, 9000, true);
    auto aus1 = feed_packet(pkt1);
    ASSERT_EQ(aus1.size(), 1u);

    // Frame at max seq
    auto pkt2 = make_slice_packet(65535, 12000, true);
    auto aus2 = feed_packet(pkt2);
    ASSERT_EQ(aus2.size(), 1u);

    // Frame wrapping to 0
    auto pkt3 = make_slice_packet(0, 15000, true);
    auto aus3 = feed_packet(pkt3);
    ASSERT_EQ(aus3.size(), 1u);
    EXPECT_EQ(aus3[0].rtp_timestamp, 15000u);
}
