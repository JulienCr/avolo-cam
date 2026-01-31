/**
 * platform-decoder-fallback.cpp - Fallback when no platform decoder is available
 *
 * Used on Linux without FFmpeg or other platforms without hardware decoder support.
 * Returns nullptr, which the caller should handle gracefully.
 */

#include "platform-decoder.h"

// Only compile this file if we're not on macOS, Windows, or if FFmpeg is not available
#if !defined(__APPLE__) && !defined(_WIN32) && !defined(HAVE_FFMPEG)

#include <obs-module.h>

namespace avolocam {

std::unique_ptr<PlatformDecoder> PlatformDecoder::create(const DecoderConfig &config)
{
    (void)config;
    blog(LOG_ERROR, "[avolocam] No platform decoder available for this platform");
    blog(LOG_ERROR, "[avolocam] Consider building with FFmpeg support (ENABLE_FFMPEG_FALLBACK=ON)");
    return nullptr;
}

} // namespace avolocam

#endif // Fallback conditions
