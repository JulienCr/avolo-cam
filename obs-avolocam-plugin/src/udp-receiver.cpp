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

    // Allow address reuse
    int reuse = 1;
    setsockopt(impl_->socket, SOL_SOCKET, SO_REUSEADDR,
               reinterpret_cast<const char*>(&reuse), sizeof(reuse));

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

} // namespace avolocam
