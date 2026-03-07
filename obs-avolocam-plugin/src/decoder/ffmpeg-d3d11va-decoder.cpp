/**
 * ffmpeg-d3d11va-decoder.cpp - FFmpeg D3D11VA H.264 decoder implementation
 *
 * Key design:
 * - Separate D3D11 device (decode thread doesn't lock OBS graphics)
 * - Shared texture pool for GPU output
 * - Low-latency flags: AV_CODEC_FLAG_LOW_DELAY, no frame threading
 * - Explicit CPU fallback (av_hwframe_transfer_data) only when GPU fails
 */

#include "ffmpeg-d3d11va-decoder.h"
#include "../logging.h"

#if defined(_WIN32) && defined(HAVE_FFMPEG_D3D11VA)

#include <obs-module.h>
#include <d3d10.h>  // For ID3D10Multithread
#include <algorithm>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_d3d11va.h>
#include <libavutil/pixfmt.h>
#include <libavutil/imgutils.h>
}

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")

// High-resolution timing
namespace {
    inline uint64_t get_time_ns() {
        LARGE_INTEGER freq, counter;
        QueryPerformanceFrequency(&freq);
        QueryPerformanceCounter(&counter);
        return (uint64_t)((counter.QuadPart * 1000000000LL) / freq.QuadPart);
    }
}

// FFmpeg format callback - must be outside namespace to match FFmpeg's expected signature
static enum AVPixelFormat ffmpeg_get_hw_format(
    AVCodecContext *ctx, const enum AVPixelFormat *pix_fmts)
{
    (void)ctx;

    // Prefer D3D11 hardware format
    for (const enum AVPixelFormat *p = pix_fmts; *p != AV_PIX_FMT_NONE; p++) {
        if (*p == AV_PIX_FMT_D3D11) {
            ALOG_FFMPEG(LOG_DEBUG, "Selected D3D11 pixel format");
            return AV_PIX_FMT_D3D11;
        }
    }

    // Fallback to NV12 software
    ALOG_FFMPEG(LOG_WARNING, "D3D11 format unavailable, falling back to software");
    for (const enum AVPixelFormat *p = pix_fmts; *p != AV_PIX_FMT_NONE; p++) {
        if (*p == AV_PIX_FMT_NV12 || *p == AV_PIX_FMT_YUV420P) {
            return *p;
        }
    }

    return AV_PIX_FMT_NONE;
}

namespace avolocam {

// Store decoder pointer for format callback
static thread_local FFmpegD3D11VADecoder *g_current_decoder = nullptr;

FFmpegD3D11VADecoder::FFmpegD3D11VADecoder(const DecoderConfig &config)
    : config_(config)
{
    ALOG_FFMPEG(LOG_INFO, "Creating FFmpeg D3D11VA decoder");
}

FFmpegD3D11VADecoder::~FFmpegD3D11VADecoder()
{
    destroy_decoder();
    destroy_d3d11();
    ALOG_FFMPEG(LOG_INFO, "FFmpeg D3D11VA decoder destroyed");
}

bool FFmpegD3D11VADecoder::is_available()
{
    // Check if D3D11 is available
    ComPtr<ID3D11Device> test_device;
    D3D_FEATURE_LEVEL feature_level;
    HRESULT hr = D3D11CreateDevice(
        nullptr,
        D3D_DRIVER_TYPE_HARDWARE,
        nullptr,
        D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
        nullptr, 0,
        D3D11_SDK_VERSION,
        &test_device,
        &feature_level,
        nullptr);

    if (SUCCEEDED(hr) && test_device) {
        // Check if FFmpeg has H.264 decoder
        const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_H264);
        if (codec) {
            ALOG_FFMPEG(LOG_INFO, "D3D11VA is available (feature level %d.%d)",
                 (feature_level >> 12) & 0xF, (feature_level >> 8) & 0xF);
            return true;
        }
    }

    ALOG_FFMPEG(LOG_WARNING, "D3D11VA not available");
    return false;
}

bool FFmpegD3D11VADecoder::init_d3d11_device()
{
    if (d3d_device_) {
        return true;
    }

    // Create our OWN D3D11 device (not OBS's!)
    // This is critical: decode thread should not touch OBS graphics context
    D3D_FEATURE_LEVEL feature_levels[] = {
        D3D_FEATURE_LEVEL_11_1,
        D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_1,
        D3D_FEATURE_LEVEL_10_0,
    };

    UINT flags = D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
#ifdef _DEBUG
    flags |= D3D11_CREATE_DEVICE_DEBUG;
#endif

    D3D_FEATURE_LEVEL actual_level;
    HRESULT hr = D3D11CreateDevice(
        nullptr,                    // Default adapter (same GPU as OBS)
        D3D_DRIVER_TYPE_HARDWARE,
        nullptr,
        flags,
        feature_levels,
        ARRAYSIZE(feature_levels),
        D3D11_SDK_VERSION,
        &d3d_device_,
        &actual_level,
        &d3d_context_);

    if (FAILED(hr)) {
        ALOG_FFMPEG(LOG_ERROR, "Failed to create D3D11 device: 0x%08X", hr);
        return false;
    }

    // Enable multithread protection (FFmpeg may call from multiple threads)
    ComQIPtr<ID3D10Multithread> mt(d3d_device_);
    if (mt) {
        mt->SetMultithreadProtected(TRUE);
    }

    ALOG_FFMPEG(LOG_INFO, "Created separate D3D11 device (feature level %d.%d)",
         (actual_level >> 12) & 0xF, (actual_level >> 8) & 0xF);
    return true;
}

bool FFmpegD3D11VADecoder::init_ffmpeg_hwaccel()
{
    // Find H.264 decoder
    codec_ = avcodec_find_decoder(AV_CODEC_ID_H264);
    if (!codec_) {
        ALOG_FFMPEG(LOG_ERROR, "H.264 decoder not found");
        return false;
    }

    // Create codec context
    codec_ctx_ = avcodec_alloc_context3(codec_);
    if (!codec_ctx_) {
        ALOG_FFMPEG(LOG_ERROR, "Failed to allocate codec context");
        return false;
    }

    // Low-latency flags - CRITICAL for <150ms target
    codec_ctx_->flags |= AV_CODEC_FLAG_LOW_DELAY;
    codec_ctx_->flags2 |= AV_CODEC_FLAG2_FAST;

    // NO frame threading (adds latency due to buffering)
    codec_ctx_->thread_count = 1;
    codec_ctx_->thread_type = 0;

    // Output even corrupt frames (for resilience)
    codec_ctx_->flags |= AV_CODEC_FLAG_OUTPUT_CORRUPT;

    // Set dimensions if known
    if (width_ > 0 && height_ > 0) {
        codec_ctx_->width = width_;
        codec_ctx_->height = height_;
    }

    // CRITICAL: Set extradata BEFORE opening codec
    // Build Annex-B format: [00 00 00 01][SPS][00 00 00 01][PPS]
    if (!sps_.empty() && !pps_.empty()) {
        size_t extradata_size = 4 + sps_.size() + 4 + pps_.size();
        codec_ctx_->extradata = (uint8_t *)av_mallocz(extradata_size + AV_INPUT_BUFFER_PADDING_SIZE);
        if (codec_ctx_->extradata) {
            uint8_t *p = codec_ctx_->extradata;
            // SPS with start code
            p[0] = 0; p[1] = 0; p[2] = 0; p[3] = 1;
            memcpy(p + 4, sps_.data(), sps_.size());
            p += 4 + sps_.size();
            // PPS with start code
            p[0] = 0; p[1] = 0; p[2] = 0; p[3] = 1;
            memcpy(p + 4, pps_.data(), pps_.size());
            codec_ctx_->extradata_size = (int)extradata_size;
            ALOG_FFMPEG(LOG_INFO, "Set extradata (SPS=%zu, PPS=%zu) BEFORE codec open",
                 sps_.size(), pps_.size());
        }
    }

    // Create D3D11VA hardware device context with our device
    if (hardware_mode_ && d3d_device_) {
        // Allocate hw device context
        hw_device_ctx_ = av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_D3D11VA);
        if (hw_device_ctx_) {
            AVHWDeviceContext *hw_ctx = (AVHWDeviceContext *)hw_device_ctx_->data;
            AVD3D11VADeviceContext *d3d11_ctx = (AVD3D11VADeviceContext *)hw_ctx->hwctx;

            // Use our D3D11 device (FFmpeg takes its own reference)
            d3d11_ctx->device = d3d_device_.Get();
            d3d_device_->AddRef();
            d3d11_ctx->device_context = d3d_context_.Get();
            d3d_context_->AddRef();

            // Initialize the hardware context
            int ret = av_hwdevice_ctx_init(hw_device_ctx_);
            if (ret < 0) {
                char errbuf[128];
                av_strerror(ret, errbuf, sizeof(errbuf));
                ALOG_FFMPEG(LOG_WARNING, "Failed to init D3D11VA context: %s", errbuf);
                av_buffer_unref(&hw_device_ctx_);
                hardware_mode_ = false;
            } else {
                codec_ctx_->hw_device_ctx = av_buffer_ref(hw_device_ctx_);
                codec_ctx_->get_format = ffmpeg_get_hw_format;
                ALOG_FFMPEG(LOG_INFO, "D3D11VA hardware context initialized with our device");
            }
        } else {
            ALOG_FFMPEG(LOG_WARNING, "Failed to allocate D3D11VA hw context");
            hardware_mode_ = false;
        }
    }

    // Open codec
    int ret = avcodec_open2(codec_ctx_, codec_, nullptr);
    if (ret < 0) {
        char errbuf[128];
        av_strerror(ret, errbuf, sizeof(errbuf));
        ALOG_FFMPEG(LOG_ERROR, "Failed to open codec: %s", errbuf);
        return false;
    }

    ALOG_FFMPEG(LOG_INFO, "Codec opened successfully (hw=%s)",
         hardware_mode_ ? "yes" : "no");

    // Allocate frames
    frame_ = av_frame_alloc();
    sw_frame_ = av_frame_alloc();
    packet_ = av_packet_alloc();

    if (!frame_ || !sw_frame_ || !packet_) {
        ALOG_FFMPEG(LOG_ERROR, "Failed to allocate frame/packet");
        return false;
    }

    ALOG_FFMPEG(LOG_INFO, "Decoder initialized (hardware=%s)",
         hardware_mode_ ? "yes" : "no");
    return true;
}

bool FFmpegD3D11VADecoder::create_shared_texture_pool(uint32_t width, uint32_t height)
{
    // Check if current pool is sufficient
    if (shared_pool_[0].texture &&
        shared_pool_[0].width == width &&
        shared_pool_[0].height == height) {
        return true;
    }

    release_shared_texture_pool();

    D3D11_TEXTURE2D_DESC desc = {};
    desc.Width = width;
    desc.Height = height;
    desc.MipLevels = 1;
    desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_NV12;
    desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;  // CRITICAL for cross-device sharing

    for (size_t i = 0; i < SHARED_POOL_SIZE; i++) {
        HRESULT hr = d3d_device_->CreateTexture2D(&desc, nullptr, &shared_pool_[i].texture);
        if (FAILED(hr)) {
            ALOG_FFMPEG(LOG_ERROR, "Failed to create shared texture %zu: 0x%08X",
                 i, hr);
            release_shared_texture_pool();
            return false;
        }

        // Get shared handle (stable, can be cached by OBS)
        ComQIPtr<IDXGIResource> dxgi_res(shared_pool_[i].texture);
        if (dxgi_res) {
            dxgi_res->GetSharedHandle(&shared_pool_[i].shared_handle);
        }

        shared_pool_[i].width = width;
        shared_pool_[i].height = height;
        shared_pool_[i].in_use = false;

        ALOG_FFMPEG(LOG_DEBUG, "Created shared texture %zu (%ux%u, handle=%p)",
             i, width, height, shared_pool_[i].shared_handle);
    }

    ALOG_FFMPEG(LOG_INFO, "Created shared texture pool %ux%u (pool size=%zu)",
         width, height, SHARED_POOL_SIZE);
    return true;
}

void FFmpegD3D11VADecoder::release_shared_texture_pool()
{
    for (size_t i = 0; i < SHARED_POOL_SIZE; i++) {
        shared_pool_[i].texture.Clear();
        shared_pool_[i].shared_handle = nullptr;
        shared_pool_[i].in_use = false;
        shared_pool_[i].width = 0;
        shared_pool_[i].height = 0;
    }
    current_shared_handle_ = nullptr;
}

FFmpegD3D11VADecoder::SharedTexture* FFmpegD3D11VADecoder::get_available_shared_texture()
{
    // Simple round-robin - with 3 textures and GPU copy being fast,
    // we don't need complex in_use tracking. Just rotate through the pool.
    // By the time we come back to a texture, it should be done being used.
    size_t idx = current_shared_index_;
    current_shared_index_ = (current_shared_index_ + 1) % SHARED_POOL_SIZE;
    return &shared_pool_[idx];
}

bool FFmpegD3D11VADecoder::copy_to_shared_texture(AVFrame *frame, SharedTexture *out_shared)
{
    if (!frame || !out_shared || !out_shared->texture) {
        return false;
    }

    // Get D3D11 texture from AVFrame
    // frame->data[0] is ID3D11Texture2D*
    // frame->data[1] is subresource index
    ID3D11Texture2D *src_texture = (ID3D11Texture2D *)frame->data[0];
    intptr_t subresource = (intptr_t)frame->data[1];

    if (!src_texture) {
        ALOG_FFMPEG(LOG_ERROR, "AVFrame has no D3D11 texture");
        return false;
    }

    // Copy source region to our shared texture
    // This is a GPU→GPU copy on the same device, very fast
    d3d_context_->CopySubresourceRegion(
        out_shared->texture, 0,     // Dest texture, subresource 0
        0, 0, 0,                    // Dest x, y, z
        src_texture, (UINT)subresource,  // Src texture, subresource
        nullptr);                   // Copy entire resource

    return true;
}

bool FFmpegD3D11VADecoder::decode_software_fallback(AVFrame *frame, DecodedFrame &out)
{
    // This is the EXPLICIT fallback path - only used when GPU fails
    // Uses av_hwframe_transfer_data which is SLOW but reliable

    AVFrame *src_frame = frame;
    AVFrame *cpu_frame = sw_frame_;

    // If frame is hardware, transfer to CPU
    if (frame->format == AV_PIX_FMT_D3D11) {
        int ret = av_hwframe_transfer_data(cpu_frame, frame, 0);
        if (ret < 0) {
            ALOG_FFMPEG(LOG_ERROR, "av_hwframe_transfer_data failed: %d", ret);
            return false;
        }
        src_frame = cpu_frame;
    }

    // Ensure we have NV12 or YUV420P
    if (src_frame->format != AV_PIX_FMT_NV12 && src_frame->format != AV_PIX_FMT_YUV420P) {
        ALOG_FFMPEG(LOG_ERROR, "Unsupported software format: %d", src_frame->format);
        return false;
    }

    // NV12: Y plane + interleaved UV plane
    if (src_frame->format == AV_PIX_FMT_NV12) {
        size_t y_size = (size_t)src_frame->linesize[0] * src_frame->height;
        size_t uv_size = (size_t)src_frame->linesize[1] * (src_frame->height / 2);
        size_t total_size = y_size + uv_size;

        if (output_buffer_.size() < total_size) {
            output_buffer_.resize(total_size);
        }

        memcpy(output_buffer_.data(), src_frame->data[0], y_size);
        memcpy(output_buffer_.data() + y_size, src_frame->data[1], uv_size);

        out.y_plane = output_buffer_.data();
        out.uv_plane = output_buffer_.data() + y_size;
        out.y_stride = src_frame->linesize[0];
        out.uv_stride = src_frame->linesize[1];
    }
    // YUV420P: Convert to NV12 (interleave U and V)
    else if (src_frame->format == AV_PIX_FMT_YUV420P) {
        size_t y_size = (size_t)src_frame->linesize[0] * src_frame->height;
        size_t uv_width = (src_frame->width + 1) / 2;
        size_t uv_height = (src_frame->height + 1) / 2;
        size_t uv_stride = uv_width * 2;  // Interleaved UV
        size_t uv_size = uv_stride * uv_height;
        size_t total_size = y_size + uv_size;

        if (output_buffer_.size() < total_size) {
            output_buffer_.resize(total_size);
        }

        // Copy Y plane
        memcpy(output_buffer_.data(), src_frame->data[0], y_size);

        // Interleave U and V planes to NV12
        uint8_t *uv_dst = output_buffer_.data() + y_size;
        for (size_t row = 0; row < uv_height; row++) {
            const uint8_t *u_src = src_frame->data[1] + row * src_frame->linesize[1];
            const uint8_t *v_src = src_frame->data[2] + row * src_frame->linesize[2];
            uint8_t *dst = uv_dst + row * uv_stride;
            for (size_t col = 0; col < uv_width; col++) {
                dst[col * 2] = u_src[col];
                dst[col * 2 + 1] = v_src[col];
            }
        }

        out.y_plane = output_buffer_.data();
        out.uv_plane = output_buffer_.data() + y_size;
        out.y_stride = src_frame->linesize[0];
        out.uv_stride = (uint32_t)uv_stride;
    }

    out.width = src_frame->width;
    out.height = src_frame->height;
    out.has_gpu_texture = false;
    out.owns_memory = true;

    return true;
}

bool FFmpegD3D11VADecoder::parse_sps_dimensions(const uint8_t *sps, size_t size)
{
    // Minimal SPS parsing for baseline dimensions
    // Full parsing would require exp-golomb decoding
    if (size < 4) return false;

    // Use configured max dimensions as fallback
    // Real dimensions will be in the decoded frame
    width_ = config_.max_width;
    height_ = config_.max_height;

    return true;
}

bool FFmpegD3D11VADecoder::build_annexb_extradata()
{
    // FFmpeg expects Annex-B format extradata
    // Format: [00 00 00 01][SPS][00 00 00 01][PPS]

    if (sps_.empty() || pps_.empty()) {
        return false;
    }

    size_t extradata_size = 4 + sps_.size() + 4 + pps_.size();

    // Allocate with padding (FFmpeg requirement)
    codec_ctx_->extradata = (uint8_t *)av_mallocz(extradata_size + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!codec_ctx_->extradata) {
        return false;
    }

    uint8_t *p = codec_ctx_->extradata;

    // SPS with start code
    p[0] = 0; p[1] = 0; p[2] = 0; p[3] = 1;
    memcpy(p + 4, sps_.data(), sps_.size());
    p += 4 + sps_.size();

    // PPS with start code
    p[0] = 0; p[1] = 0; p[2] = 0; p[3] = 1;
    memcpy(p + 4, pps_.data(), pps_.size());

    codec_ctx_->extradata_size = (int)extradata_size;

    ALOG_FFMPEG(LOG_INFO, "Built Annex-B extradata (SPS=%zu, PPS=%zu)",
         sps_.size(), pps_.size());
    return true;
}

bool FFmpegD3D11VADecoder::initialize(const uint8_t *sps, size_t sps_size,
                                       const uint8_t *pps, size_t pps_size)
{
    if (!sps || sps_size == 0 || !pps || pps_size == 0) {
        ALOG_FFMPEG(LOG_ERROR, "Invalid SPS/PPS data");
        return false;
    }

    // Store parameter sets
    sps_.assign(sps, sps + sps_size);
    pps_.assign(pps, pps + pps_size);

    // Parse SPS for dimensions
    if (!parse_sps_dimensions(sps, sps_size)) {
        ALOG_FFMPEG(LOG_ERROR, "Failed to parse SPS");
        return false;
    }

    // Initialize D3D11 device (our own, not OBS's)
    if (config_.prefer_hardware) {
        if (!init_d3d11_device()) {
            ALOG_FFMPEG(LOG_WARNING, "D3D11 init failed, will use software");
            hardware_mode_ = false;
        }
    } else {
        hardware_mode_ = false;
    }

    // Initialize FFmpeg decoder (extradata is set inside)
    if (!init_ffmpeg_hwaccel()) {
        ALOG_FFMPEG(LOG_ERROR, "Failed to initialize decoder");
        return false;
    }

    initialized_ = true;
    ALOG_FFMPEG(LOG_INFO, "D3D11VA decoder initialized: %ux%u, hardware=%s",
         width_, height_, hardware_mode_ ? "yes" : "no");
    return true;
}

bool FFmpegD3D11VADecoder::decode(const uint8_t *data, size_t size, DecodedFrame &out)
{
    if (!initialized_ || !codec_ctx_ || !data || size == 0) {
        return false;
    }

    uint64_t start_time = get_time_ns();

    // Debug: log first access unit's start bytes (only first few times)
    static int debug_count = 0;
    if (debug_count < 5 && size >= 8) {
        ALOG_FFMPEG(LOG_INFO, "Input AU size=%zu, start=[%02X %02X %02X %02X %02X %02X %02X %02X]",
             size, data[0], data[1], data[2], data[3], data[4], data[5], data[6], data[7]);
        debug_count++;
    }

    // Setup packet (input is Annex-B, which FFmpeg expects)
    packet_->data = (uint8_t *)data;
    packet_->size = (int)size;

    // Send packet to decoder
    uint64_t send_start = get_time_ns();
    int ret = avcodec_send_packet(codec_ctx_, packet_);
    timing_stats_.process_input_ns = get_time_ns() - send_start;

    if (ret < 0 && ret != AVERROR(EAGAIN)) {
        if (ret != AVERROR_EOF) {
            char errbuf[128];
            av_strerror(ret, errbuf, sizeof(errbuf));
            ALOG_FFMPEG(LOG_WARNING, "avcodec_send_packet failed: %s (%d)", errbuf, ret);
        }
        return false;
    }

    // Receive decoded frame
    uint64_t recv_start = get_time_ns();
    ret = avcodec_receive_frame(codec_ctx_, frame_);
    timing_stats_.process_output_ns = get_time_ns() - recv_start;

    if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
        // Need more data
        return false;
    }
    if (ret < 0) {
        char errbuf[128];
        av_strerror(ret, errbuf, sizeof(errbuf));
        ALOG_FFMPEG(LOG_WARNING, "avcodec_receive_frame failed: %s", errbuf);
        return false;
    }

    // Update dimensions from decoded frame
    if ((uint32_t)frame_->width != width_ || (uint32_t)frame_->height != height_) {
        width_ = frame_->width;
        height_ = frame_->height;
        ALOG_FFMPEG(LOG_INFO, "Resolution update %ux%u", width_, height_);
    }

    // GPU texture output path: copy decoded frame to shared texture
    if (gpu_output_enabled_ && hardware_mode_ && d3d_device_ &&
        frame_->format == AV_PIX_FMT_D3D11) {

        // Create shared texture pool if needed
        if (!create_shared_texture_pool(width_, height_)) {
            ALOG_FFMPEG(LOG_WARNING, "Failed to create shared pool, falling back to CPU");
            goto cpu_fallback;
        }

        // Get next shared texture from pool
        SharedTexture *shared = get_available_shared_texture();
        if (!shared || !shared->texture) {
            ALOG_FFMPEG(LOG_WARNING, "No shared texture available, falling back to CPU");
            goto cpu_fallback;
        }

        // GPU→GPU copy (same device, <0.5ms)
        if (!copy_to_shared_texture(frame_, shared)) {
            ALOG_FFMPEG(LOG_WARNING, "Copy to shared texture failed, falling back to CPU");
            goto cpu_fallback;
        }

        // Flush to submit GPU commands (non-blocking)
        d3d_context_->Flush();

        // Update current shared handle
        current_shared_handle_ = shared->shared_handle;

        // Fill output with GPU info
        out.width = width_;
        out.height = height_;
        out.has_gpu_texture = true;
        out.gpu_texture = shared->texture;
        // NV12 shared handle stored for completeness; the GPU zero-copy path
        // uses gpu_texture directly (same D3D device) and GPUConverter produces
        // its own RGBA shared handle for cross-device sharing with OBS.
        out.shared_handle = shared->shared_handle;
        out.y_plane = nullptr;
        out.uv_plane = nullptr;

        timing_stats_.lock_buffer_ns = 0;
        timing_stats_.memcpy_ns = 0;
        timing_stats_.total_decode_ns = get_time_ns() - start_time;
        timing_stats_.accumulate();
        timing_stats_.reset_per_frame();

        av_frame_unref(frame_);
        return true;
    }

cpu_fallback:
    {
        // CPU fallback: av_hwframe_transfer_data (slow but reliable)
        timing_stats_.lock_buffer_ns = 0;
        uint64_t fallback_start = get_time_ns();

        bool success = decode_software_fallback(frame_, out);

        timing_stats_.memcpy_ns = get_time_ns() - fallback_start;
        timing_stats_.total_decode_ns = get_time_ns() - start_time;
        timing_stats_.accumulate();
        timing_stats_.reset_per_frame();

        av_frame_unref(frame_);
        return success;
    }
}

void FFmpegD3D11VADecoder::flush()
{
    if (!codec_ctx_ || decoder_flushed_) return;

    // Send flush packet
    avcodec_send_packet(codec_ctx_, nullptr);

    // Drain remaining frames
    while (avcodec_receive_frame(codec_ctx_, frame_) == 0) {
        av_frame_unref(frame_);
    }

    decoder_flushed_ = true;
}

void FFmpegD3D11VADecoder::reset()
{
    if (!codec_ctx_) return;

    avcodec_flush_buffers(codec_ctx_);
    decoder_flushed_ = false;

    // Mark all shared textures as available
    for (size_t i = 0; i < SHARED_POOL_SIZE; i++) {
        shared_pool_[i].in_use = false;
    }
}

uint32_t FFmpegD3D11VADecoder::get_width() const
{
    return width_;
}

uint32_t FFmpegD3D11VADecoder::get_height() const
{
    return height_;
}

bool FFmpegD3D11VADecoder::is_hardware() const
{
    return hardware_mode_;
}

const char *FFmpegD3D11VADecoder::get_name() const
{
    return hardware_mode_ ? "FFmpeg D3D11VA" : "FFmpeg Software";
}

bool FFmpegD3D11VADecoder::is_initialized() const
{
    return initialized_;
}

const DecodeTimingStats &FFmpegD3D11VADecoder::get_timing_stats() const
{
    return timing_stats_;
}

void FFmpegD3D11VADecoder::reset_timing_stats()
{
    timing_stats_ = DecodeTimingStats{};
}

bool FFmpegD3D11VADecoder::supports_gpu_output() const
{
    return hardware_mode_ && d3d_device_ != nullptr;
}

bool FFmpegD3D11VADecoder::set_gpu_output(bool enable)
{
    if (enable && !supports_gpu_output()) {
        ALOG_FFMPEG(LOG_WARNING, "GPU output requested but not supported");
        return false;
    }
    gpu_output_enabled_ = enable;
    ALOG_FFMPEG(LOG_INFO, "GPU output %s", enable ? "enabled" : "disabled");
    return true;
}

void FFmpegD3D11VADecoder::destroy_decoder()
{
    if (packet_) {
        av_packet_free(&packet_);
        packet_ = nullptr;
    }

    if (sw_frame_) {
        av_frame_free(&sw_frame_);
        sw_frame_ = nullptr;
    }

    if (frame_) {
        av_frame_free(&frame_);
        frame_ = nullptr;
    }

    if (codec_ctx_) {
        avcodec_free_context(&codec_ctx_);
        codec_ctx_ = nullptr;
    }

    if (hw_device_ctx_) {
        av_buffer_unref(&hw_device_ctx_);
        hw_device_ctx_ = nullptr;
    }

    codec_ = nullptr;
    initialized_ = false;
}

void FFmpegD3D11VADecoder::destroy_d3d11()
{
    release_shared_texture_pool();
    d3d_context_.Clear();
    d3d_device_.Clear();
}

// Factory method implementation for Windows
std::unique_ptr<PlatformDecoder> PlatformDecoder::create(const DecoderConfig &config)
{
    ALOG_FFMPEG(LOG_INFO, "Creating FFmpeg D3D11VA decoder");
    if (FFmpegD3D11VADecoder::is_available()) {
        return std::make_unique<FFmpegD3D11VADecoder>(config);
    }
    ALOG_FFMPEG(LOG_ERROR, "FFmpeg D3D11VA decoder not available");
    return nullptr;
}

} // namespace avolocam

#endif // _WIN32 && HAVE_FFMPEG_D3D11VA
