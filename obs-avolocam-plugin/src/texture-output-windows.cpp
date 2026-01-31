/**
 * texture-output-windows.cpp - Windows D3D11 texture output implementation
 *
 * Implements GPU texture output using D3D11 shared textures when possible,
 * with CPU staging texture fallback.
 */

#include "texture-output.h"

#ifdef _WIN32

#include <obs-module.h>
#include <graphics/graphics.h>
#include <media-io/video-io.h>
#include <util/platform.h>
#include <cstring>

#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>

namespace avolocam {

// Check if OBS is using D3D11 backend
static bool obs_is_d3d11_backend()
{
    obs_enter_graphics();
    int device_type = gs_get_device_type();
    obs_leave_graphics();

    // OBS on Windows uses D3D11 by default
    return device_type == GS_DEVICE_DIRECT3D_11;
}

// Get OBS D3D11 device (if available)
static ID3D11Device *get_obs_d3d11_device()
{
    obs_enter_graphics();
    gs_device_t *device = static_cast<gs_device_t*>(gs_get_device_obj());
    obs_leave_graphics();

    if (!device) return nullptr;

    // OBS exposes the D3D11 device through its graphics system
    // This requires using internal OBS APIs
    // For now, return nullptr to use CPU fallback
    return nullptr;
}

TextureOutput::TextureOutput()
{
    // Windows-specific initialization
}

TextureOutput::~TextureOutput()
{
    shutdown();
}

void TextureOutput::initialize(obs_source_t *source, bool prefer_zero_copy)
{
    source_ = source;

    // Check for D3D11 support
    if (prefer_zero_copy && obs_is_d3d11_backend()) {
        // D3D11 zero-copy requires matching device between decoder and OBS
        // For now, default to CPU copy as D3D11 sharing is complex
        preferred_mode_ = OutputMode::CPU_COPY;
        blog(LOG_INFO, "[avolocam] D3D11 backend detected, using CPU copy (shared texture TODO)");
    } else {
        preferred_mode_ = OutputMode::CPU_COPY;
        blog(LOG_INFO, "[avolocam] Using CPU copy output");
    }

    initialized_ = true;
}

void TextureOutput::shutdown()
{
    if (!initialized_) return;

    release_win_texture();
    source_ = nullptr;
    initialized_ = false;
}

void TextureOutput::release_win_texture()
{
    if (win_staging_texture_) {
        ((ID3D11Texture2D *)win_staging_texture_)->Release();
        win_staging_texture_ = nullptr;
    }

    if (win_texture_) {
        obs_enter_graphics();
        gs_texture_destroy(win_texture_);
        obs_leave_graphics();
        win_texture_ = nullptr;
    }

    win_texture_width_ = 0;
    win_texture_height_ = 0;
}

bool TextureOutput::is_zero_copy_available() const
{
    // D3D11 zero-copy requires shared texture support
    // This is complex to implement correctly, so report false for now
    return false;
}

OutputResult TextureOutput::output_frame(const DecodedFrame &frame)
{
    if (!initialized_ || !source_) {
        return {false, OutputMode::CPU_COPY, 0};
    }

    uint64_t start_time = os_gettime_ns();
    OutputResult result;

    // Check for D3D11 texture handle
    if (frame.platform_handle && preferred_mode_ == OutputMode::GPU_ZERO_COPY) {
        result = output_via_d3d11(frame);
        if (result.success) {
            zero_copy_frames_++;
            total_frames_++;
            result.operation_time_ns = os_gettime_ns() - start_time;
            return result;
        }
    }

    // CPU fallback
    result = output_via_cpu(frame);
    cpu_copy_frames_++;
    total_frames_++;
    result.operation_time_ns = os_gettime_ns() - start_time;
    return result;
}

OutputResult TextureOutput::output_gpu_frame(const GPUFrame &frame)
{
    if (!initialized_ || !source_) {
        return {false, OutputMode::CPU_COPY, 0};
    }

    uint64_t start_time = os_gettime_ns();
    OutputResult result;

    // Check for D3D11 texture
    if (frame.d3d_texture && preferred_mode_ == OutputMode::GPU_ZERO_COPY) {
        // Future: Implement D3D11 shared texture path
        // For now, fall through to CPU
    }

    // CPU fallback
    DecodedFrame base_frame;
    base_frame.y_plane = frame.y_plane;
    base_frame.uv_plane = frame.uv_plane;
    base_frame.y_stride = frame.y_stride;
    base_frame.uv_stride = frame.uv_stride;
    base_frame.width = frame.width;
    base_frame.height = frame.height;
    base_frame.pts = frame.pts;

    result = output_via_cpu(base_frame);
    cpu_copy_frames_++;
    total_frames_++;
    result.operation_time_ns = os_gettime_ns() - start_time;
    return result;
}

OutputResult TextureOutput::output_via_d3d11(const DecodedFrame &frame)
{
    // D3D11 zero-copy implementation
    //
    // For true zero-copy on Windows:
    // 1. Media Foundation decoder outputs to ID3D11Texture2D
    // 2. Create a shared texture handle (DXGI_SHARED_HANDLE)
    // 3. Open the shared texture in OBS's D3D11 device
    // 4. Use gs_texture_create_from_d3d11_shared() (if available)
    //
    // Challenges:
    // - MF decoder and OBS may use different D3D11 devices
    // - Need to ensure proper synchronization between devices
    // - OBS doesn't expose gs_texture_create_from_d3d11_shared publicly
    //
    // For now, this always fails and falls back to CPU copy

    (void)frame;
    return {false, OutputMode::GPU_ZERO_COPY, 0};
}

OutputResult TextureOutput::output_via_cpu(const DecodedFrame &frame)
{
    if (!frame.y_plane || !frame.uv_plane) {
        return {false, OutputMode::CPU_COPY, 0};
    }

    // Create OBS video frame
    struct obs_source_frame obs_frame = {};
    obs_frame.width = frame.width;
    obs_frame.height = frame.height;
    obs_frame.format = VIDEO_FORMAT_NV12;
    obs_frame.timestamp = os_gettime_ns();

    // Set plane pointers
    obs_frame.data[0] = frame.y_plane;
    obs_frame.data[1] = frame.uv_plane;
    obs_frame.linesize[0] = frame.y_stride;
    obs_frame.linesize[1] = frame.uv_stride;

    // Color space: Rec.709 full range (matching iOS encoder)
    // Get the proper color matrix for Rec.709 full range
    float color_matrix[16];
    float color_range_min[3];
    float color_range_max[3];
    video_format_get_parameters(VIDEO_CS_709, VIDEO_RANGE_FULL,
                                color_matrix, color_range_min, color_range_max);
    memcpy(obs_frame.color_matrix, color_matrix, sizeof(color_matrix));
    memcpy(obs_frame.color_range_min, color_range_min, sizeof(color_range_min));
    memcpy(obs_frame.color_range_max, color_range_max, sizeof(color_range_max));
    obs_frame.full_range = true;

    // Output the frame
    obs_source_output_video(source_, &obs_frame);

    return {true, OutputMode::CPU_COPY, 0};
}

// Platform-level queries
bool platform_supports_zero_copy()
{
    // D3D11 zero-copy is theoretically possible but not implemented
    return false;
}

const char *output_mode_name(OutputMode mode)
{
    switch (mode) {
    case OutputMode::GPU_ZERO_COPY:
        return "GPU Zero-Copy (D3D11 Shared)";
    case OutputMode::GPU_UPLOAD:
        return "GPU Upload";
    case OutputMode::CPU_COPY:
        return "CPU Copy";
    default:
        return "Unknown";
    }
}

} // namespace avolocam

#endif // _WIN32
