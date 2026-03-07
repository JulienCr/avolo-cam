/**
 * mdns-discovery.h - mDNS/Bonjour camera discovery
 *
 * Discovers AvoCam cameras on the local network using mDNS.
 * Cameras advertise as _avolocam._tcp service.
 *
 * TXT records include:
 * - flash_udp_port: UDP port for Flash streaming
 * - alias: Camera friendly name
 * - version: Firmware version
 */

#pragma once

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace avolocam {

/**
 * Discovered camera information
 */
struct DiscoveredCamera {
    std::string name;              // Service name from mDNS
    std::string ip;                // Resolved IP address
    uint16_t http_port;            // HTTP API port (usually 8888)
    uint16_t flash_udp_port;       // UDP port for Flash streaming (from TXT record)
    std::string alias;             // Camera alias (from TXT record)
    std::string version;           // Firmware version (from TXT record)
    std::string token;             // Auth token (if available)
    std::map<std::string, std::string> txt_records;  // All TXT records
    uint64_t last_seen;            // Last seen timestamp (nanoseconds)
    bool resolved;                 // True if IP address is resolved
};

/**
 * Discovery event types
 */
enum class DiscoveryEvent {
    Added,      // New camera discovered
    Updated,    // Camera info updated
    Removed,    // Camera removed/offline
};

/**
 * Callback for camera discovery events
 */
using CameraDiscoveryCallback = std::function<void(DiscoveryEvent event,
                                                    const DiscoveredCamera &camera)>;

/**
 * mDNS camera discovery service
 *
 * Uses platform-specific mDNS APIs:
 * - macOS/iOS: NSNetServiceBrowser (via Objective-C bridge)
 * - Windows: dns-sd.dll (Bonjour for Windows)
 * - Linux: Avahi (libavahi-client)
 */
class MdnsDiscovery {
public:
    MdnsDiscovery();
    ~MdnsDiscovery();

    // Non-copyable
    MdnsDiscovery(const MdnsDiscovery&) = delete;
    MdnsDiscovery& operator=(const MdnsDiscovery&) = delete;

    /**
     * Start browsing for AvoCam services
     *
     * @param callback Function to call when cameras are discovered/updated/removed
     * @return true on success, false if discovery is not available
     */
    bool start(CameraDiscoveryCallback callback);

    /**
     * Stop browsing
     */
    void stop();

    /**
     * Check if discovery is running
     */
    bool is_running() const;

    /**
     * Get list of currently discovered cameras
     *
     * Thread-safe snapshot of discovered cameras.
     */
    std::vector<DiscoveredCamera> get_cameras() const;

    /**
     * Get a specific camera by name or IP
     *
     * @param identifier Camera name or IP address
     * @return Camera info if found
     */
    std::optional<DiscoveredCamera> get_camera(const std::string &identifier) const;

    /**
     * Manually add a camera (for networks where mDNS doesn't work)
     *
     * @param ip IP address
     * @param http_port HTTP API port
     * @param flash_udp_port UDP port for Flash streaming
     */
    void add_manual_camera(const std::string &ip, uint16_t http_port, uint16_t flash_udp_port);

    /**
     * Remove a manually added camera
     */
    void remove_manual_camera(const std::string &ip);

    /**
     * Get the service type being browsed
     */
    static const char *get_service_type() { return "_avolocam._tcp"; }

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace avolocam
