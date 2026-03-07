#include <gtest/gtest.h>
#include "timestamp-mapper.h"

using namespace avolocam;

class TimestampMapperTest : public ::testing::Test {
protected:
    TimestampMapper mapper_;

    // Helper: register a frame with typical values
    void register_frame(uint32_t rtp_ts, int64_t capture_ns, int64_t encode_ns,
                        int64_t frame_idx = 0)
    {
        FrameTimingInfo info{};
        info.frame_idx = frame_idx;
        info.rtp_ts = rtp_ts;
        info.capture_ts_ns = capture_ns;
        info.encode_ts_ns = encode_ns;
        mapper_.register_frame_info(info);
    }
};

// --- Basic mapping ---

TEST_F(TimestampMapperTest, BasicLatencyCalculation) {
    // Capture at 100ms, encode done at 105ms (5ms encode)
    register_frame(9000, 100'000'000, 105'000'000);

    // Receive at 115ms local time, no clock offset
    LatencyInfo info = mapper_.get_latency_info(9000, 115'000'000);

    ASSERT_TRUE(info.valid);
    EXPECT_NEAR(info.capture_to_encode_ms, 5.0, 0.01);
    EXPECT_NEAR(info.encode_to_receive_ms, 10.0, 0.01);
    EXPECT_NEAR(info.total_latency_ms, 15.0, 0.01);
}

TEST_F(TimestampMapperTest, CalculateLatency_ReturnsTotal) {
    register_frame(9000, 100'000'000, 105'000'000);
    double latency = mapper_.calculate_latency(9000, 115'000'000);
    EXPECT_NEAR(latency, 15.0, 0.01);
}

TEST_F(TimestampMapperTest, LookupMiss_ReturnsInvalid) {
    // No frames registered
    LatencyInfo info = mapper_.get_latency_info(9000, 100'000'000);
    EXPECT_FALSE(info.valid);

    double latency = mapper_.calculate_latency(9000, 100'000'000);
    EXPECT_DOUBLE_EQ(latency, -1.0);
}

// --- Clock offset ---

TEST_F(TimestampMapperTest, ClockOffset) {
    mapper_.set_clock_offset(10'000'000); // local is 10ms ahead of remote

    register_frame(9000, 100'000'000, 105'000'000);

    // Receive at 120ms local. Adjusted = 120 - 10 = 110ms.
    // Network = 110 - 105 = 5ms
    LatencyInfo info = mapper_.get_latency_info(9000, 120'000'000);

    ASSERT_TRUE(info.valid);
    EXPECT_NEAR(info.encode_to_receive_ms, 5.0, 0.01);
    EXPECT_NEAR(info.total_latency_ms, 10.0, 0.01);
}

TEST_F(TimestampMapperTest, GetSetClockOffset) {
    EXPECT_EQ(mapper_.get_clock_offset(), 0);
    mapper_.set_clock_offset(42);
    EXPECT_EQ(mapper_.get_clock_offset(), 42);
}

// --- Negative network latency clamp ---

TEST_F(TimestampMapperTest, NegativeNetworkLatency_Clamped) {
    // encode_ts is 200ms, but receive time is 190ms (clock drift / bad offset)
    register_frame(9000, 100'000'000, 200'000'000);

    LatencyInfo info = mapper_.get_latency_info(9000, 190'000'000);
    ASSERT_TRUE(info.valid);
    // Should clamp to 1ms minimum
    EXPECT_NEAR(info.encode_to_receive_ms, 1.0, 0.01);
}

// --- Statistics ---

TEST_F(TimestampMapperTest, Statistics) {
    EXPECT_EQ(mapper_.total_mappings_added(), 0u);
    EXPECT_EQ(mapper_.total_lookups(), 0u);
    EXPECT_EQ(mapper_.lookup_hits(), 0u);
    EXPECT_EQ(mapper_.lookup_misses(), 0u);

    register_frame(9000, 100'000'000, 105'000'000);
    EXPECT_EQ(mapper_.total_mappings_added(), 1u);

    mapper_.calculate_latency(9000, 115'000'000); // hit
    mapper_.calculate_latency(99999, 115'000'000); // miss (far away)

    EXPECT_EQ(mapper_.total_lookups(), 2u);
    EXPECT_EQ(mapper_.lookup_hits(), 1u);
    EXPECT_EQ(mapper_.lookup_misses(), 1u);
}

// --- Mapping count and reset ---

TEST_F(TimestampMapperTest, MappingCount) {
    EXPECT_EQ(mapper_.mapping_count(), 0u);
    register_frame(9000, 0, 0);
    register_frame(18000, 0, 0);
    EXPECT_EQ(mapper_.mapping_count(), 2u);
}

TEST_F(TimestampMapperTest, Reset_ClearsAll) {
    register_frame(9000, 100'000'000, 105'000'000);
    EXPECT_EQ(mapper_.mapping_count(), 1u);

    mapper_.reset();
    EXPECT_EQ(mapper_.mapping_count(), 0u);

    LatencyInfo info = mapper_.get_latency_info(9000, 115'000'000);
    EXPECT_FALSE(info.valid);
}

// --- Capacity limit (MAX_ENTRIES=256) ---

TEST_F(TimestampMapperTest, EvictsOldEntries_WhenFull) {
    // Fill to capacity and beyond
    for (uint32_t i = 0; i < 300; i++) {
        register_frame(i * 3000, 0, 0, i);
    }
    // Should have pruned, staying at or below 256
    EXPECT_LE(mapper_.mapping_count(), 256u);
}

// --- Wraparound at 2^32 ---

TEST_F(TimestampMapperTest, Wraparound_BasicLookup) {
    // Register near max uint32
    uint32_t near_max = 0xFFFFFF00;
    register_frame(near_max, 100'000'000, 105'000'000);

    LatencyInfo info = mapper_.get_latency_info(near_max, 115'000'000);
    ASSERT_TRUE(info.valid);
    EXPECT_NEAR(info.total_latency_ms, 15.0, 0.01);
}

TEST_F(TimestampMapperTest, Cleanup_HandlesWraparound) {
    // Entry near max, current wrapped around past zero
    uint32_t old_ts = 0xFFFFF000;
    uint32_t current_ts = 0x00100000; // Wrapped around, ~1M ticks ahead

    register_frame(old_ts, 0, 0);
    EXPECT_EQ(mapper_.mapping_count(), 1u);

    mapper_.cleanup_old_entries(current_ts);
    // The old entry should be cleaned up (>450000 ticks old across wrap)
    EXPECT_EQ(mapper_.mapping_count(), 0u);
}

// --- Edge cases ---

TEST_F(TimestampMapperTest, ZeroTimestamp) {
    register_frame(0, 50'000'000, 55'000'000);

    LatencyInfo info = mapper_.get_latency_info(0, 65'000'000);
    ASSERT_TRUE(info.valid);
    EXPECT_NEAR(info.total_latency_ms, 15.0, 0.01);
}

TEST_F(TimestampMapperTest, MaxTimestamp) {
    register_frame(UINT32_MAX, 50'000'000, 55'000'000);

    LatencyInfo info = mapper_.get_latency_info(UINT32_MAX, 65'000'000);
    ASSERT_TRUE(info.valid);
    EXPECT_NEAR(info.total_latency_ms, 15.0, 0.01);
}

TEST_F(TimestampMapperTest, NearbyTimestamp_FuzzyMatch) {
    register_frame(9000, 100'000'000, 105'000'000);

    // Lookup with a slightly different timestamp (within 90000 ticks = 1s)
    LatencyInfo info = mapper_.get_latency_info(9050, 115'000'000);
    ASSERT_TRUE(info.valid);
    EXPECT_NEAR(info.total_latency_ms, 15.0, 0.01);
}

TEST_F(TimestampMapperTest, FarTimestamp_NoFuzzyMatch) {
    register_frame(9000, 100'000'000, 105'000'000);

    // Lookup with timestamp >90000 ticks away
    LatencyInfo info = mapper_.get_latency_info(9000 + 100000, 115'000'000);
    EXPECT_FALSE(info.valid);
}

// --- Duplicate timestamp overwrites ---

TEST_F(TimestampMapperTest, DuplicateTimestamp_Overwrites) {
    register_frame(9000, 100'000'000, 105'000'000);
    register_frame(9000, 200'000'000, 210'000'000); // overwrite

    LatencyInfo info = mapper_.get_latency_info(9000, 220'000'000);
    ASSERT_TRUE(info.valid);
    EXPECT_NEAR(info.capture_to_encode_ms, 10.0, 0.01); // 210-200
}
