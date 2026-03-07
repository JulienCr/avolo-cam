#include <gtest/gtest.h>
#include "access-unit-assembler.h"

using namespace avolocam;

class AccessUnitAssemblerTest : public ::testing::Test {
protected:
    AccessUnitAssembler asm_;

    // Helper: create NAL data with 4-byte start code
    static std::vector<uint8_t> nal_with_sc4(uint8_t type, const std::vector<uint8_t>& body = {0xAA}) {
        std::vector<uint8_t> data = {0x00, 0x00, 0x00, 0x01};
        data.push_back(0x60 | (type & 0x1F)); // NRI=0x60 | type
        data.insert(data.end(), body.begin(), body.end());
        return data;
    }

    // Helper: create NAL data with 3-byte start code
    static std::vector<uint8_t> nal_with_sc3(uint8_t type, const std::vector<uint8_t>& body = {0xAA}) {
        std::vector<uint8_t> data = {0x00, 0x00, 0x01};
        data.push_back(0x60 | (type & 0x1F));
        data.insert(data.end(), body.begin(), body.end());
        return data;
    }
};

// --- Single NAL with marker ---

TEST_F(AccessUnitAssemblerTest, SingleNal_WithMarker) {
    auto nal = nal_with_sc3(1); // non-IDR slice
    auto result = asm_.add_nal(nal, 9000, true);

    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result->rtp_timestamp, 9000u);
    EXPECT_EQ(result->nal_count, 1u);
    EXPECT_FALSE(result->is_idr);
}

TEST_F(AccessUnitAssemblerTest, SingleNal_NoMarker) {
    auto nal = nal_with_sc3(1);
    auto result = asm_.add_nal(nal, 9000, false);

    EXPECT_FALSE(result.has_value());
}

// --- Two NALs same timestamp ---

TEST_F(AccessUnitAssemblerTest, TwoNals_SameTimestamp) {
    auto nal1 = nal_with_sc3(1);
    auto nal2 = nal_with_sc3(1);

    auto r1 = asm_.add_nal(nal1, 9000, false);
    EXPECT_FALSE(r1.has_value());

    auto r2 = asm_.add_nal(nal2, 9000, true);
    ASSERT_TRUE(r2.has_value());
    EXPECT_EQ(r2->nal_count, 2u);
}

// --- SPS + PPS + IDR ---

TEST_F(AccessUnitAssemblerTest, SPS_PPS_IDR) {
    auto sps = nal_with_sc4(7);
    auto pps = nal_with_sc4(8);
    auto idr = nal_with_sc4(5);

    asm_.add_nal(sps, 9000, false);
    asm_.add_nal(pps, 9000, false);
    auto result = asm_.add_nal(idr, 9000, true);

    ASSERT_TRUE(result.has_value());
    EXPECT_TRUE(result->is_idr);
    EXPECT_TRUE(result->has_sps);
    EXPECT_TRUE(result->has_pps);
    EXPECT_EQ(result->nal_count, 3u);
}

// --- Parameter set caching ---

TEST_F(AccessUnitAssemblerTest, HasParameterSets) {
    EXPECT_FALSE(asm_.has_parameter_sets());

    auto sps = nal_with_sc4(7);
    asm_.add_nal(sps, 9000, false);
    EXPECT_FALSE(asm_.has_parameter_sets()); // Only SPS, no PPS

    auto pps = nal_with_sc4(8);
    asm_.add_nal(pps, 9000, true);
    EXPECT_TRUE(asm_.has_parameter_sets());

    // SPS/PPS should be cached
    EXPECT_FALSE(asm_.get_sps().empty());
    EXPECT_FALSE(asm_.get_pps().empty());
}

// --- Different timestamps → separate AUs ---

TEST_F(AccessUnitAssemblerTest, DifferentTimestamps) {
    auto nal1 = nal_with_sc3(1);
    auto nal2 = nal_with_sc3(1);

    auto r1 = asm_.add_nal(nal1, 9000, true);
    auto r2 = asm_.add_nal(nal2, 18000, true);

    ASSERT_TRUE(r1.has_value());
    ASSERT_TRUE(r2.has_value());
    EXPECT_EQ(r1->rtp_timestamp, 9000u);
    EXPECT_EQ(r2->rtp_timestamp, 18000u);
}

// --- Flush ---

TEST_F(AccessUnitAssemblerTest, Flush_WithPending) {
    auto nal = nal_with_sc3(1);
    asm_.add_nal(nal, 9000, false); // No marker, pending

    auto result = asm_.flush();
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result->rtp_timestamp, 9000u);
}

TEST_F(AccessUnitAssemblerTest, Flush_Empty) {
    auto result = asm_.flush();
    EXPECT_FALSE(result.has_value());
}

// --- Reset ---

TEST_F(AccessUnitAssemblerTest, Reset) {
    auto nal = nal_with_sc3(1);
    asm_.add_nal(nal, 9000, false); // Pending

    asm_.reset();

    auto result = asm_.flush();
    EXPECT_FALSE(result.has_value()); // Pending was cleared
}

TEST_F(AccessUnitAssemblerTest, Reset_KeepsCachedParams) {
    auto sps = nal_with_sc4(7);
    auto pps = nal_with_sc4(8);
    asm_.add_nal(sps, 9000, false);
    asm_.add_nal(pps, 9000, true);

    EXPECT_TRUE(asm_.has_parameter_sets());
    asm_.reset();
    // SPS/PPS cache should survive reset
    EXPECT_TRUE(asm_.has_parameter_sets());
}

// --- Cleanup old pending ---

TEST_F(AccessUnitAssemblerTest, CleanupOldPending_Over16) {
    // Add 20 incomplete AUs (no marker)
    for (uint32_t i = 0; i < 20; i++) {
        auto nal = nal_with_sc3(1);
        asm_.add_nal(nal, i * 3000, false);
    }

    // Now complete one to trigger cleanup
    auto nal = nal_with_sc3(1);
    auto result = asm_.add_nal(nal, 100000, true);
    ASSERT_TRUE(result.has_value());

    // After cleanup, flush should return at most MAX_PENDING_AUS remaining
    int count = 0;
    while (asm_.flush().has_value()) count++;
    EXPECT_LE(count, 16);
}

// --- Empty NAL data handling ---

TEST_F(AccessUnitAssemblerTest, TooSmallNal) {
    // NAL with only start code, no actual data
    std::vector<uint8_t> tiny = {0x00, 0x00, 0x01};
    auto result = asm_.add_nal(tiny, 9000, true);
    EXPECT_FALSE(result.has_value());
}

// --- IDR detection ---

TEST_F(AccessUnitAssemblerTest, IdrDetection) {
    auto idr = nal_with_sc4(5);
    auto result = asm_.add_nal(idr, 9000, true);

    ASSERT_TRUE(result.has_value());
    EXPECT_TRUE(result->is_idr);
}

TEST_F(AccessUnitAssemblerTest, NonIdrSlice) {
    auto slice = nal_with_sc3(1);
    auto result = asm_.add_nal(slice, 9000, true);

    ASSERT_TRUE(result.has_value());
    EXPECT_FALSE(result->is_idr);
}

// --- Data concatenation ---

TEST_F(AccessUnitAssemblerTest, DataConcatenation) {
    auto nal1 = nal_with_sc3(1, {0x11, 0x22});
    auto nal2 = nal_with_sc3(1, {0x33, 0x44});

    asm_.add_nal(nal1, 9000, false);
    auto result = asm_.add_nal(nal2, 9000, true);

    ASSERT_TRUE(result.has_value());
    // Data should be nal1 + nal2 concatenated
    EXPECT_EQ(result->data.size(), nal1.size() + nal2.size());
}
