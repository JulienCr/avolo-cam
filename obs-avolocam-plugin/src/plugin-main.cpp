/**
 * obs-avolocam - Ultra low-latency video source for OBS
 *
 * Receives H.264 video over UDP/RTP from iOS devices running AvoCam
 * with hardware-accelerated decoding on macOS (VideoToolbox) and
 * Windows (FFmpeg D3D11VA).
 */

#include <obs-module.h>
#include "avolocam-source.h"
#include "avolocam-source-data.h"
#include "logging.h"

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE("obs-avolocam", "en-US")

MODULE_EXPORT const char *obs_module_description(void)
{
    return "Ultra low-latency video source for AvoCam iOS cameras";
}

// Force recompile on every build (volatile timestamp)
static const char *g_build_timestamp = __DATE__ " " __TIME__;

bool obs_module_load(void)
{
    ALOG(LOG_INFO, "Plugin built: %s", g_build_timestamp);
    ALOG(LOG_INFO, "Plugin loading...");

    // Register the video source
    avolocam_source_register();

    ALOG(LOG_INFO, "Plugin loaded successfully");
    return true;
}

void obs_module_unload(void)
{
    ALOG(LOG_INFO, "Plugin unloading...");

    // Stop and release global mDNS discovery to avoid thread leak.
    // Swap under lock, then stop outside to avoid blocking the mutex during thread joins.
    decltype(avolocam::g_discovery) local_discovery;
    {
        std::lock_guard<std::mutex> lock(avolocam::g_discovery_mutex);
        local_discovery.swap(avolocam::g_discovery);
    }
    if (local_discovery) {
        local_discovery->stop();
    }

    ALOG(LOG_INFO, "Plugin unloaded");
}
