/**
 * mdns-discovery.cpp - Cross-platform mDNS discovery implementation
 *
 * Platform-specific implementations:
 * - macOS: Uses CFNetServices / NSNetServiceBrowser
 * - Windows: Uses dns-sd.dll (Bonjour for Windows SDK)
 * - Linux: Uses Avahi client API (not implemented yet)
 */

#include "mdns-discovery.h"
#include <obs-module.h>
#include <util/platform.h>
#include <mutex>
#include <thread>
#include <atomic>
#include <algorithm>

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <CFNetwork/CFNetServices.h>
#include <dns_sd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#elif defined(_WIN32) && !defined(NO_MDNS_DISCOVERY)
#include <winsock2.h>
#include <ws2tcpip.h>
#include <dns_sd.h>
#pragma comment(lib, "dnssd.lib")
#pragma comment(lib, "ws2_32.lib")
#elif defined(_WIN32)
// Windows without Bonjour SDK - mDNS discovery disabled
#include <winsock2.h>
#include <ws2tcpip.h>
#endif

namespace avolocam {

// Service type for AvoCam cameras
static const char *SERVICE_TYPE = "_avolocam._tcp";
static const char *SERVICE_DOMAIN = "local.";

/**
 * Platform-independent discovered service info
 */
struct ServiceInfo {
    std::string name;
    std::string host;
    uint16_t port;
    std::map<std::string, std::string> txt;
    bool resolved;
};

/**
 * Implementation struct
 */
struct MdnsDiscovery::Impl {
    mutable std::mutex mutex_;
    std::map<std::string, DiscoveredCamera> cameras_;
    CameraDiscoveryCallback callback_;
    std::atomic<bool> running_{false};

#ifdef __APPLE__
    DNSServiceRef browse_ref_ = nullptr;
    std::map<std::string, DNSServiceRef> resolve_refs_;
    std::thread run_loop_thread_;
    CFRunLoopRef run_loop_ = nullptr;
#elif defined(_WIN32) && !defined(NO_MDNS_DISCOVERY)
    DNSServiceRef browse_ref_ = nullptr;
    std::map<std::string, DNSServiceRef> resolve_refs_;
    std::thread event_thread_;
    HANDLE stop_event_ = nullptr;
#endif

    Impl() = default;

    ~Impl() {
        stop();
    }

    bool start(CameraDiscoveryCallback callback) {
        if (running_.load()) return true;

        callback_ = std::move(callback);

#ifdef __APPLE__
        return start_macos();
#elif defined(_WIN32) && !defined(NO_MDNS_DISCOVERY)
        return start_windows();
#else
        blog(LOG_WARNING, "[avolocam] mDNS discovery not available (Bonjour SDK not installed or platform not supported)");
        blog(LOG_INFO, "[avolocam] Use manual camera entry via IP address instead");
        return false;
#endif
    }

    void stop() {
        if (!running_.load()) return;

        running_.store(false);

#ifdef __APPLE__
        stop_macos();
#elif defined(_WIN32) && !defined(NO_MDNS_DISCOVERY)
        stop_windows();
#endif

        std::lock_guard<std::mutex> lock(mutex_);
        cameras_.clear();
    }

#ifdef __APPLE__
    // macOS implementation using dns_sd.h API

    bool start_macos() {
        DNSServiceErrorType err = DNSServiceBrowse(
            &browse_ref_,
            0,                          // flags
            kDNSServiceInterfaceIndexAny,
            SERVICE_TYPE,
            SERVICE_DOMAIN,
            browse_callback,
            this);

        if (err != kDNSServiceErr_NoError) {
            blog(LOG_ERROR, "[avolocam] DNSServiceBrowse failed: %d", err);
            return false;
        }

        running_.store(true);

        // Create thread to process events
        run_loop_thread_ = std::thread([this]() {
            int fd = DNSServiceRefSockFD(browse_ref_);
            while (running_.load()) {
                fd_set read_fds;
                FD_ZERO(&read_fds);
                FD_SET(fd, &read_fds);

                struct timeval tv;
                tv.tv_sec = 0;
                tv.tv_usec = 100000; // 100ms timeout

                int result = select(fd + 1, &read_fds, nullptr, nullptr, &tv);
                if (result > 0 && FD_ISSET(fd, &read_fds)) {
                    DNSServiceProcessResult(browse_ref_);
                }
            }
        });

        blog(LOG_INFO, "[avolocam] mDNS discovery started (macOS)");
        return true;
    }

    void stop_macos() {
        if (run_loop_thread_.joinable()) {
            run_loop_thread_.join();
        }

        // Clean up resolve refs
        for (auto &pair : resolve_refs_) {
            DNSServiceRefDeallocate(pair.second);
        }
        resolve_refs_.clear();

        if (browse_ref_) {
            DNSServiceRefDeallocate(browse_ref_);
            browse_ref_ = nullptr;
        }
    }

    static void DNSSD_API browse_callback(
        DNSServiceRef sdRef,
        DNSServiceFlags flags,
        uint32_t interfaceIndex,
        DNSServiceErrorType errorCode,
        const char *serviceName,
        const char *regtype,
        const char *replyDomain,
        void *context)
    {
        (void)sdRef;
        (void)regtype;
        auto *impl = static_cast<Impl*>(context);

        if (errorCode != kDNSServiceErr_NoError) {
            blog(LOG_WARNING, "[avolocam] Browse callback error: %d", errorCode);
            return;
        }

        std::string name = serviceName;

        if (flags & kDNSServiceFlagsAdd) {
            blog(LOG_INFO, "[avolocam] Discovered camera: %s", serviceName);
            impl->resolve_service(name, interfaceIndex, replyDomain);
        } else {
            blog(LOG_INFO, "[avolocam] Camera removed: %s", serviceName);
            impl->remove_camera(name);
        }
    }

    void resolve_service(const std::string &name, uint32_t interface_index,
                         const std::string &domain) {
        DNSServiceRef resolve_ref = nullptr;

        DNSServiceErrorType err = DNSServiceResolve(
            &resolve_ref,
            0,
            interface_index,
            name.c_str(),
            SERVICE_TYPE,
            domain.c_str(),
            resolve_callback,
            this);

        if (err != kDNSServiceErr_NoError) {
            blog(LOG_ERROR, "[avolocam] DNSServiceResolve failed: %d", err);
            return;
        }

        // Store resolve ref
        resolve_refs_[name] = resolve_ref;

        // Process resolve in separate thread
        std::thread([resolve_ref, this]() {
            int fd = DNSServiceRefSockFD(resolve_ref);
            fd_set read_fds;
            FD_ZERO(&read_fds);
            FD_SET(fd, &read_fds);

            struct timeval tv;
            tv.tv_sec = 5; // 5 second timeout for resolve

            int result = select(fd + 1, &read_fds, nullptr, nullptr, &tv);
            if (result > 0) {
                DNSServiceProcessResult(resolve_ref);
            }
        }).detach();
    }

    static void DNSSD_API resolve_callback(
        DNSServiceRef sdRef,
        DNSServiceFlags flags,
        uint32_t interfaceIndex,
        DNSServiceErrorType errorCode,
        const char *fullname,
        const char *hosttarget,
        uint16_t port,
        uint16_t txtLen,
        const unsigned char *txtRecord,
        void *context)
    {
        (void)sdRef;
        (void)flags;
        (void)fullname;
        auto *impl = static_cast<Impl*>(context);

        if (errorCode != kDNSServiceErr_NoError) {
            blog(LOG_WARNING, "[avolocam] Resolve callback error: %d", errorCode);
            return;
        }

        // Parse TXT records
        std::map<std::string, std::string> txt;
        parse_txt_records(txtRecord, txtLen, txt);

        // Now resolve hostname to IP
        impl->resolve_host(fullname, hosttarget, ntohs(port), txt, interfaceIndex);
    }

    void resolve_host(const std::string &fullname, const std::string &hostname,
                      uint16_t port, const std::map<std::string, std::string> &txt,
                      uint32_t interface_index) {
        // Extract service name from fullname
        std::string name = fullname;
        size_t pos = name.find("._avolocam");
        if (pos != std::string::npos) {
            name = name.substr(0, pos);
        }

        DNSServiceRef getaddr_ref = nullptr;

        // Store context for callback
        struct GetAddrContext {
            Impl *impl;
            std::string name;
            uint16_t port;
            std::map<std::string, std::string> txt;
        };

        auto *ctx = new GetAddrContext{this, name, port, txt};

        DNSServiceErrorType err = DNSServiceGetAddrInfo(
            &getaddr_ref,
            0,
            interface_index,
            kDNSServiceProtocol_IPv4,
            hostname.c_str(),
            getaddr_callback,
            ctx);

        if (err != kDNSServiceErr_NoError) {
            blog(LOG_ERROR, "[avolocam] DNSServiceGetAddrInfo failed: %d", err);
            delete ctx;
            return;
        }

        // Process in thread
        std::thread([getaddr_ref, ctx]() {
            int fd = DNSServiceRefSockFD(getaddr_ref);
            fd_set read_fds;
            FD_ZERO(&read_fds);
            FD_SET(fd, &read_fds);

            struct timeval tv;
            tv.tv_sec = 5;

            int result = select(fd + 1, &read_fds, nullptr, nullptr, &tv);
            if (result > 0) {
                DNSServiceProcessResult(getaddr_ref);
            }

            DNSServiceRefDeallocate(getaddr_ref);
            delete ctx;
        }).detach();
    }

    static void DNSSD_API getaddr_callback(
        DNSServiceRef sdRef,
        DNSServiceFlags flags,
        uint32_t interfaceIndex,
        DNSServiceErrorType errorCode,
        const char *hostname,
        const struct sockaddr *address,
        uint32_t ttl,
        void *context)
    {
        (void)sdRef;
        (void)flags;
        (void)interfaceIndex;
        (void)hostname;
        (void)ttl;

        struct GetAddrContext {
            Impl *impl;
            std::string name;
            uint16_t port;
            std::map<std::string, std::string> txt;
        };
        auto *ctx = static_cast<GetAddrContext*>(context);

        if (errorCode != kDNSServiceErr_NoError) {
            return;
        }

        if (address->sa_family != AF_INET) {
            return;
        }

        const struct sockaddr_in *addr_in = (const struct sockaddr_in *)address;
        char ip_str[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &addr_in->sin_addr, ip_str, sizeof(ip_str));

        ctx->impl->add_camera(ctx->name, ip_str, ctx->port, ctx->txt);
    }

    static void parse_txt_records(const unsigned char *txt, uint16_t len,
                                   std::map<std::string, std::string> &out) {
        uint16_t pos = 0;
        while (pos < len) {
            uint8_t record_len = txt[pos++];
            if (pos + record_len > len) break;

            std::string record((const char *)&txt[pos], record_len);
            pos += record_len;

            size_t eq = record.find('=');
            if (eq != std::string::npos) {
                out[record.substr(0, eq)] = record.substr(eq + 1);
            }
        }
    }

#elif defined(_WIN32) && !defined(NO_MDNS_DISCOVERY)
    // Windows implementation using Bonjour SDK

    bool start_windows() {
        // Initialize Winsock
        WSADATA wsa_data;
        WSAStartup(MAKEWORD(2, 2), &wsa_data);

        stop_event_ = CreateEvent(nullptr, TRUE, FALSE, nullptr);

        DNSServiceErrorType err = DNSServiceBrowse(
            &browse_ref_,
            0,
            kDNSServiceInterfaceIndexAny,
            SERVICE_TYPE,
            SERVICE_DOMAIN,
            browse_callback_win,
            this);

        if (err != kDNSServiceErr_NoError) {
            blog(LOG_ERROR, "[avolocam] DNSServiceBrowse failed: %d", err);
            CloseHandle(stop_event_);
            stop_event_ = nullptr;
            return false;
        }

        running_.store(true);

        event_thread_ = std::thread([this]() {
            SOCKET fd = (SOCKET)DNSServiceRefSockFD(browse_ref_);

            // Create event ONCE outside the loop for efficiency
            WSAEVENT read_event = WSACreateEvent();
            WSAEventSelect(fd, read_event, FD_READ);

            WSAEVENT events[2];
            events[0] = read_event;
            events[1] = stop_event_;

            while (running_.load()) {
                // Use 20ms timeout for faster response (was 100ms)
                DWORD result = WSAWaitForMultipleEvents(2, events, FALSE, 20, FALSE);

                if (result == WSA_WAIT_EVENT_0) {
                    DNSServiceProcessResult(browse_ref_);
                    WSAResetEvent(read_event);  // Reset for reuse
                } else if (result == WSA_WAIT_EVENT_0 + 1) {
                    // Stop event signaled
                    break;
                }
            }

            // Clean up event after loop exits
            WSACloseEvent(read_event);
        });

        blog(LOG_INFO, "[avolocam] mDNS discovery started (Windows)");
        return true;
    }

    void stop_windows() {
        if (stop_event_) {
            SetEvent(stop_event_);
        }

        if (event_thread_.joinable()) {
            event_thread_.join();
        }

        for (auto &pair : resolve_refs_) {
            DNSServiceRefDeallocate(pair.second);
        }
        resolve_refs_.clear();

        if (browse_ref_) {
            DNSServiceRefDeallocate(browse_ref_);
            browse_ref_ = nullptr;
        }

        if (stop_event_) {
            CloseHandle(stop_event_);
            stop_event_ = nullptr;
        }

        WSACleanup();
    }

    static void DNSSD_API browse_callback_win(
        DNSServiceRef sdRef,
        DNSServiceFlags flags,
        uint32_t interfaceIndex,
        DNSServiceErrorType errorCode,
        const char *serviceName,
        const char *regtype,
        const char *replyDomain,
        void *context)
    {
        (void)sdRef;
        (void)regtype;
        auto *impl = static_cast<Impl*>(context);

        if (errorCode != kDNSServiceErr_NoError) {
            return;
        }

        std::string name = serviceName;

        if (flags & kDNSServiceFlagsAdd) {
            blog(LOG_INFO, "[avolocam] Discovered camera: %s", serviceName);
            impl->resolve_service_win(name, interfaceIndex, replyDomain);
        } else {
            impl->remove_camera(name);
        }
    }

    void resolve_service_win(const std::string &name, uint32_t interface_index,
                              const std::string &domain) {
        DNSServiceRef resolve_ref = nullptr;

        // Store context for callback
        struct ResolveContext {
            Impl *impl;
            std::string name;
            uint32_t interface_index;
        };

        auto *ctx = new ResolveContext{this, name, interface_index};

        DNSServiceErrorType err = DNSServiceResolve(
            &resolve_ref,
            0,
            interface_index,
            name.c_str(),
            SERVICE_TYPE,
            domain.c_str(),
            resolve_callback_win,
            ctx);

        if (err != kDNSServiceErr_NoError) {
            blog(LOG_ERROR, "[avolocam] DNSServiceResolve failed: %d", err);
            delete ctx;
            return;
        }

        // Store resolve ref for cleanup
        {
            std::lock_guard<std::mutex> lock(mutex_);
            resolve_refs_[name] = resolve_ref;
        }

        // Process resolve in separate thread with proper Windows event handling
        std::thread([resolve_ref, ctx, this]() {
            SOCKET fd = (SOCKET)DNSServiceRefSockFD(resolve_ref);
            WSAEVENT read_event = WSACreateEvent();
            WSAEventSelect(fd, read_event, FD_READ);

            // Wait up to 5 seconds for resolve
            DWORD result = WaitForSingleObject(read_event, 5000);

            if (result == WAIT_OBJECT_0) {
                DNSServiceProcessResult(resolve_ref);
            } else {
                blog(LOG_WARNING, "[avolocam] Resolve timeout for: %s", ctx->name.c_str());
            }

            WSACloseEvent(read_event);

            // Clean up resolve ref
            {
                std::lock_guard<std::mutex> lock(mutex_);
                auto it = resolve_refs_.find(ctx->name);
                if (it != resolve_refs_.end() && it->second == resolve_ref) {
                    resolve_refs_.erase(it);
                }
            }
            DNSServiceRefDeallocate(resolve_ref);
            delete ctx;
        }).detach();
    }

    static void DNSSD_API resolve_callback_win(
        DNSServiceRef sdRef,
        DNSServiceFlags flags,
        uint32_t interfaceIndex,
        DNSServiceErrorType errorCode,
        const char *fullname,
        const char *hosttarget,
        uint16_t port,
        uint16_t txtLen,
        const unsigned char *txtRecord,
        void *context)
    {
        (void)sdRef;
        (void)flags;
        (void)fullname;

        struct ResolveContext {
            Impl *impl;
            std::string name;
            uint32_t interface_index;
        };
        auto *ctx = static_cast<ResolveContext*>(context);

        if (errorCode != kDNSServiceErr_NoError) {
            blog(LOG_WARNING, "[avolocam] Resolve callback error: %d", errorCode);
            return;
        }

        // Parse TXT records
        std::map<std::string, std::string> txt;
        parse_txt_records_win(txtRecord, txtLen, txt);

        // Resolve hostname to IP address
        ctx->impl->resolve_host_win(ctx->name, hosttarget, ntohs(port), txt, interfaceIndex);
    }

    static void parse_txt_records_win(const unsigned char *txt, uint16_t len,
                                       std::map<std::string, std::string> &out) {
        uint16_t pos = 0;
        while (pos < len) {
            uint8_t record_len = txt[pos++];
            if (pos + record_len > len) break;

            std::string record((const char *)&txt[pos], record_len);
            pos += record_len;

            size_t eq = record.find('=');
            if (eq != std::string::npos) {
                out[record.substr(0, eq)] = record.substr(eq + 1);
            }
        }
    }

    void resolve_host_win(const std::string &name, const std::string &hostname,
                          uint16_t port, const std::map<std::string, std::string> &txt,
                          uint32_t interface_index) {
        DNSServiceRef getaddr_ref = nullptr;

        // Store context for callback
        struct GetAddrContextWin {
            Impl *impl;
            std::string name;
            uint16_t port;
            std::map<std::string, std::string> txt;
        };

        auto *ctx = new GetAddrContextWin{this, name, port, txt};

        DNSServiceErrorType err = DNSServiceGetAddrInfo(
            &getaddr_ref,
            0,
            interface_index,
            kDNSServiceProtocol_IPv4,
            hostname.c_str(),
            getaddr_callback_win,
            ctx);

        if (err != kDNSServiceErr_NoError) {
            blog(LOG_ERROR, "[avolocam] DNSServiceGetAddrInfo failed: %d", err);
            delete ctx;
            return;
        }

        // Process in thread with proper Windows event handling
        std::thread([getaddr_ref, ctx]() {
            SOCKET fd = (SOCKET)DNSServiceRefSockFD(getaddr_ref);
            WSAEVENT read_event = WSACreateEvent();
            WSAEventSelect(fd, read_event, FD_READ);

            // Wait up to 5 seconds for address resolution
            DWORD result = WaitForSingleObject(read_event, 5000);

            if (result == WAIT_OBJECT_0) {
                DNSServiceProcessResult(getaddr_ref);
            } else {
                blog(LOG_WARNING, "[avolocam] GetAddrInfo timeout for: %s", ctx->name.c_str());
            }

            WSACloseEvent(read_event);
            DNSServiceRefDeallocate(getaddr_ref);
            delete ctx;
        }).detach();
    }

    static void DNSSD_API getaddr_callback_win(
        DNSServiceRef sdRef,
        DNSServiceFlags flags,
        uint32_t interfaceIndex,
        DNSServiceErrorType errorCode,
        const char *hostname,
        const struct sockaddr *address,
        uint32_t ttl,
        void *context)
    {
        (void)sdRef;
        (void)flags;
        (void)interfaceIndex;
        (void)hostname;
        (void)ttl;

        struct GetAddrContextWin {
            Impl *impl;
            std::string name;
            uint16_t port;
            std::map<std::string, std::string> txt;
        };
        auto *ctx = static_cast<GetAddrContextWin*>(context);

        if (errorCode != kDNSServiceErr_NoError) {
            blog(LOG_WARNING, "[avolocam] GetAddrInfo callback error: %d", errorCode);
            return;
        }

        if (address->sa_family != AF_INET) {
            return;
        }

        const struct sockaddr_in *addr_in = (const struct sockaddr_in *)address;
        char ip_str[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &addr_in->sin_addr, ip_str, sizeof(ip_str));

        ctx->impl->add_camera(ctx->name, ip_str, ctx->port, ctx->txt);
    }
#endif

    void add_camera(const std::string &name, const std::string &ip,
                    uint16_t port, const std::map<std::string, std::string> &txt) {
        DiscoveredCamera camera;
        camera.name = name;
        camera.ip = ip;
        camera.http_port = port;
        camera.txt_records = txt;
        camera.resolved = true;
        camera.last_seen = os_gettime_ns();

        // Extract known TXT fields
        auto it = txt.find("flash_udp_port");
        if (it != txt.end()) {
            camera.flash_udp_port = (uint16_t)std::stoi(it->second);
        } else {
            camera.flash_udp_port = 5000; // Default
        }

        it = txt.find("alias");
        if (it != txt.end()) {
            camera.alias = it->second;
        }

        it = txt.find("version");
        if (it != txt.end()) {
            camera.version = it->second;
        }

        blog(LOG_INFO, "[avolocam] Camera resolved: %s at %s:%d (UDP: %d)",
             name.c_str(), ip.c_str(), port, camera.flash_udp_port);

        DiscoveryEvent event;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto existing = cameras_.find(name);
            event = (existing == cameras_.end()) ? DiscoveryEvent::Added : DiscoveryEvent::Updated;
            cameras_[name] = camera;
        }

        if (callback_) {
            callback_(event, camera);
        }
    }

    void remove_camera(const std::string &name) {
        DiscoveredCamera camera;
        bool found = false;

        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto it = cameras_.find(name);
            if (it != cameras_.end()) {
                camera = it->second;
                cameras_.erase(it);
                found = true;
            }
        }

        if (found && callback_) {
            callback_(DiscoveryEvent::Removed, camera);
        }
    }

    std::vector<DiscoveredCamera> get_cameras() const {
        std::lock_guard<std::mutex> lock(mutex_);
        std::vector<DiscoveredCamera> result;
        result.reserve(cameras_.size());
        for (const auto &pair : cameras_) {
            result.push_back(pair.second);
        }
        return result;
    }
};

// Public interface implementation

MdnsDiscovery::MdnsDiscovery()
    : impl_(std::make_unique<Impl>())
{
}

MdnsDiscovery::~MdnsDiscovery() = default;

bool MdnsDiscovery::start(CameraDiscoveryCallback callback)
{
    return impl_->start(std::move(callback));
}

void MdnsDiscovery::stop()
{
    impl_->stop();
}

bool MdnsDiscovery::is_running() const
{
    return impl_->running_.load();
}

std::vector<DiscoveredCamera> MdnsDiscovery::get_cameras() const
{
    return impl_->get_cameras();
}

std::optional<DiscoveredCamera> MdnsDiscovery::get_camera(const std::string &identifier) const
{
    std::lock_guard<std::mutex> lock(impl_->mutex_);

    // Search by name
    auto it = impl_->cameras_.find(identifier);
    if (it != impl_->cameras_.end()) {
        return it->second;
    }

    // Search by IP
    for (const auto &pair : impl_->cameras_) {
        if (pair.second.ip == identifier) {
            return pair.second;
        }
    }

    return std::nullopt;
}

void MdnsDiscovery::add_manual_camera(const std::string &ip, uint16_t http_port,
                                       uint16_t flash_udp_port)
{
    DiscoveredCamera camera;
    camera.name = "Manual: " + ip;
    camera.ip = ip;
    camera.http_port = http_port;
    camera.flash_udp_port = flash_udp_port;
    camera.resolved = true;
    camera.last_seen = os_gettime_ns();

    {
        std::lock_guard<std::mutex> lock(impl_->mutex_);
        impl_->cameras_[camera.name] = camera;
    }

    if (impl_->callback_) {
        impl_->callback_(DiscoveryEvent::Added, camera);
    }
}

void MdnsDiscovery::remove_manual_camera(const std::string &ip)
{
    impl_->remove_camera("Manual: " + ip);
}

} // namespace avolocam
