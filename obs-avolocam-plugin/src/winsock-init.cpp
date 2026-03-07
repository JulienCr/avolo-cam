/**
 * winsock-init.cpp - Shared Winsock initialization
 */

#include "winsock-init.h"

#ifdef _WIN32

#include <mutex>

#include <winsock2.h>

#include <obs-module.h>

#include "logging.h"

#pragma comment(lib, "ws2_32.lib")

namespace avolocam {

static std::once_flag g_winsock_init_flag;
static bool g_winsock_initialized = false;

bool ensure_winsock_initialized()
{
    std::call_once(g_winsock_init_flag, []() {
        WSADATA wsa_data;
        int result = WSAStartup(MAKEWORD(2, 2), &wsa_data);
        if (result != 0) {
            ALOG(LOG_ERROR, "WSAStartup failed: %d", result);
        } else {
            g_winsock_initialized = true;
            ALOG(LOG_INFO, "Winsock initialized (shared)");
        }
    });
    return g_winsock_initialized;
}

} // namespace avolocam

#endif // _WIN32
