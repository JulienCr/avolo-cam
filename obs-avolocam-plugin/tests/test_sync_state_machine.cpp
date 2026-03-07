#include <gtest/gtest.h>
#include "sync-state-machine.h"

using namespace avolocam;

class SyncStateMachineTest : public ::testing::Test {
protected:
    SyncStateMachine sm;
    int idr_request_count = 0;

    void SetUp() override {
        sm.set_idr_request_callback([this]() { idr_request_count++; });
    }
};

// --- Initial state ---

TEST_F(SyncStateMachineTest, InitialState_IsSync) {
    EXPECT_EQ(sm.state(), SyncState::SYNC);
}

// --- can_decode gating by NAL type ---

TEST_F(SyncStateMachineTest, CanDecode_Slice_InSync) {
    EXPECT_TRUE(sm.can_decode(NalType::SLICE_NON_IDR, false));
}

TEST_F(SyncStateMachineTest, CanDecode_IDR_InSync) {
    EXPECT_TRUE(sm.can_decode(NalType::SLICE_IDR, true));
}

TEST_F(SyncStateMachineTest, CanDecode_SPS_AlwaysTrue) {
    EXPECT_TRUE(sm.can_decode(NalType::SPS, false));

    // Even out of sync, SPS should be accepted
    sm.on_decode_error();
    sm.on_decode_error(); // → OUT_OF_SYNC
    EXPECT_TRUE(sm.can_decode(NalType::SPS, false));
}

TEST_F(SyncStateMachineTest, CanDecode_PPS_AlwaysTrue) {
    EXPECT_TRUE(sm.can_decode(NalType::PPS, false));

    sm.on_decode_error();
    sm.on_decode_error();
    EXPECT_TRUE(sm.can_decode(NalType::PPS, false));
}

TEST_F(SyncStateMachineTest, CanDecode_AUD_OnlyInSync) {
    EXPECT_TRUE(sm.can_decode(NalType::AUD, false));

    sm.on_decode_error();
    sm.on_decode_error();
    EXPECT_FALSE(sm.can_decode(NalType::AUD, false));
}

TEST_F(SyncStateMachineTest, CanDecode_SEI_OnlyInSync) {
    EXPECT_TRUE(sm.can_decode(NalType::SEI, false));

    sm.on_decode_error();
    sm.on_decode_error();
    EXPECT_FALSE(sm.can_decode(NalType::SEI, false));
}

// --- Error handling and state transitions ---

TEST_F(SyncStateMachineTest, SingleError_StaysSync) {
    sm.on_decode_error();
    EXPECT_EQ(sm.state(), SyncState::SYNC);
}

TEST_F(SyncStateMachineTest, TwoErrors_GoesOutOfSync) {
    sm.on_decode_error();
    sm.on_decode_error();
    // With callback: OUT_OF_SYNC → request_idr → RESYNC
    EXPECT_EQ(sm.state(), SyncState::RESYNC);
    EXPECT_EQ(idr_request_count, 1);
}

// --- Packet loss ---

TEST_F(SyncStateMachineTest, PacketLoss_LessThan3_StaysSync) {
    sm.on_packet_loss(2);
    EXPECT_EQ(sm.state(), SyncState::SYNC);
}

TEST_F(SyncStateMachineTest, PacketLoss_3OrMore_GoesOutOfSync) {
    sm.on_packet_loss(3);
    EXPECT_EQ(sm.state(), SyncState::RESYNC);
    EXPECT_EQ(idr_request_count, 1);
}

TEST_F(SyncStateMachineTest, PacketLoss_Large) {
    sm.on_packet_loss(50);
    EXPECT_EQ(sm.state(), SyncState::RESYNC);
}

// --- Out of sync behavior ---

TEST_F(SyncStateMachineTest, OutOfSync_RejectsNonIdr) {
    sm.on_packet_loss(5); // → RESYNC

    EXPECT_FALSE(sm.can_decode(NalType::SLICE_NON_IDR, false));
    EXPECT_GT(sm.frames_dropped_sync(), 0u);
}

TEST_F(SyncStateMachineTest, OutOfSync_AcceptsIdr) {
    sm.on_packet_loss(5); // → RESYNC

    EXPECT_TRUE(sm.can_decode(NalType::SLICE_IDR, true));
    EXPECT_EQ(sm.state(), SyncState::SYNC);
}

// --- Resync ---

TEST_F(SyncStateMachineTest, Resync_ResetsErrorCount) {
    // Go out of sync via errors
    sm.on_decode_error();
    sm.on_decode_error(); // → RESYNC

    // Resync via IDR
    sm.can_decode(NalType::SLICE_IDR, true); // → SYNC

    // Now single error should not trigger out of sync again
    sm.on_decode_error();
    EXPECT_EQ(sm.state(), SyncState::SYNC);
}

// --- Statistics ---

TEST_F(SyncStateMachineTest, FramesDroppedSync) {
    sm.on_packet_loss(5); // → RESYNC
    EXPECT_EQ(sm.frames_dropped_sync(), 0u);

    sm.can_decode(NalType::SLICE_NON_IDR, false); // Dropped
    EXPECT_EQ(sm.frames_dropped_sync(), 1u);

    sm.can_decode(NalType::SLICE_NON_IDR, false); // Dropped
    EXPECT_EQ(sm.frames_dropped_sync(), 2u);
}

TEST_F(SyncStateMachineTest, ResyncCount) {
    EXPECT_EQ(sm.resync_count(), 0u);

    sm.on_packet_loss(5); // → RESYNC
    sm.can_decode(NalType::SLICE_IDR, true); // → SYNC (resync)
    EXPECT_EQ(sm.resync_count(), 1u);

    sm.on_packet_loss(5); // → RESYNC
    sm.can_decode(NalType::SLICE_IDR, true); // → SYNC (resync)
    EXPECT_EQ(sm.resync_count(), 2u);
}

TEST_F(SyncStateMachineTest, IdrRequestsSent) {
    EXPECT_EQ(sm.idr_requests_sent(), 0u);

    sm.on_packet_loss(5);
    EXPECT_EQ(sm.idr_requests_sent(), 1u);

    sm.can_decode(NalType::SLICE_IDR, true); // resync
    sm.on_decode_error();
    sm.on_decode_error();
    EXPECT_EQ(sm.idr_requests_sent(), 2u);
}

// --- No callback behavior ---

TEST(SyncStateMachineNoCallbackTest, NoCallback_GoesToOutOfSync) {
    SyncStateMachine sm_no_cb; // No callback set

    sm_no_cb.on_decode_error();
    sm_no_cb.on_decode_error();

    // Without callback, should go OUT_OF_SYNC but NOT RESYNC
    EXPECT_EQ(sm_no_cb.state(), SyncState::OUT_OF_SYNC);
}

TEST(SyncStateMachineNoCallbackTest, NoCallback_PacketLoss) {
    SyncStateMachine sm_no_cb;

    sm_no_cb.on_packet_loss(5);
    EXPECT_EQ(sm_no_cb.state(), SyncState::OUT_OF_SYNC);
}

// --- Resync from OUT_OF_SYNC (without callback) ---

TEST(SyncStateMachineNoCallbackTest, OutOfSync_IdrResyncs) {
    SyncStateMachine sm_no_cb;

    sm_no_cb.on_packet_loss(5);
    EXPECT_EQ(sm_no_cb.state(), SyncState::OUT_OF_SYNC);

    EXPECT_TRUE(sm_no_cb.can_decode(NalType::SLICE_IDR, true));
    EXPECT_EQ(sm_no_cb.state(), SyncState::SYNC);
}
