/**
 * avolocam-receive.cpp - UDP receive loop and packet processing
 *
 * Extracted from avolocam-source.cpp: receive thread, RTP processing, tally.
 */

#include "avolocam-source-data.h"
#include "pipeline-config.h"

namespace avolocam {

void SourceData::receive_loop() {
    uint16_t port = config.camera_port.load();

    // Bind to UDP port
    auto bind_res = pipeline.receiver->bind(port);
    if (!bind_res) {
        ALOG(LOG_ERROR, "Failed to bind to port %d: %s",
             port, source_error_str(bind_res.error));
        bind_result_.store(-1);
        return;
    }

    // Register port in global registry
    {
        std::lock_guard<std::mutex> lock(g_ports_mutex);
        g_bound_ports.insert(port);
    }

    bind_result_.store(1);  // Signal success to start()

    // Log actual receive buffer size for diagnostics
    int actual_rcvbuf = pipeline.receiver->get_actual_rcvbuf();
    if (actual_rcvbuf > 0 && actual_rcvbuf < 2 * 1024 * 1024) {
        ALOG(LOG_WARNING, "UDP receive buffer is only %d bytes (requested 4MB). "
             "This may cause packet drops with multiple cameras.", actual_rcvbuf);
    }

    ALOG(LOG_INFO, "Listening on UDP port %d (rcvbuf=%dKB)",
         port, actual_rcvbuf / 1024);

    std::vector<uint8_t> packet_buffer(2048);

    while (running.load()) {
        // Receive UDP packet with timeout
        // Flash mode: 5ms timeout for fast wakeup; Stable: 100ms
        int recv_timeout = config.flash_mode ? UDP_RECV_TIMEOUT_FLASH_MS : UDP_RECV_TIMEOUT_STABLE_MS;
        int received = pipeline.receiver->receive(packet_buffer.data(),
                                         packet_buffer.size(),
                                         recv_timeout);

        uint64_t now = os_gettime_ns();
        tick_tally(now);

        if (received <= 0) continue;

        frames_received.fetch_add(1, std::memory_order_relaxed);

        if (config.flash_mode) {
            // Flash mode: bypass jitter buffer, feed directly to depacketizer
            process_packet_direct(packet_buffer.data(), received);

            // Drain all remaining packets in the socket (non-blocking)
            while (running.load()) {
                int extra = pipeline.receiver->receive(packet_buffer.data(),
                                              packet_buffer.size(),
                                              0);  // non-blocking
                if (extra <= 0) break;
                frames_received.fetch_add(1, std::memory_order_relaxed);
                process_packet_direct(packet_buffer.data(), extra);
            }
        } else {
            // Stable mode: use jitter buffer for reordering
            pipeline.jitter_buffer->add_packet(packet_buffer.data(), received,
                                      os_gettime_ns());
            process_jitter_buffer();
        }
    }

    // Unregister port from global registry when receive loop exits
    {
        std::lock_guard<std::mutex> lock(g_ports_mutex);
        g_bound_ports.erase(port);
    }

    pipeline.receiver->close();
}

/**
 * Process a raw UDP packet directly (bypassing jitter buffer)
 * Used in flash mode for minimum latency on stable LAN
 */
void SourceData::process_packet_direct(const uint8_t *data, int size) {
    if (size < 12) return;  // Minimum RTP header size

    packet_count++;
    auto nal_units = pipeline.depacketizer->process(data, size);
    process_nal_units(nal_units);
}

void SourceData::process_jitter_buffer() {
    std::vector<uint8_t> packet;
    uint64_t recv_time;

    while (pipeline.jitter_buffer->get_next_packet(packet, recv_time)) {
        packet_count++;
        auto nal_units = pipeline.depacketizer->process(packet.data(), packet.size());
        process_nal_units(nal_units);
    }
}

/**
 * Common NAL unit processing: debug logging, sync check, assembly, queue push.
 * Shared by both flash mode (process_packet_direct) and stable mode (process_jitter_buffer).
 */
void SourceData::process_nal_units(std::vector<NalUnit>& nal_units) {
    total_nals += nal_units.size();

    if (config.debug_mode && packet_count % 500 == 0) {
        ALOG(LOG_DEBUG, "Packets: %d, NALs: %d", packet_count, total_nals);
    }

    for (auto& nal : nal_units) {
        uint8_t nal_type = static_cast<uint8_t>(nal.type);

        if (config.debug_mode && (nal_type == 7 || nal_type == 8 || nal_type == 5)) {
            ALOG(LOG_DEBUG, "NAL type=%d (SPS=7/PPS=8/IDR=5), size=%zu, marker=%d",
                 nal_type, nal.data.size(), nal.marker);
        }

        if (!pipeline.sync_state->can_decode(nal.type, nal.is_idr)) {
            if (config.debug_mode && (nal_type == 7 || nal_type == 8 || nal_type == 5)) {
                ALOG(LOG_DEBUG, "Sync state rejected NAL type=%d", nal_type);
            }
            frames_dropped.fetch_add(1, std::memory_order_relaxed);
            continue;
        }

        auto access_unit = pipeline.assembler->add_nal(
            std::move(nal.data), nal.rtp_timestamp, nal.marker);

        if (access_unit) {
            push_to_decode_queue(std::move(*access_unit));
        }
    }
}

/**
 * Push access unit to decode queue with drop policy
 * If queue is full, drop oldest frame (not the new one)
 */
void SourceData::push_to_decode_queue(AccessUnit&& au) {
    std::lock_guard<std::mutex> lock(decode_queue.mutex);

    if (config.flash_mode && decode_queue.max_size == 1) {
        // Flash mode with queue=1: replace the existing element in-place
        // to avoid the overhead of pop_front + push_back
        if (!decode_queue.queue.empty()) {
            decode_queue.queue.front() = std::move(au);
            decode_queue_drops.fetch_add(1, std::memory_order_relaxed);
        } else {
            decode_queue.queue.push_back(std::move(au));
        }
    } else {
        // Standard mode: drop oldest if queue is full
        if (decode_queue.queue.size() >= decode_queue.max_size) {
            decode_queue.queue.pop_front();
            decode_queue_drops.fetch_add(1, std::memory_order_relaxed);
        }
        decode_queue.queue.push_back(std::move(au));
    }
    decode_queue.cv.notify_one();
}

/**
 * Periodic tally check: polls for state changes and sends heartbeats.
 * Called from receive_loop() on every iteration.
 */
void SourceData::tick_tally(uint64_t now_ns) {
    if (now_ns - tally_timers.last_poll_ns >= TALLY_POLL_INTERVAL_NS) {
        send_tally_state();
        tally_timers.last_poll_ns = now_ns;
    }
    if (now_ns - tally_timers.last_heartbeat_ns >= TALLY_HEARTBEAT_NS) {
        send_tally_heartbeat();
        tally_timers.last_heartbeat_ns = now_ns;
    }
}

void SourceData::send_tally_state() {
    if (!pipeline.ws_client || !pipeline.ws_client->is_connected()) return;
    if (!source) return;

    // obs_source_showing() returns true if the source is visible on the final output (Program)
    // obs_source_active() returns true if the source is active (either Program OR Preview)
    bool is_program = obs_source_showing(source);
    bool is_preview = obs_source_active(source) && !is_program;

    // Only send if state changed
    if (is_program == tally_program.load() && is_preview == tally_preview.load())
        return;

    tally_program.store(is_program);
    tally_preview.store(is_preview);

    char json[128];
    snprintf(json, sizeof(json),
             R"({"op":"tally","program":%s,"preview":%s})",
             is_program ? "true" : "false",
             is_preview ? "true" : "false");

    pipeline.ws_client->send_command(json);

    ALOG(LOG_INFO, "Tally sent: program=%s, preview=%s (ws=%s)",
         is_program ? "true" : "false",
         is_preview ? "true" : "false",
         pipeline.ws_client->is_connected() ? "connected" : "disconnected");
}

// Unconditional tally re-send (guards against lost WebSocket messages).
// Unlike send_tally_state() which only sends on change, this always sends.
void SourceData::send_tally_heartbeat() {
    if (!pipeline.ws_client || !pipeline.ws_client->is_connected()) return;
    if (!source) return;

    char json[128];
    snprintf(json, sizeof(json),
             R"({"op":"tally","program":%s,"preview":%s})",
             tally_program.load() ? "true" : "false",
             tally_preview.load() ? "true" : "false");
    pipeline.ws_client->send_command(json);
}

// Extract SPS and PPS from Annex B formatted data
void SourceData::extract_parameter_sets(const std::vector<uint8_t>& data,
                             std::vector<uint8_t>& sps,
                             std::vector<uint8_t>& pps) {
    sps.clear();
    pps.clear();

    size_t i = 0;
    while (i < data.size()) {
        // Find start code
        size_t start_code_len = 0;
        if (i + 3 <= data.size() && data[i] == 0 && data[i+1] == 0) {
            if (data[i+2] == 1) {
                start_code_len = 3;
            } else if (i + 4 <= data.size() && data[i+2] == 0 && data[i+3] == 1) {
                start_code_len = 4;
            }
        }

        if (start_code_len == 0) {
            i++;
            continue;
        }

        size_t nal_start = i + start_code_len;
        if (nal_start >= data.size()) break;

        // Find end of NAL (next start code or end of data)
        size_t nal_end = data.size();
        for (size_t j = nal_start; j + 2 < data.size(); j++) {
            if (data[j] == 0 && data[j+1] == 0 &&
                (data[j+2] == 1 || (j + 3 < data.size() && data[j+2] == 0 && data[j+3] == 1))) {
                nal_end = j;
                break;
            }
        }

        // Extract NAL type
        uint8_t nal_type = data[nal_start] & 0x1F;

        if (nal_type == 7 && sps.empty()) {
            // SPS - copy without start code
            sps.assign(data.begin() + nal_start, data.begin() + nal_end);
        } else if (nal_type == 8 && pps.empty()) {
            // PPS - copy without start code
            pps.assign(data.begin() + nal_start, data.begin() + nal_end);
        }

        i = nal_end;

        // Early exit if we have both
        if (!sps.empty() && !pps.empty()) break;
    }
}

} // namespace avolocam
