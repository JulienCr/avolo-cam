/**
 * winsock-init.h - Shared Winsock initialization
 *
 * Provides a single WSAStartup call shared across all subsystems
 * (UdpReceiver, WebSocketClient, MdnsDiscovery). Uses std::call_once
 * to guarantee thread-safe one-time initialization.
 *
 * WSACleanup is intentionally never called: this is a plugin DLL and
 * the OS reclaims Winsock resources on process exit. Calling WSACleanup
 * from one subsystem while another still has active sockets would
 * invalidate those sockets.
 */

#pragma once

#ifdef _WIN32

namespace avolocam {

/**
 * Ensure Winsock 2.2 is initialized. Thread-safe, idempotent.
 * Call this before any socket operation. Returns true on success.
 */
bool ensure_winsock_initialized();

} // namespace avolocam

#endif // _WIN32
