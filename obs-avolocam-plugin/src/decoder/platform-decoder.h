/**
 * platform-decoder.h - Abstract platform decoder interface
 *
 * Provides a unified interface for hardware-accelerated H.264 decoding
 * across different platforms (macOS VideoToolbox, Windows FFmpeg D3D11VA).
 */

#pragma once

#include <cstdint>
#include <memory>
#include <vector>

namespace avolocam {

/**
 * Decode timing statistics for performance analysis
 *
 * Measures time spent in each stage of the decode pipeline.
 * All times are in nanoseconds.
 */
struct DecodeTimingStats {
    uint64_t process_input_ns = 0;    // Time in ProcessInput()
    uint64_t process_output_ns = 0;   // Time in ProcessOutput() (excluding buffer ops)
    uint64_t lock_buffer_ns = 0;      // Time in Lock2D() or buffer lock
    uint64_t memcpy_ns = 0;           // Time in memcpy operations
    uint64_t total_decode_ns = 0;     // Total decode time for this frame
    uint64_t frame_count = 0;         // Number of frames processed

    // Cumulative stats for averaging
    uint64_t cumulative_input_ns = 0;
    uint64_t cumulative_output_ns = 0;
    uint64_t cumulative_lock_ns = 0;
    uint64_t cumulative_memcpy_ns = 0;
    uint64_t cumulative_total_ns = 0;

    void accumulate() {
        cumulative_input_ns += process_input_ns;
        cumulative_output_ns += process_output_ns;
        cumulative_lock_ns += lock_buffer_ns;
        cumulative_memcpy_ns += memcpy_ns;
        cumulative_total_ns += total_decode_ns;
        frame_count++;
    }

    void reset_per_frame() {
        process_input_ns = 0;
        process_output_ns = 0;
        lock_buffer_ns = 0;
        memcpy_ns = 0;
        total_decode_ns = 0;
    }

    // Get average times in milliseconds
    double avg_input_ms() const { return frame_count > 0 ? (cumulative_input_ns / frame_count) / 1e6 : 0; }
    double avg_output_ms() const { return frame_count > 0 ? (cumulative_output_ns / frame_count) / 1e6 : 0; }
    double avg_lock_ms() const { return frame_count > 0 ? (cumulative_lock_ns / frame_count) / 1e6 : 0; }
    double avg_memcpy_ms() const { return frame_count > 0 ? (cumulative_memcpy_ns / frame_count) / 1e6 : 0; }
    double avg_total_ms() const { return frame_count > 0 ? (cumulative_total_ns / frame_count) / 1e6 : 0; }
};

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
    void *platform_handle = nullptr; // Platform-specific handle (CVPixelBuffer, etc.)

    // GPU texture info (Windows D3D11)
    void *gpu_texture = nullptr;    // ID3D11Texture2D* when using GPU path
    uint32_t gpu_subresource = 0;   // Subresource index for texture arrays
    bool has_gpu_texture = false;   // True if gpu_texture is valid
    void *shared_handle = nullptr;  // DXGI shared handle for cross-device sharing (RGBA)
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
     * Factory method - creates the best available decoder for the current platform
     *
     * - macOS: VideoToolbox
     * - Windows: FFmpeg D3D11VA
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

    /**
     * Get decode timing statistics
     * @return Reference to timing stats (accumulated over session)
     */
    virtual const DecodeTimingStats &get_timing_stats() const = 0;

    /**
     * Reset timing statistics
     */
    virtual void reset_timing_stats() = 0;

    /**
     * Check if GPU texture output is available
     * @return true if decoder can output GPU textures directly
     */
    virtual bool supports_gpu_output() const { return false; }

    /**
     * Enable or disable GPU texture output mode
     * When enabled, DecodedFrame::gpu_texture will be set instead of CPU planes
     * @param enable true to enable GPU output
     * @return true if mode was changed successfully
     */
    virtual bool set_gpu_output(bool enable) { (void)enable; return false; }

    // D3D11 device access for GPU output path (Windows only, returns nullptr on other platforms)
    virtual void *get_d3d_device() const { return nullptr; }
    virtual void *get_d3d_context() const { return nullptr; }
};

} // namespace avolocam
