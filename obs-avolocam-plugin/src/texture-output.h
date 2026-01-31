/**
 * texture-output.h - GPU texture output interface for OBS
 *
 * Provides zero-copy GPU texture rendering when possible,
 * with fallback to CPU copy for compatibility.
 *
 * Platform support:
 * - macOS: IOSurface zero-copy via gs_texture_create_from_iosurface
 * - Windows: D3D11 shared texture (future), CPU fallback for now
 */

#pragma once

#include "decoder/platform-decoder.h"
#include <obs-module.h>
#include <cstdint>

namespace avolocam {

/**
 * Output rendering mode
 */
enum class OutputMode {
    GPU_ZERO_COPY,   // Direct GPU texture (IOSurface/D3D11 shared)
    GPU_UPLOAD,      // Upload to GPU texture
    CPU_COPY         // CPU buffer copy via obs_source_output_video
};

/**
 * Result of frame output operation
 */
struct OutputResult {
    bool success;               // True if frame was output successfully
    OutputMode mode_used;       // Actual mode used for this frame
    uint64_t operation_time_ns; // Time taken for the operation
};

/**
 * Extended decoded frame with platform-specific GPU handles
 */
struct GPUFrame {
    // Base frame data (for CPU fallback)
    uint8_t *y_plane = nullptr;
    uint8_t *uv_plane = nullptr;
    uint32_t y_stride = 0;
    uint32_t uv_stride = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    uint64_t pts = 0;

    // Platform-specific GPU handles
    void *platform_handle = nullptr;  // CVPixelBufferRef on macOS, ID3D11Texture2D* on Windows

    // GPU texture info
    bool has_gpu_texture = false;

#ifdef __APPLE__
    void *iosurface = nullptr;  // IOSurfaceRef for zero-copy
#endif

#ifdef _WIN32
    void *d3d_texture = nullptr;      // ID3D11Texture2D*
    void *d3d_shared_handle = nullptr; // Shared texture handle
#endif
};

/**
 * Texture output context
 *
 * Manages GPU textures and rendering for a single source.
 */
class TextureOutput {
public:
    TextureOutput();
    ~TextureOutput();

    // Non-copyable
    TextureOutput(const TextureOutput&) = delete;
    TextureOutput& operator=(const TextureOutput&) = delete;

    /**
     * Initialize for a source
     * @param source OBS source to output to
     * @param prefer_zero_copy Prefer GPU zero-copy when available
     */
    void initialize(obs_source_t *source, bool prefer_zero_copy = true);

    /**
     * Shutdown and release resources
     */
    void shutdown();

    /**
     * Output a decoded frame to OBS
     *
     * Automatically selects the best output mode based on frame type
     * and platform capabilities.
     *
     * @param frame Decoded frame to output
     * @return Result of the output operation
     */
    OutputResult output_frame(const DecodedFrame &frame);

    /**
     * Output a GPU frame with extended GPU handles
     * @param frame GPU frame with platform-specific handles
     * @return Result of the output operation
     */
    OutputResult output_gpu_frame(const GPUFrame &frame);

    /**
     * Check if zero-copy output is available on this platform
     */
    bool is_zero_copy_available() const;

    /**
     * Get current output mode preference
     */
    OutputMode get_preferred_mode() const { return preferred_mode_; }

    /**
     * Set output mode preference
     */
    void set_preferred_mode(OutputMode mode) { preferred_mode_ = mode; }

    /**
     * Get statistics
     */
    uint64_t zero_copy_frames() const { return zero_copy_frames_; }
    uint64_t cpu_copy_frames() const { return cpu_copy_frames_; }
    uint64_t total_frames() const { return total_frames_; }

private:
    obs_source_t *source_ = nullptr;
    OutputMode preferred_mode_ = OutputMode::CPU_COPY;
    bool initialized_ = false;

    // Statistics
    uint64_t zero_copy_frames_ = 0;
    uint64_t cpu_copy_frames_ = 0;
    uint64_t total_frames_ = 0;

#ifdef __APPLE__
    // macOS: OBS texture from IOSurface
    gs_texture_t *macos_texture_ = nullptr;
    uint32_t macos_texture_width_ = 0;
    uint32_t macos_texture_height_ = 0;

    OutputResult output_via_iosurface(const DecodedFrame &frame);
    OutputResult output_via_iosurface_gpu(const GPUFrame &frame);
    void release_macos_texture();
#endif

#ifdef _WIN32
    // Windows: D3D11 texture support
    void *win_staging_texture_ = nullptr;  // ID3D11Texture2D*
    gs_texture_t *win_texture_ = nullptr;
    uint32_t win_texture_width_ = 0;
    uint32_t win_texture_height_ = 0;

    OutputResult output_via_d3d11(const DecodedFrame &frame);
    void release_win_texture();
#endif

    // CPU fallback
    OutputResult output_via_cpu(const DecodedFrame &frame);
};

/**
 * Query platform zero-copy capabilities
 */
bool platform_supports_zero_copy();

/**
 * Get human-readable name for output mode
 */
const char *output_mode_name(OutputMode mode);

} // namespace avolocam
