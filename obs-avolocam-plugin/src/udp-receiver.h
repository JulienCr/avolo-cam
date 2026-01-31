/**
 * udp-receiver.h - UDP socket receiver for RTP packets
 */

#pragma once

#include <cstdint>
#include <cstddef>
#include <string>

namespace avolocam {

/**
 * UDP socket wrapper for receiving RTP packets
 */
class UdpReceiver {
public:
    UdpReceiver();
    ~UdpReceiver();

    // Non-copyable
    UdpReceiver(const UdpReceiver&) = delete;
    UdpReceiver& operator=(const UdpReceiver&) = delete;

    /**
     * Bind to a UDP port for listening
     * @param port Port number to bind to
     * @return true on success
     */
    bool bind(uint16_t port);

    /**
     * Receive a UDP packet (blocking with timeout)
     * @param buffer Buffer to receive into
     * @param max_size Maximum bytes to receive
     * @param timeout_ms Timeout in milliseconds (0 = blocking)
     * @return Number of bytes received, 0 on timeout, -1 on error
     */
    int receive(uint8_t *buffer, size_t max_size, int timeout_ms);

    /**
     * Close the socket
     */
    void close();

    /**
     * Check if socket is valid
     */
    bool is_valid() const;

    /**
     * Set expected source IP for filtering
     * Only packets from this IP will be accepted.
     * @param ip The expected source IP address (empty string disables filtering)
     */
    void set_expected_source(const std::string& ip);

private:
    struct Impl;
    Impl *impl_;
};

} // namespace avolocam
