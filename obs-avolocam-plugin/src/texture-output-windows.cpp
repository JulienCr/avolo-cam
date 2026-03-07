/**
 * texture-output-windows.cpp - Windows D3D11 texture output implementation
 *
 * Implements GPU texture output using D3D11 shared textures when possible,
 * with CPU staging texture fallback.
 *
 * GPU Pipeline (when available):
 *   MF Decoder → ID3D11Texture2D (NV12) → Compute Shader → RGBA Texture → OBS
 *
 * CPU Fallback:
 *   MF Decoder → Lock2D → memcpy → obs_source_output_video
 */

#include "texture-output.h"
#include "gpu-converter.h"

#ifdef _WIN32

#include <obs-module.h>
#include <graphics/graphics.h>
#include <media-io/video-io.h>
#include <util/platform.h>
#include <cstring>
#include <memory>
#include <mutex>

#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <util/windows/ComPtr.hpp>

namespace avolocam {

// Static GPU converter instance (shared across all TextureOutput instances)
// This is because we want to share the compute shader and texture pool
static std::unique_ptr<GPUConverter> g_gpu_converter;
static std::mutex g_gpu_converter_mutex;
static int g_gpu_converter_ref_count = 0;

// Check if OBS is using D3D11 backend
static bool obs_is_d3d11_backend()
{
    obs_enter_graphics();
    int device_type = gs_get_device_type();
    obs_leave_graphics();

    // OBS on Windows uses D3D11 by default
    return device_type == GS_DEVICE_DIRECT3D_11;
}

// Get OBS D3D11 device (using internal structure)
// This is a best-effort approach - OBS doesn't officially expose this
static ID3D11Device *get_obs_d3d11_device()
{
    // OBS's gs_device_t structure has the D3D11 device as one of its members
    // The exact offset depends on OBS version, so we use gs_get_device_obj()
    // which returns the raw device pointer on D3D11 backend

    if (!obs_is_d3d11_backend()) {
        return nullptr;
    }

    obs_enter_graphics();

    // On D3D11 backend, gs_get_device_obj() returns ID3D11Device*
    void *device_obj = gs_get_device_obj();

    obs_leave_graphics();

    if (!device_obj) {
        return nullptr;
    }

    // Cast to ID3D11Device - this works because OBS stores the raw device
    return static_cast<ID3D11Device*>(device_obj);
}

// Initialize global GPU converter with decoder's D3D11 device
//
// TODO: ARCHITECTURAL ISSUE - Cross-Device Texture Sharing
// Currently, the GPUConverter is initialized with the decoder's D3D11 device,
// but OBS has its own D3D11 device. CopyResource between different devices
// does NOT work. The current implementation uses DXGI shared handles to
// properly share textures between the two devices.
//
// IDEAL SOLUTION: Initialize the decoder to use OBS's D3D11 device directly.
// This would eliminate the need for cross-device sharing entirely and provide
// true zero-copy operation. However, this requires changes to the MF decoder
// initialization to accept an external device.
//
// For now, we use shared handles which adds minimal overhead but still avoids
// CPU involvement in the texture transfer.
static bool init_gpu_converter(ID3D11Device *device, ID3D11DeviceContext *context)
{
    std::lock_guard<std::mutex> lock(g_gpu_converter_mutex);

    if (g_gpu_converter && g_gpu_converter->is_initialized()) {
        g_gpu_converter_ref_count++;
        return true;
    }

    g_gpu_converter = std::make_unique<GPUConverter>();
    if (!g_gpu_converter->initialize(device, context)) {
        g_gpu_converter.reset();
        return false;
    }

    g_gpu_converter_ref_count++;
    return true;
}

static void shutdown_gpu_converter()
{
    std::lock_guard<std::mutex> lock(g_gpu_converter_mutex);

    g_gpu_converter_ref_count--;
    if (g_gpu_converter_ref_count <= 0) {
        g_gpu_converter.reset();
        g_gpu_converter_ref_count = 0;
    }
}

static GPUConverter *get_gpu_converter()
{
    std::lock_guard<std::mutex> lock(g_gpu_converter_mutex);
    return g_gpu_converter.get();
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
        // Try to enable GPU zero-copy
        ID3D11Device *obs_device = get_obs_d3d11_device();
        if (obs_device) {
            preferred_mode_ = OutputMode::GPU_ZERO_COPY;
            blog(LOG_INFO, "[avolocam] D3D11 backend detected, GPU zero-copy enabled");
        } else {
            preferred_mode_ = OutputMode::CPU_COPY;
            blog(LOG_INFO, "[avolocam] D3D11 backend detected, but couldn't get device - using CPU copy");
        }
    } else {
        preferred_mode_ = OutputMode::CPU_COPY;
        blog(LOG_INFO, "[avolocam] Using CPU copy output");
    }

    initialized_ = true;
}

void TextureOutput::shutdown()
{
    if (!initialized_) return;

    release_shared_cache();
    release_win_texture();
    if (gpu_converter_acquired_) {
        shutdown_gpu_converter();
        gpu_converter_acquired_ = false;
    }
    source_ = nullptr;
    initialized_ = false;
}

void TextureOutput::release_shared_cache()
{
    for (size_t i = 0; i < SHARED_CACHE_SIZE; i++) {
        shared_cache_[i].opened_texture.Clear();
        shared_cache_[i].shared_handle = nullptr;
    }
    cached_obs_device_ = nullptr;
}

ID3D11Texture2D *TextureOutput::get_or_open_shared_texture(ID3D11Device *obs_device, void *shared_handle)
{
    if (!obs_device || !shared_handle) return nullptr;

    // Check if OBS device changed (need to invalidate cache)
    if (cached_obs_device_ != obs_device) {
        release_shared_cache();
        cached_obs_device_ = obs_device;
    }

    // Look for cached entry
    for (size_t i = 0; i < SHARED_CACHE_SIZE; i++) {
        if (shared_cache_[i].shared_handle == shared_handle) {
            return shared_cache_[i].opened_texture;
        }
    }

    // Not cached, open it
    ComPtr<ID3D11Texture2D> opened;
    HRESULT hr = obs_device->OpenSharedResource(
        static_cast<HANDLE>(shared_handle),
        __uuidof(ID3D11Texture2D),
        (void**)&opened);

    if (FAILED(hr) || !opened) {
        blog(LOG_WARNING, "[avolocam] OpenSharedResource failed: 0x%08X", hr);
        return nullptr;
    }

    // Find empty slot or reuse oldest
    for (size_t i = 0; i < SHARED_CACHE_SIZE; i++) {
        if (!shared_cache_[i].opened_texture) {
            shared_cache_[i].shared_handle = shared_handle;
            shared_cache_[i].opened_texture = opened;
            blog(LOG_DEBUG, "[avolocam] Cached shared texture in slot %zu", i);
            return shared_cache_[i].opened_texture;
        }
    }

    // Cache full, replace slot 0 (simple LRU)
    shared_cache_[0].shared_handle = shared_handle;
    shared_cache_[0].opened_texture = opened;
    blog(LOG_DEBUG, "[avolocam] Replaced shared texture cache slot 0");
    return shared_cache_[0].opened_texture;
}

void TextureOutput::release_win_texture()
{
    win_staging_texture_.Clear();

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
    return preferred_mode_ == OutputMode::GPU_ZERO_COPY &&
           obs_is_d3d11_backend() &&
           get_obs_d3d11_device() != nullptr;
}

OutputResult TextureOutput::output_frame(const DecodedFrame &frame)
{
    if (!initialized_ || !source_) {
        return {false, OutputMode::CPU_COPY, 0};
    }

    uint64_t start_time = os_gettime_ns();
    OutputResult result;

    // Check for GPU texture - use GPU path if available
    if (frame.has_gpu_texture && frame.gpu_texture &&
        preferred_mode_ == OutputMode::GPU_ZERO_COPY) {
        result = output_via_d3d11(frame);
        if (result.success) {
            zero_copy_frames_++;
            total_frames_++;
            result.operation_time_ns = os_gettime_ns() - start_time;
            return result;
        }
        // Fall through to CPU path
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
        // Convert DecodedFrame to use GPU texture
        DecodedFrame gpu_frame;
        gpu_frame.width = frame.width;
        gpu_frame.height = frame.height;
        gpu_frame.pts = frame.pts;
        gpu_frame.gpu_texture = frame.d3d_texture;
        gpu_frame.has_gpu_texture = true;

        result = output_via_d3d11(gpu_frame);
        if (result.success) {
            zero_copy_frames_++;
            total_frames_++;
            result.operation_time_ns = os_gettime_ns() - start_time;
            return result;
        }
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
    // GPU path using DXGI shared textures for cross-device sharing
    //
    // Pipeline:
    // 1. MF decoder provides NV12 texture on decoder's device (frame.gpu_texture)
    // 2. GPUConverter converts NV12 -> RGBA on decoder's device
    // 3. Get shared handle from RGBA texture (created with D3D11_RESOURCE_MISC_SHARED)
    // 4. Open shared texture on OBS's D3D11 device via OpenSharedResource
    // 5. Copy from shared texture to OBS texture (now same-device copy)
    // 6. Render using OBS graphics API
    //
    // IMPORTANT: CopyResource does NOT work between different D3D11 devices.
    // We must use DXGI shared handles to access the texture from OBS's device.

    if (!frame.has_gpu_texture || !frame.gpu_texture) {
        return {false, OutputMode::GPU_ZERO_COPY, 0};
    }

    GPUConverter *converter = get_gpu_converter();
    if (!converter) {
        // GPU converter not initialized
        return {false, OutputMode::GPU_ZERO_COPY, 0};
    }

    // Convert NV12 to RGBA on decoder's device
    GPUDecodedFrame input;
    input.texture = static_cast<ID3D11Texture2D*>(frame.gpu_texture);
    input.subresource = frame.gpu_subresource;
    input.width = frame.width;
    input.height = frame.height;
    input.pts = frame.pts;
    input.sample_ref = frame.platform_handle;

    ConvertedFrame converted;
    if (!converter->convert(input, converted)) {
        blog(LOG_WARNING, "[avolocam] GPU conversion failed");
        return {false, OutputMode::GPU_ZERO_COPY, 0};
    }

    // Now we have an RGBA texture in converted.rgba_texture on decoder's device
    // We need to share it with OBS's device via DXGI shared handle

    // Verify we have a valid shared handle
    if (!converted.shared_handle) {
        blog(LOG_WARNING, "[avolocam] Converted texture doesn't have shared handle - falling back to CPU");
        converter->release_frame(converted);
        return {false, OutputMode::GPU_ZERO_COPY, 0};
    }

    bool output_success = false;

    obs_enter_graphics();

    // Get OBS's D3D11 device
    ID3D11Device *obs_device = static_cast<ID3D11Device*>(gs_get_device_obj());
    if (!obs_device) {
        blog(LOG_WARNING, "[avolocam] Failed to get OBS D3D11 device");
        obs_leave_graphics();
        converter->release_frame(converted);
        return {false, OutputMode::GPU_ZERO_COPY, 0};
    }

    // Open the shared texture on OBS's device
    // This allows us to access the decoder's RGBA texture from OBS's device
    ComPtr<ID3D11Texture2D> shared_texture;
    HRESULT hr = obs_device->OpenSharedResource(
        converted.shared_handle,
        __uuidof(ID3D11Texture2D),
        (void**)&shared_texture);

    if (FAILED(hr) || !shared_texture) {
        blog(LOG_WARNING, "[avolocam] Failed to open shared texture on OBS device: 0x%08X", hr);
        obs_leave_graphics();
        converter->release_frame(converted);
        return {false, OutputMode::GPU_ZERO_COPY, 0};
    }

    // Check if we need to recreate the OBS output texture
    if (!win_texture_ ||
        win_texture_width_ != converted.width ||
        win_texture_height_ != converted.height) {

        if (win_texture_) {
            gs_texture_destroy(win_texture_);
        }

        // Create OBS texture for final output
        win_texture_ = gs_texture_create(
            converted.width,
            converted.height,
            GS_RGBA,
            1,  // mip levels
            nullptr,  // data
            GS_DYNAMIC);  // Dynamic for updates

        if (win_texture_) {
            win_texture_width_ = converted.width;
            win_texture_height_ = converted.height;
            blog(LOG_INFO, "[avolocam] Created OBS output texture %ux%u for GPU path",
                 converted.width, converted.height);
        }
    }

    if (win_texture_) {
        // Get OBS's D3D11 texture object
        ID3D11Texture2D *obs_texture = static_cast<ID3D11Texture2D*>(
            gs_texture_get_obj(win_texture_));

        if (obs_texture) {
            // Get OBS's device context
            ComPtr<ID3D11DeviceContext> obs_ctx;
            obs_device->GetImmediateContext(&obs_ctx);

            if (obs_ctx) {
                // NOW we can CopyResource because both textures are accessible
                // from the same device (OBS's device):
                // - shared_texture: opened on OBS device via OpenSharedResource
                // - obs_texture: created on OBS device
                obs_ctx->CopyResource(obs_texture, shared_texture);

                // Draw the texture as a source
                gs_effect_t *effect = gs_get_effect();
                if (effect) {
                    gs_technique_t *tech = gs_effect_get_technique(effect, "Draw");
                    if (tech) {
                        gs_technique_begin(tech);
                        gs_technique_begin_pass(tech, 0);

                        gs_effect_set_texture(
                            gs_effect_get_param_by_name(effect, "image"),
                            win_texture_);

                        gs_draw_sprite(win_texture_, 0, converted.width, converted.height);

                        gs_technique_end_pass(tech);
                        gs_technique_end(tech);
                    }
                }

                output_success = true;
            }
        }
    }

    // shared_texture released automatically by ComPtr
    obs_leave_graphics();

    // Release converted frame back to pool
    converter->release_frame(converted);

    return {output_success, OutputMode::GPU_ZERO_COPY, 0};
}

OutputResult TextureOutput::prepare_gpu_frame(const DecodedFrame &frame)
{
    // Prepare GPU texture for video_render callback
    // This converts NV12 to RGBA and stores the result in an OBS texture

    if (!frame.has_gpu_texture || !frame.gpu_texture) {
        return {false, OutputMode::GPU_ZERO_COPY, 0};
    }

    GPUConverter *converter = get_gpu_converter();
    if (!converter) {
        return {false, OutputMode::GPU_ZERO_COPY, 0};
    }

    // Convert NV12 to RGBA on decoder's device
    GPUDecodedFrame input;
    input.texture = static_cast<ID3D11Texture2D*>(frame.gpu_texture);
    input.subresource = frame.gpu_subresource;
    input.width = frame.width;
    input.height = frame.height;
    input.pts = frame.pts;
    input.sample_ref = frame.platform_handle;

    ConvertedFrame converted;
    if (!converter->convert(input, converted)) {
        blog(LOG_WARNING, "[avolocam] GPU conversion failed");
        return {false, OutputMode::GPU_ZERO_COPY, 0};
    }

    if (!converted.shared_handle) {
        blog(LOG_WARNING, "[avolocam] Converted texture has no shared handle");
        converter->release_frame(converted);
        return {false, OutputMode::GPU_ZERO_COPY, 0};
    }

    bool success = false;

    obs_enter_graphics();

    ID3D11Device *obs_device = static_cast<ID3D11Device*>(gs_get_device_obj());
    if (!obs_device) {
        obs_leave_graphics();
        converter->release_frame(converted);
        return {false, OutputMode::GPU_ZERO_COPY, 0};
    }

    // Get or open shared texture on OBS's device (cached to avoid slow OpenSharedResource every frame)
    ID3D11Texture2D *shared_texture = get_or_open_shared_texture(obs_device, converted.shared_handle);

    if (!shared_texture) {
        obs_leave_graphics();
        converter->release_frame(converted);
        return {false, OutputMode::GPU_ZERO_COPY, 0};
    }

    // Create or update OBS texture
    if (!win_texture_ ||
        win_texture_width_ != converted.width ||
        win_texture_height_ != converted.height) {

        if (win_texture_) {
            gs_texture_destroy(win_texture_);
        }

        win_texture_ = gs_texture_create(
            converted.width,
            converted.height,
            GS_RGBA,
            1,
            nullptr,
            0);  // No special flags needed

        if (win_texture_) {
            win_texture_width_ = converted.width;
            win_texture_height_ = converted.height;
            blog(LOG_INFO, "[avolocam] Created GPU output texture %ux%u",
                 converted.width, converted.height);
        }
    }

    if (win_texture_) {
        ID3D11Texture2D *obs_texture = static_cast<ID3D11Texture2D*>(
            gs_texture_get_obj(win_texture_));

        if (obs_texture) {
            ComPtr<ID3D11DeviceContext> obs_ctx;
            obs_device->GetImmediateContext(&obs_ctx);

            if (obs_ctx) {
                // GPU-GPU copy (fast!)
                obs_ctx->CopyResource(obs_texture, shared_texture);

                // Store for video_render
                current_output_texture_ = win_texture_;
                success = true;
            }
        }
    }

    // Note: shared_texture is cached, don't release it here
    obs_leave_graphics();
    converter->release_frame(converted);

    return {success, OutputMode::GPU_ZERO_COPY, 0};
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

OutputResult TextureOutput::output_ffmpeg_gpu_frame(const DecodedFrame &frame, void *shared_handle)
{
    // FFmpeg D3D11VA path: NV12 shared texture → OBS
    // The shared handle comes from FFmpeg's separate D3D11 device
    // We open it ONCE on OBS's device and cache it

    if (!shared_handle || !frame.has_gpu_texture) {
        return {false, OutputMode::GPU_ZERO_COPY, 0};
    }

    bool output_success = false;

    obs_enter_graphics();

    // Get OBS's D3D11 device
    ID3D11Device *obs_device = static_cast<ID3D11Device*>(gs_get_device_obj());
    if (!obs_device) {
        blog(LOG_WARNING, "[avolocam] FFmpeg GPU: Failed to get OBS D3D11 device");
        obs_leave_graphics();
        return {false, OutputMode::GPU_ZERO_COPY, 0};
    }

    // Get or open shared texture (cached to avoid slow OpenSharedResource every frame)
    ID3D11Texture2D *shared_texture = get_or_open_shared_texture(obs_device, shared_handle);

    if (!shared_texture) {
        blog(LOG_WARNING, "[avolocam] FFmpeg GPU: Failed to open shared texture");
        obs_leave_graphics();
        return {false, OutputMode::GPU_ZERO_COPY, 0};
    }

    // Get texture description to verify format
    D3D11_TEXTURE2D_DESC tex_desc;
    shared_texture->GetDesc(&tex_desc);

    // FFmpeg outputs NV12 - we need to convert to RGBA or output directly
    // For now, use CPU path via obs_source_output_video with NV12 format
    // This avoids needing the GPUConverter for FFmpeg path

    // TODO: Use GPUConverter for full GPU path
    // For initial implementation, copy to staging and output via CPU path
    // This still benefits from FFmpeg's potentially lower decode latency

    // Create staging texture if needed
    if (!win_staging_texture_ ||
        win_texture_width_ != tex_desc.Width ||
        win_texture_height_ != tex_desc.Height) {

        win_staging_texture_.Clear();

        D3D11_TEXTURE2D_DESC staging_desc = tex_desc;
        staging_desc.Usage = D3D11_USAGE_STAGING;
        staging_desc.BindFlags = 0;
        staging_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        staging_desc.MiscFlags = 0;

        HRESULT hr = obs_device->CreateTexture2D(&staging_desc, nullptr, &win_staging_texture_);
        if (FAILED(hr)) {
            blog(LOG_ERROR, "[avolocam] FFmpeg GPU: Failed to create staging texture: 0x%08X", hr);
            obs_leave_graphics();
            return {false, OutputMode::GPU_ZERO_COPY, 0};
        }

        win_texture_width_ = tex_desc.Width;
        win_texture_height_ = tex_desc.Height;
        blog(LOG_INFO, "[avolocam] FFmpeg GPU: Created staging texture %ux%u",
             tex_desc.Width, tex_desc.Height);
    }

    // Copy shared texture to staging
    ComPtr<ID3D11DeviceContext> obs_ctx;
    obs_device->GetImmediateContext(&obs_ctx);
    if (obs_ctx) {
        obs_ctx->CopyResource(win_staging_texture_, shared_texture);

        // Map staging and output via CPU path
        D3D11_MAPPED_SUBRESOURCE mapped;
        HRESULT hr = obs_ctx->Map(win_staging_texture_, 0,
                                   D3D11_MAP_READ, 0, &mapped);
        if (SUCCEEDED(hr)) {
            // Create OBS video frame
            struct obs_source_frame obs_frame = {};
            obs_frame.width = tex_desc.Width;
            obs_frame.height = tex_desc.Height;
            obs_frame.format = VIDEO_FORMAT_NV12;
            obs_frame.timestamp = os_gettime_ns();

            // NV12: Y plane is at offset 0, UV plane follows
            size_t y_size = (size_t)mapped.RowPitch * tex_desc.Height;
            obs_frame.data[0] = static_cast<uint8_t*>(mapped.pData);
            obs_frame.data[1] = static_cast<uint8_t*>(mapped.pData) + y_size;
            obs_frame.linesize[0] = mapped.RowPitch;
            obs_frame.linesize[1] = mapped.RowPitch;

            // Color space: Rec.709 full range
            float color_matrix[16];
            float color_range_min[3];
            float color_range_max[3];
            video_format_get_parameters(VIDEO_CS_709, VIDEO_RANGE_FULL,
                                        color_matrix, color_range_min, color_range_max);
            memcpy(obs_frame.color_matrix, color_matrix, sizeof(color_matrix));
            memcpy(obs_frame.color_range_min, color_range_min, sizeof(color_range_min));
            memcpy(obs_frame.color_range_max, color_range_max, sizeof(color_range_max));
            obs_frame.full_range = true;

            obs_source_output_video(source_, &obs_frame);
            output_success = true;

            obs_ctx->Unmap(win_staging_texture_, 0);
        }
    }

    obs_leave_graphics();

    return {output_success, OutputMode::GPU_ZERO_COPY, 0};
}

// Initialize GPU converter with decoder's device
bool TextureOutput::init_gpu_output(void *d3d_device, void *d3d_context)
{
    if (!d3d_device || !d3d_context) {
        return false;
    }

    bool result = init_gpu_converter(
        static_cast<ID3D11Device*>(d3d_device),
        static_cast<ID3D11DeviceContext*>(d3d_context));
    if (result) {
        gpu_converter_acquired_ = true;
    }
    return result;
}

// Platform-level queries
bool platform_supports_zero_copy()
{
    return obs_is_d3d11_backend() && get_obs_d3d11_device() != nullptr;
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
