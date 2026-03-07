#include <gtest/gtest.h>
#include "rtp-depacketizer.h"
#include "rtp_test_helpers.h"

using namespace avolocam;
using namespace test_helpers;

class RtpDepacketizerTest : public ::testing::Test {
protected:
    RtpDepacketizer depak;
};

// --- Rejection tests ---

TEST_F(RtpDepacketizerTest, TooSmallPacket) {
    uint8_t data[] = {0x80, 0x60};
    auto result = depak.process(data, 2);
    EXPECT_TRUE(result.empty());
}

TEST_F(RtpDepacketizerTest, InvalidVersion) {
    // Version 0 instead of 2
    auto pkt = build_rtp_packet(1, 1000, 0x1234, true, {0x61, 0xAA});
    pkt[0] = 0x00; // V=0
    auto result = depak.process(pkt.data(), pkt.size());
    EXPECT_TRUE(result.empty());
}

TEST_F(RtpDepacketizerTest, EmptyPayload) {
    // RTP header only, no payload
    auto pkt = build_rtp_packet(1, 1000, 0x1234, true, {});
    auto result = depak.process(pkt.data(), pkt.size());
    EXPECT_TRUE(result.empty());
}

// --- Single NAL tests ---

TEST_F(RtpDepacketizerTest, SingleNalType1) {
    auto payload = make_single_nal(1); // non-IDR slice
    auto pkt = build_rtp_packet(1, 9000, 0x1234, true, payload);
    auto result = depak.process(pkt.data(), pkt.size());

    ASSERT_EQ(result.size(), 1u);
    EXPECT_EQ(result[0].type, NalType::SLICE_NON_IDR);
    EXPECT_FALSE(result[0].is_idr);
    // Should have 3-byte start code for non-IDR
    EXPECT_EQ(result[0].data[0], 0x00);
    EXPECT_EQ(result[0].data[1], 0x00);
    EXPECT_EQ(result[0].data[2], 0x01);
}

TEST_F(RtpDepacketizerTest, SingleNalType5_IDR) {
    auto payload = make_single_nal(5); // IDR slice
    auto pkt = build_rtp_packet(1, 9000, 0x1234, true, payload);
    auto result = depak.process(pkt.data(), pkt.size());

    ASSERT_EQ(result.size(), 1u);
    EXPECT_EQ(result[0].type, NalType::SLICE_IDR);
    EXPECT_TRUE(result[0].is_idr);
    // Should have 4-byte start code for IDR
    EXPECT_EQ(result[0].data[0], 0x00);
    EXPECT_EQ(result[0].data[1], 0x00);
    EXPECT_EQ(result[0].data[2], 0x00);
    EXPECT_EQ(result[0].data[3], 0x01);
}

TEST_F(RtpDepacketizerTest, SingleNalType7_SPS) {
    auto payload = make_single_nal(7);
    auto pkt = build_rtp_packet(1, 9000, 0x1234, false, payload);
    auto result = depak.process(pkt.data(), pkt.size());

    ASSERT_EQ(result.size(), 1u);
    EXPECT_EQ(result[0].type, NalType::SPS);
    // 4-byte start code for SPS
    EXPECT_EQ(result[0].data[0], 0x00);
    EXPECT_EQ(result[0].data[1], 0x00);
    EXPECT_EQ(result[0].data[2], 0x00);
    EXPECT_EQ(result[0].data[3], 0x01);
}

TEST_F(RtpDepacketizerTest, SingleNalType8_PPS) {
    auto payload = make_single_nal(8);
    auto pkt = build_rtp_packet(1, 9000, 0x1234, false, payload);
    auto result = depak.process(pkt.data(), pkt.size());

    ASSERT_EQ(result.size(), 1u);
    EXPECT_EQ(result[0].type, NalType::PPS);
    // 4-byte start code for PPS
    EXPECT_EQ(result[0].data[2], 0x00);
    EXPECT_EQ(result[0].data[3], 0x01);
}

TEST_F(RtpDepacketizerTest, SingleNalMarkerBit) {
    auto payload = make_single_nal(1);
    auto pkt_marker = build_rtp_packet(10, 9000, 0x1234, true, payload);
    auto pkt_no_marker = build_rtp_packet(11, 9000, 0x1234, false, payload);

    auto r1 = depak.process(pkt_marker.data(), pkt_marker.size());
    auto r2 = depak.process(pkt_no_marker.data(), pkt_no_marker.size());

    ASSERT_EQ(r1.size(), 1u);
    ASSERT_EQ(r2.size(), 1u);
    EXPECT_TRUE(r1[0].marker);
    EXPECT_FALSE(r2[0].marker);
}

TEST_F(RtpDepacketizerTest, SingleNalTimestampSequence) {
    auto payload = make_single_nal(1);
    auto pkt = build_rtp_packet(42, 90000, 0xABCD, true, payload);
    auto result = depak.process(pkt.data(), pkt.size());

    ASSERT_EQ(result.size(), 1u);
    EXPECT_EQ(result[0].rtp_timestamp, 90000u);
    EXPECT_EQ(result[0].sequence, 42u);
}

// --- STAP-A tests ---

TEST_F(RtpDepacketizerTest, StapA_SingleNal) {
    auto nal1 = make_single_nal(7); // SPS
    auto stap = make_stap_a({nal1});
    auto pkt = build_rtp_packet(1, 9000, 0x1234, false, stap);
    auto result = depak.process(pkt.data(), pkt.size());

    ASSERT_EQ(result.size(), 1u);
    EXPECT_EQ(result[0].type, NalType::SPS);
}

TEST_F(RtpDepacketizerTest, StapA_TwoNals) {
    auto sps = make_single_nal(7);
    auto pps = make_single_nal(8);
    auto stap = make_stap_a({sps, pps});
    auto pkt = build_rtp_packet(1, 9000, 0x1234, false, stap);
    auto result = depak.process(pkt.data(), pkt.size());

    ASSERT_EQ(result.size(), 2u);
    EXPECT_EQ(result[0].type, NalType::SPS);
    EXPECT_EQ(result[1].type, NalType::PPS);
}

TEST_F(RtpDepacketizerTest, StapA_ThreeNals) {
    auto sps = make_single_nal(7);
    auto pps = make_single_nal(8);
    auto idr = make_single_nal(5);
    auto stap = make_stap_a({sps, pps, idr});
    auto pkt = build_rtp_packet(1, 9000, 0x1234, true, stap);
    auto result = depak.process(pkt.data(), pkt.size());

    ASSERT_EQ(result.size(), 3u);
    EXPECT_EQ(result[0].type, NalType::SPS);
    EXPECT_EQ(result[1].type, NalType::PPS);
    EXPECT_EQ(result[2].type, NalType::SLICE_IDR);
    EXPECT_TRUE(result[2].is_idr);
}

TEST_F(RtpDepacketizerTest, StapA_Truncated) {
    // STAP-A with size claiming more data than available
    std::vector<uint8_t> payload = {0x78}; // STAP-A header
    payload.push_back(0x00);
    payload.push_back(0xFF); // Size = 255 but no data follows
    auto pkt = build_rtp_packet(1, 9000, 0x1234, false, payload);
    auto result = depak.process(pkt.data(), pkt.size());

    EXPECT_TRUE(result.empty());
}

// --- FU-A tests ---

TEST_F(RtpDepacketizerTest, FuA_Complete2Parts) {
    uint8_t nri = 0x60;
    uint8_t type = 1; // non-IDR slice

    auto start_payload = make_fua_start(nri, type, {0x11, 0x22});
    auto end_payload = make_fua_end(nri, type, {0x33, 0x44});

    auto pkt1 = build_rtp_packet(100, 9000, 0x1234, false, start_payload);
    auto pkt2 = build_rtp_packet(101, 9000, 0x1234, true, end_payload);

    auto r1 = depak.process(pkt1.data(), pkt1.size());
    EXPECT_TRUE(r1.empty()); // Not complete yet

    auto r2 = depak.process(pkt2.data(), pkt2.size());
    ASSERT_EQ(r2.size(), 1u);
    EXPECT_EQ(r2[0].type, NalType::SLICE_NON_IDR);
    EXPECT_FALSE(r2[0].is_idr);
    // Check reconstructed NAL: start_code + nal_header + data
    // 3-byte start code for non-IDR
    EXPECT_EQ(r2[0].data[0], 0x00);
    EXPECT_EQ(r2[0].data[1], 0x00);
    EXPECT_EQ(r2[0].data[2], 0x01);
    // NAL header: nri | type
    EXPECT_EQ(r2[0].data[3], nri | type);
    // Payload data
    EXPECT_EQ(r2[0].data[4], 0x11);
    EXPECT_EQ(r2[0].data[5], 0x22);
    EXPECT_EQ(r2[0].data[6], 0x33);
    EXPECT_EQ(r2[0].data[7], 0x44);
}

TEST_F(RtpDepacketizerTest, FuA_Complete3Parts) {
    uint8_t nri = 0x60;
    uint8_t type = 1;

    auto pkt1 = build_rtp_packet(100, 9000, 0x1234, false,
                                  make_fua_start(nri, type, {0x11}));
    auto pkt2 = build_rtp_packet(101, 9000, 0x1234, false,
                                  make_fua_middle(nri, type, {0x22}));
    auto pkt3 = build_rtp_packet(102, 9000, 0x1234, true,
                                  make_fua_end(nri, type, {0x33}));

    EXPECT_TRUE(depak.process(pkt1.data(), pkt1.size()).empty());
    EXPECT_TRUE(depak.process(pkt2.data(), pkt2.size()).empty());

    auto r3 = depak.process(pkt3.data(), pkt3.size());
    ASSERT_EQ(r3.size(), 1u);
    // start_code(3) + nal_header(1) + 3 bytes data
    EXPECT_EQ(r3[0].data.size(), 7u);
}

TEST_F(RtpDepacketizerTest, FuA_MissingMiddle) {
    uint8_t nri = 0x60;
    uint8_t type = 1;
    int loss_count = 0;
    depak.set_packet_loss_callback([&](int n) { loss_count += n; });

    auto pkt1 = build_rtp_packet(100, 9000, 0x1234, false,
                                  make_fua_start(nri, type, {0x11}));
    // Skip seq 101 (middle)
    auto pkt3 = build_rtp_packet(102, 9000, 0x1234, true,
                                  make_fua_end(nri, type, {0x33}));

    depak.process(pkt1.data(), pkt1.size());
    auto r = depak.process(pkt3.data(), pkt3.size());

    EXPECT_TRUE(r.empty()); // Fragment dropped
    EXPECT_GT(loss_count, 0);
    EXPECT_GT(depak.fragments_dropped(), 0u);
}

TEST_F(RtpDepacketizerTest, FuA_MiddleWithoutStart) {
    uint8_t nri = 0x60;
    uint8_t type = 1;

    // Send middle fragment without a preceding start
    auto pkt = build_rtp_packet(50, 9000, 0x1234, false,
                                 make_fua_middle(nri, type, {0x22}));
    auto r = depak.process(pkt.data(), pkt.size());

    EXPECT_TRUE(r.empty());
    EXPECT_EQ(depak.fragments_dropped(), 1u);
}

TEST_F(RtpDepacketizerTest, FuA_IdrFragment) {
    uint8_t nri = 0x60;
    uint8_t type = 5; // IDR

    auto pkt1 = build_rtp_packet(200, 18000, 0x1234, false,
                                  make_fua_start(nri, type, {0xAA}));
    auto pkt2 = build_rtp_packet(201, 18000, 0x1234, true,
                                  make_fua_end(nri, type, {0xBB}));

    depak.process(pkt1.data(), pkt1.size());
    auto r = depak.process(pkt2.data(), pkt2.size());

    ASSERT_EQ(r.size(), 1u);
    EXPECT_TRUE(r[0].is_idr);
    EXPECT_EQ(r[0].type, NalType::SLICE_IDR);
    // 4-byte start code for IDR
    EXPECT_EQ(r[0].data[0], 0x00);
    EXPECT_EQ(r[0].data[1], 0x00);
    EXPECT_EQ(r[0].data[2], 0x00);
    EXPECT_EQ(r[0].data[3], 0x01);
}

TEST_F(RtpDepacketizerTest, FuA_NriPreserved) {
    uint8_t nri = 0x40; // Different NRI
    uint8_t type = 1;

    auto pkt1 = build_rtp_packet(300, 27000, 0x1234, false,
                                  make_fua_start(nri, type, {0x11}));
    auto pkt2 = build_rtp_packet(301, 27000, 0x1234, true,
                                  make_fua_end(nri, type, {0x22}));

    depak.process(pkt1.data(), pkt1.size());
    auto r = depak.process(pkt2.data(), pkt2.size());

    ASSERT_EQ(r.size(), 1u);
    // NAL header after start code should preserve NRI
    uint8_t nal_header = r[0].data[3]; // After 3-byte start code
    EXPECT_EQ(nal_header & 0x60, nri);
    EXPECT_EQ(nal_header & 0x1F, type);
}

// --- Multi-SSRC test ---

TEST_F(RtpDepacketizerTest, MultiSsrc_IndependentReassembly) {
    uint8_t nri = 0x60;
    uint8_t type = 1;

    // SSRC A: start fragment
    auto pktA1 = build_rtp_packet(10, 9000, 0xAAAA, false,
                                   make_fua_start(nri, type, {0x11}));
    // SSRC B: start fragment
    auto pktB1 = build_rtp_packet(20, 18000, 0xBBBB, false,
                                   make_fua_start(nri, type, {0x33}));
    // SSRC A: end fragment
    auto pktA2 = build_rtp_packet(11, 9000, 0xAAAA, true,
                                   make_fua_end(nri, type, {0x22}));
    // SSRC B: end fragment
    auto pktB2 = build_rtp_packet(21, 18000, 0xBBBB, true,
                                   make_fua_end(nri, type, {0x44}));

    EXPECT_TRUE(depak.process(pktA1.data(), pktA1.size()).empty());
    EXPECT_TRUE(depak.process(pktB1.data(), pktB1.size()).empty());

    auto rA = depak.process(pktA2.data(), pktA2.size());
    ASSERT_EQ(rA.size(), 1u);
    EXPECT_EQ(rA[0].rtp_timestamp, 9000u);

    auto rB = depak.process(pktB2.data(), pktB2.size());
    ASSERT_EQ(rB.size(), 1u);
    EXPECT_EQ(rB[0].rtp_timestamp, 18000u);
}

// --- Reset and Stats ---

TEST_F(RtpDepacketizerTest, Reset) {
    uint8_t nri = 0x60;
    uint8_t type = 1;

    // Start a fragment
    auto pkt1 = build_rtp_packet(100, 9000, 0x1234, false,
                                  make_fua_start(nri, type, {0x11}));
    depak.process(pkt1.data(), pkt1.size());

    depak.reset();

    // End fragment after reset should be dropped (no start)
    auto pkt2 = build_rtp_packet(101, 9000, 0x1234, true,
                                  make_fua_end(nri, type, {0x22}));
    auto r = depak.process(pkt2.data(), pkt2.size());
    EXPECT_TRUE(r.empty());
}

TEST_F(RtpDepacketizerTest, Stats) {
    auto payload = make_single_nal(1);
    auto pkt = build_rtp_packet(1, 9000, 0x1234, true, payload);

    EXPECT_EQ(depak.nal_units_output(), 0u);

    depak.process(pkt.data(), pkt.size());
    EXPECT_EQ(depak.nal_units_output(), 1u);

    depak.process(pkt.data(), pkt.size());
    EXPECT_EQ(depak.nal_units_output(), 2u);
}
