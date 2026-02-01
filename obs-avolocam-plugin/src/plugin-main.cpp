/**
 * obs-avolocam - Ultra low-latency video source for OBS
 *
 * Receives H.264 video over UDP/RTP from iOS devices running AvoCam
 * with hardware-accelerated decoding on macOS (VideoToolbox) and
 * Windows (Media Foundation).
 */

#include <obs-module.h>
#include "avolocam-source.h"

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE("obs-avolocam", "en-US")

MODULE_EXPORT const char *obs_module_description(void)
{
    return "Ultra low-latency video source for AvoCam iOS cameras";
}

bool obs_module_load(void)
{
    blog(LOG_INFO, "[avolocam] Plugin built: %s %s", __DATE__, __TIME__);
    blog(LOG_INFO, "[avolocam] Plugin loading...");

    // Register the video source
    avolocam_source_register();

    blog(LOG_INFO, "[avolocam] Plugin loaded successfully");
    return true;
}

void obs_module_unload(void)
{
    blog(LOG_INFO, "[avolocam] Plugin unloading...");
}
