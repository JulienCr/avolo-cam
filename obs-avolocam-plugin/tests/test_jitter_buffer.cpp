#include <gtest/gtest.h>
#include "jitter-buffer.h"
#include "rtp_test_helpers.h"

using namespace avolocam;
using namespace test_helpers;

class JitterBufferTest : public ::testing::Test {
protected:
    // 50ms stable mode buffer
    JitterBuffer stable_buf{50};
    // 8ms ultra-low buffer
    JitterBuffer ultra_buf{8};
};

// --- Empty buffer ---

TEST_F(JitterBufferTest, EmptyBuffer_GetReturnsFalse) {
    std::vector<uint8_t> data;
    uint64_t recv_time;
    EXPECT_FALSE(stable_buf.get_next_packet(data, recv_time));
}

TEST_F(JitterBufferTest, EmptyBuffer_SizeIsZero) {
    EXPECT_EQ(stable_buf.size(), 0u);
}

// --- Single packet output ---

TEST_F(JitterBufferTest, SinglePacket_LowLatencyMode) {
    // Low latency = threshold 1, should output immediately
    stable_buf.set_low_latency_mode(true);
    auto pkt = build_rtp_packet(1, 9000, 0x1234, true, {0x61, 0xAA});
    stable_buf.add_packet(pkt.data(), pkt.size(), 1000000);

    std::vector<uint8_t> out;
    uint64_t recv_time;
    EXPECT_TRUE(stable_buf.get_next_packet(out, recv_time));
    EXPECT_EQ(out, pkt);
    EXPECT_EQ(recv_time, 1000000u);
}

TEST_F(JitterBufferTest, SinglePacket_StableMode) {
    // Stable mode = threshold 2, single packet should NOT be output
    stable_buf.set_low_latency_mode(false);
    auto pkt = build_rtp_packet(1, 9000, 0x1234, true, {0x61, 0xAA});
    stable_buf.add_packet(pkt.data(), pkt.size(), 1000000);

    std::vector<uint8_t> out;
    uint64_t recv_time;
    EXPECT_FALSE(stable_buf.get_next_packet(out, recv_time));
}

TEST_F(JitterBufferTest, UltraLowBuffer_ThresholdOne) {
    // max_delay <= 8 forces threshold 1 regardless of mode
    ultra_buf.set_low_latency_mode(false);
    auto pkt = build_rtp_packet(1, 9000, 0x1234, true, {0x61, 0xAA});
    ultra_buf.add_packet(pkt.data(), pkt.size(), 1000000);

    std::vector<uint8_t> out;
    uint64_t recv_time;
    EXPECT_TRUE(ultra_buf.get_next_packet(out, recv_time));
}

// --- Ordering ---

TEST_F(JitterBufferTest, InOrder) {
    stable_buf.set_low_latency_mode(true);
    auto pkt1 = build_rtp_packet(1, 9000, 0x1234, false, {0x61, 0x11});
    auto pkt2 = build_rtp_packet(2, 9000, 0x1234, true, {0x61, 0x22});

    stable_buf.add_packet(pkt1.data(), pkt1.size(), 1000000);
    stable_buf.add_packet(pkt2.data(), pkt2.size(), 2000000);

    std::vector<uint8_t> out;
    uint64_t recv;
    ASSERT_TRUE(stable_buf.get_next_packet(out, recv));
    EXPECT_EQ(out, pkt1);
    ASSERT_TRUE(stable_buf.get_next_packet(out, recv));
    EXPECT_EQ(out, pkt2);
}

TEST_F(JitterBufferTest, OutOfOrder) {
    stable_buf.set_low_latency_mode(true);
    auto pkt1 = build_rtp_packet(1, 9000, 0x1234, false, {0x61, 0x11});
    auto pkt2 = build_rtp_packet(2, 9000, 0x1234, true, {0x61, 0x22});

    // Add in reverse order
    stable_buf.add_packet(pkt2.data(), pkt2.size(), 2000000);
    stable_buf.add_packet(pkt1.data(), pkt1.size(), 1000000);

    std::vector<uint8_t> out;
    uint64_t recv;
    // Should come out in sequence order
    ASSERT_TRUE(stable_buf.get_next_packet(out, recv));
    EXPECT_EQ(out, pkt1);
    ASSERT_TRUE(stable_buf.get_next_packet(out, recv));
    EXPECT_EQ(out, pkt2);
}

TEST_F(JitterBufferTest, SeqWrap) {
    stable_buf.set_low_latency_mode(true);
    auto pkt_before = build_rtp_packet(65535, 9000, 0x1234, false, {0x61, 0x11});
    auto pkt_after = build_rtp_packet(0, 9000, 0x1234, true, {0x61, 0x22});

    // Add wrapping seq out of order
    stable_buf.add_packet(pkt_after.data(), pkt_after.size(), 2000000);
    stable_buf.add_packet(pkt_before.data(), pkt_before.size(), 1000000);

    std::vector<uint8_t> out;
    uint64_t recv;
    ASSERT_TRUE(stable_buf.get_next_packet(out, recv));
    EXPECT_EQ(out, pkt_before);
    ASSERT_TRUE(stable_buf.get_next_packet(out, recv));
    EXPECT_EQ(out, pkt_after);
}

// --- Late packet drop ---

TEST_F(JitterBufferTest, LatePacketDropped) {
    stable_buf.set_low_latency_mode(true);
    uint64_t base_ns = 1000000000ULL; // 1 second

    // Add many packets spread over a long time
    for (int i = 0; i < 10; i++) {
        auto pkt = build_rtp_packet(static_cast<uint16_t>(i), 9000 + i * 3000, 0x1234,
                                     false, {0x61, static_cast<uint8_t>(i)});
        // Each 200ms apart (way more than 2x max_delay for 50ms buffer)
        stable_buf.add_packet(pkt.data(), pkt.size(), base_ns + i * 200000000ULL);
    }

    // Some old packets should have been dropped
    EXPECT_GT(stable_buf.packets_dropped(), 0u);
}

// --- Clear ---

TEST_F(JitterBufferTest, Clear) {
    stable_buf.set_low_latency_mode(true);
    auto pkt = build_rtp_packet(1, 9000, 0x1234, true, {0x61, 0xAA});
    stable_buf.add_packet(pkt.data(), pkt.size(), 1000000);

    EXPECT_EQ(stable_buf.size(), 1u);
    stable_buf.clear();
    EXPECT_EQ(stable_buf.size(), 0u);
    EXPECT_EQ(stable_buf.packets_received(), 0u);
}

// --- Fill level ---

TEST_F(JitterBufferTest, FillLevel) {
    stable_buf.set_low_latency_mode(false);
    auto pkt1 = build_rtp_packet(1, 9000, 0x1234, false, {0x61, 0x11});
    auto pkt2 = build_rtp_packet(2, 9000, 0x1234, true, {0x61, 0x22});

    // 10ms apart
    stable_buf.add_packet(pkt1.data(), pkt1.size(), 1000000);
    stable_buf.add_packet(pkt2.data(), pkt2.size(), 11000000);

    double fill = stable_buf.fill_level_ms();
    EXPECT_NEAR(fill, 10.0, 0.01);
}

TEST_F(JitterBufferTest, FillLevel_SinglePacket) {
    auto pkt = build_rtp_packet(1, 9000, 0x1234, true, {0x61, 0xAA});
    stable_buf.add_packet(pkt.data(), pkt.size(), 1000000);
    EXPECT_EQ(stable_buf.fill_level_ms(), 0.0);
}

// --- Stats ---

TEST_F(JitterBufferTest, Stats) {
    auto pkt = build_rtp_packet(1, 9000, 0x1234, true, {0x61, 0xAA});

    EXPECT_EQ(stable_buf.packets_received(), 0u);
    stable_buf.add_packet(pkt.data(), pkt.size(), 1000000);
    EXPECT_EQ(stable_buf.packets_received(), 1u);
}

// --- Mode toggle ---

TEST_F(JitterBufferTest, SetLowLatencyMode) {
    EXPECT_TRUE(stable_buf.low_latency_mode()); // Default on Windows

    stable_buf.set_low_latency_mode(false);
    EXPECT_FALSE(stable_buf.low_latency_mode());

    stable_buf.set_low_latency_mode(true);
    EXPECT_TRUE(stable_buf.low_latency_mode());
}

// --- Min RTP size rejection ---

TEST_F(JitterBufferTest, TooSmallPacket) {
    uint8_t tiny[] = {0x80, 0x60};
    stable_buf.add_packet(tiny, 2, 1000000);
    EXPECT_EQ(stable_buf.size(), 0u);
    EXPECT_EQ(stable_buf.packets_received(), 0u);
}
