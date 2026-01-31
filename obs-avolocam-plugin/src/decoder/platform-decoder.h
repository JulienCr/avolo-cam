/**
 * platform-decoder.h - Abstract platform decoder interface
 *
 * Provides a unified interface for hardware-accelerated H.264 decoding
 * across different platforms (macOS VideoToolbox, Windows Media Foundation).
 */

#pragma once

#include <cstdint>
#include <memory>
#include <vector>

namespace avolocam {

/**
 * Decoded frame output structure
 *
 * Contains NV12 format video data (Y plane + interleaved UV plane)
 */
struct DecodedFrame {
    uint8_t *y_plane = nullptr;     // Luma plane pointer
    uint8_t *uv_plane = nullptr;    // Chroma plane pointer (interleaved UV)
    uint32_t y_stride = 0;          // Y plane row stride in bytes
    uint32_t uv_stride = 0;         // UV plane row stride in bytes
    uint32_t width = 0;             // Frame width in pixels
    uint32_t height = 0;            // Frame height in pixels
    uint64_t pts = 0;               // Presentation timestamp
    bool owns_memory = false;       // If true, decoder manages memory lifetime
    void *platform_handle = nullptr; // Platform-specific handle (CVPixelBuffer, IMFSample, etc.)
};

/**
 * Decoder configuration options
 */
struct DecoderConfig {
    bool prefer_hardware = true;    // Prefer hardware decoder if available
    bool low_latency = true;        // Enable low-latency mode
    bool output_nv12 = true;        // Output NV12 format (vs I420)
    uint32_t max_width = 1920;      // Maximum expected width
    uint32_t max_height = 1080;     // Maximum expected height
};

/**
 * Abstract platform decoder interface
 *
 * Factory method creates the best available decoder for the current platform.
 */
class PlatformDecoder {
public:
    virtual ~PlatformDecoder() = default;

    /**
     * Factory method - creates the best decoder available for this platform
     *
     * Order of preference:
     * - macOS: VideoToolbox
     * - Windows: Media Foundation (D3D11VA if available)
     * - Fallback: FFmpeg software decoder (if compiled with HAVE_FFMPEG)
     *
     * @param config Decoder configuration options
     * @return Unique pointer to decoder, or nullptr on failure
     */
    static std::unique_ptr<PlatformDecoder> create(
        const DecoderConfig &config = DecoderConfig{});

    /**
     * Initialize decoder with H.264 parameter sets
     *
     * Must be called before decode() with valid SPS and PPS.
     * Can be called again if parameter sets change (resolution change, etc.)
     *
     * @param sps Sequence Parameter Set data (without start code)
     * @param sps_size SPS size in bytes
     * @param pps Picture Parameter Set data (without start code)
     * @param pps_size PPS size in bytes
     * @return true on success, false on failure
     */
    virtual bool initialize(const uint8_t *sps, size_t sps_size,
                            const uint8_t *pps, size_t pps_size) = 0;

    /**
     * Decode an H.264 access unit
     *
     * Input should be a complete access unit with Annex B start codes.
     *
     * @param data Access unit data
     * @param size Data size in bytes
     * @param out Output decoded frame
     * @return true if frame was decoded, false on error or if decoder needs more data
     */
    virtual bool decode(const uint8_t *data, size_t size, DecodedFrame &out) = 0;

    /**
     * Flush decoder and retrieve any pending frames
     *
     * Call when switching streams or on discontinuity.
     */
    virtual void flush() = 0;

    /**
     * Reset decoder state
     *
     * Call on stream discontinuity or seek. Does not require re-initialization.
     */
    virtual void reset() = 0;

    /**
     * Get decoded video width
     * @return Width in pixels, or 0 if not initialized
     */
    virtual uint32_t get_width() const = 0;

    /**
     * Get decoded video height
     * @return Height in pixels, or 0 if not initialized
     */
    virtual uint32_t get_height() const = 0;

    /**
     * Check if using hardware decoding
     * @return true if hardware accelerated
     */
    virtual bool is_hardware() const = 0;

    /**
     * Get decoder name for logging
     */
    virtual const char *get_name() const = 0;

    /**
     * Check if decoder is initialized and ready
     */
    virtual bool is_initialized() const = 0;
};

} // namespace avolocam
