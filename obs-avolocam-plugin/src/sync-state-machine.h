/**
 * sync-state-machine.h - Decoder synchronization state machine
 *
 * Manages sync state to handle packet loss and stream discontinuities.
 *
 * States:
 *   SYNC       - Decoder is synchronized, all frames can be decoded
 *   OUT_OF_SYNC - Lost sync, dropping frames until IDR
 *   RESYNC     - Received IDR request, waiting for IDR to arrive
 */

#pragma once

#include <atomic>
#include <cstdint>
#include <functional>

#include "rtp-depacketizer.h"

namespace avolocam {

/**
 * Synchronization state
 */
enum class SyncState {
    SYNC,         // Normal decoding
    OUT_OF_SYNC,  // Lost sync, need IDR
    RESYNC,       // IDR requested, waiting
};

/**
 * Callback to request IDR from sender
 */
using IdrRequestCallback = std::function<void()>;

/**
 * Decoder synchronization state machine
 */
class SyncStateMachine {
public:
    SyncStateMachine();
    ~SyncStateMachine();

    /**
     * Set callback to request IDR frame
     */
    void set_idr_request_callback(IdrRequestCallback callback);

    /**
     * Check if a NAL unit can be decoded in current state
     * @param nal_type NAL unit type
     * @param is_idr True if this is an IDR frame
     * @return true if NAL should be decoded
     */
    bool can_decode(NalType nal_type, bool is_idr);

    /**
     * Report decode error (triggers resync)
     */
    void on_decode_error();

    /**
     * Report packet loss detected
     * @param missing_count Number of missing packets
     */
    void on_packet_loss(int missing_count);

    /**
     * Get current state
     */
    SyncState state() const { return state_.load(); }

    /**
     * Get statistics
     */
    uint64_t frames_dropped_sync() const { return frames_dropped_sync_; }
    uint64_t idr_requests_sent() const { return idr_requests_sent_; }
    uint64_t resync_count() const { return resync_count_; }

private:
    std::atomic<SyncState> state_{SyncState::SYNC};  // Start in sync - iOS always sends SPS/PPS before keyframes
    IdrRequestCallback idr_request_callback_;

    // Track consecutive frame issues
    int consecutive_errors_ = 0;
    static constexpr int MAX_ERRORS_BEFORE_RESYNC = 2;

    // Statistics
    uint64_t frames_dropped_sync_ = 0;
    uint64_t idr_requests_sent_ = 0;
    uint64_t resync_count_ = 0;

    void request_idr();
    void transition_to(SyncState new_state);
};

} // namespace avolocam
