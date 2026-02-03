/**
 * udp-receiver.cpp - Cross-platform UDP socket implementation
 */

#include "udp-receiver.h"

#ifdef _WIN32
    #include <winsock2.h>
    #include <ws2tcpip.h>
    #pragma comment(lib, "ws2_32.lib")
    typedef SOCKET socket_t;
    #define INVALID_SOCKET_VAL INVALID_SOCKET
    #define CLOSE_SOCKET closesocket
#else
    #include <sys/socket.h>
    #include <netinet/in.h>
    #include <arpa/inet.h>
    #include <unistd.h>
    #include <fcntl.h>
    #include <poll.h>
    #include <errno.h>
    typedef int socket_t;
    #define INVALID_SOCKET_VAL (-1)
    #define CLOSE_SOCKET ::close
#endif

#include <cstring>

namespace avolocam {

struct UdpReceiver::Impl {
    socket_t socket = INVALID_SOCKET_VAL;
    uint16_t bound_port = 0;

    // Source IP filtering
    std::string expected_source_ip;
    struct in_addr expected_source_addr;
    bool filter_by_source = false;

#ifdef _WIN32
    static bool winsock_initialized;
    static int winsock_refcount;

    static bool init_winsock() {
        if (!winsock_initialized) {
            WSADATA wsa_data;
            if (WSAStartup(MAKEWORD(2, 2), &wsa_data) != 0) {
                return false;
            }
            winsock_initialized = true;
        }
        winsock_refcount++;
        return true;
    }

    static void cleanup_winsock() {
        if (--winsock_refcount == 0 && winsock_initialized) {
            WSACleanup();
            winsock_initialized = false;
        }
    }
#endif
};

#ifdef _WIN32
bool UdpReceiver::Impl::winsock_initialized = false;
int UdpReceiver::Impl::winsock_refcount = 0;
#endif

UdpReceiver::UdpReceiver() : impl_(new Impl()) {
#ifdef _WIN32
    Impl::init_winsock();
#endif
}

UdpReceiver::~UdpReceiver() {
    close();
#ifdef _WIN32
    Impl::cleanup_winsock();
#endif
    delete impl_;
}

bool UdpReceiver::bind(uint16_t port) {
    if (impl_->socket != INVALID_SOCKET_VAL) {
        close();
    }

    // Create UDP socket
    impl_->socket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (impl_->socket == INVALID_SOCKET_VAL) {
        return false;
    }

    // NOTE: SO_REUSEADDR intentionally NOT set.
    // On Windows, SO_REUSEADDR for UDP allows multiple sockets to bind the same
    // port, causing packet duplication across sources and potential decoder crashes.
    // Without it, bind() fails with EADDRINUSE if the port is already taken,
    // giving an explicit error instead of silent corruption.

    // Increase receive buffer size for high bitrate streams
    int rcvbuf = 4 * 1024 * 1024;  // 4MB
    setsockopt(impl_->socket, SOL_SOCKET, SO_RCVBUF,
               reinterpret_cast<const char*>(&rcvbuf), sizeof(rcvbuf));

    // Bind to port
    struct sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = INADDR_ANY;

    if (::bind(impl_->socket, reinterpret_cast<struct sockaddr*>(&addr),
               sizeof(addr)) < 0) {
        CLOSE_SOCKET(impl_->socket);
        impl_->socket = INVALID_SOCKET_VAL;
        return false;
    }

    impl_->bound_port = port;
    return true;
}

int UdpReceiver::receive(uint8_t *buffer, size_t max_size, int timeout_ms) {
    if (impl_->socket == INVALID_SOCKET_VAL) {
        return -1;
    }

    // Wait for data with timeout
    if (timeout_ms > 0) {
#ifdef _WIN32
        fd_set read_fds;
        FD_ZERO(&read_fds);
        FD_SET(impl_->socket, &read_fds);

        struct timeval tv;
        tv.tv_sec = timeout_ms / 1000;
        tv.tv_usec = (timeout_ms % 1000) * 1000;

        int result = select(0, &read_fds, nullptr, nullptr, &tv);
        if (result <= 0) {
            return result;  // 0 = timeout, -1 = error
        }
#else
        struct pollfd pfd;
        pfd.fd = impl_->socket;
        pfd.events = POLLIN;

        int result = poll(&pfd, 1, timeout_ms);
        if (result <= 0) {
            return result;  // 0 = timeout, -1 = error
        }
#endif
    }

    // Receive the packet
    struct sockaddr_in from_addr;
    socklen_t from_len = sizeof(from_addr);

    int received = recvfrom(impl_->socket,
                            reinterpret_cast<char*>(buffer),
                            static_cast<int>(max_size),
                            0,
                            reinterpret_cast<struct sockaddr*>(&from_addr),
                            &from_len);

    // Validate source IP if filtering is enabled
    if (received > 0 && impl_->filter_by_source) {
        if (from_addr.sin_addr.s_addr != impl_->expected_source_addr.s_addr) {
            // Packet from unexpected source - ignore it
            return 0;  // Treat as timeout
        }
    }

    return received;
}

void UdpReceiver::close() {
    if (impl_->socket != INVALID_SOCKET_VAL) {
        CLOSE_SOCKET(impl_->socket);
        impl_->socket = INVALID_SOCKET_VAL;
        impl_->bound_port = 0;
    }
}

bool UdpReceiver::is_valid() const {
    return impl_->socket != INVALID_SOCKET_VAL;
}

void UdpReceiver::set_expected_source(const std::string& ip) {
    impl_->expected_source_ip = ip;
    impl_->filter_by_source = !ip.empty();
    if (impl_->filter_by_source) {
        inet_pton(AF_INET, ip.c_str(), &impl_->expected_source_addr);
    }
}

} // namespace avolocam
