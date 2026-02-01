/**
 * sync-state-machine.cpp - Decoder sync state machine implementation
 */

#include "sync-state-machine.h"

namespace avolocam {

SyncStateMachine::SyncStateMachine() = default;
SyncStateMachine::~SyncStateMachine() = default;

void SyncStateMachine::set_idr_request_callback(IdrRequestCallback callback) {
    idr_request_callback_ = std::move(callback);
}

bool SyncStateMachine::can_decode(NalType nal_type, bool is_idr) {
    SyncState current = state_.load();

    // SPS/PPS are always accepted (parameter sets)
    if (nal_type == NalType::SPS || nal_type == NalType::PPS) {
        return true;
    }

    // AUD and SEI don't affect sync but can be passed through
    if (nal_type == NalType::AUD || nal_type == NalType::SEI) {
        return current == SyncState::SYNC;
    }

    switch (current) {
        case SyncState::SYNC:
            // All frames can be decoded
            return true;

        case SyncState::OUT_OF_SYNC:
        case SyncState::RESYNC:
            // Only IDR can resync us
            if (is_idr) {
                transition_to(SyncState::SYNC);
                consecutive_errors_ = 0;
                resync_count_++;
                return true;
            }
            // Drop non-IDR frames
            frames_dropped_sync_++;
            return false;
    }

    return false;
}

void SyncStateMachine::on_decode_error() {
    consecutive_errors_++;

    if (consecutive_errors_ >= MAX_ERRORS_BEFORE_RESYNC) {
        transition_to(SyncState::OUT_OF_SYNC);
        request_idr();
    }
}

void SyncStateMachine::on_packet_loss(int missing_count) {
    // For significant loss, go out of sync
    if (missing_count >= 3) {
        transition_to(SyncState::OUT_OF_SYNC);
        request_idr();
    }
}

void SyncStateMachine::request_idr() {
    if (idr_request_callback_) {
        idr_request_callback_();
        idr_requests_sent_++;
        transition_to(SyncState::RESYNC);
    }
}

void SyncStateMachine::transition_to(SyncState new_state) {
    state_.store(new_state);
}

} // namespace avolocam
