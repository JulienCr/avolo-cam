/**
 * ffmpeg-d3d11va-decoder.h - FFmpeg D3D11VA H.264 decoder
 *
 * Hardware-accelerated decoder using FFmpeg with D3D11VA backend.
 * Uses a SEPARATE D3D11 device (not OBS's) for decode operations,
 * with shared textures for cross-device GPU transfer.
 *
 * Key architectural decisions:
 * - Decode thread has its own D3D11 device (no lock contention with OBS)
 * - Output textures use D3D11_RESOURCE_MISC_SHARED for cross-device sharing
 * - OpenSharedResource is called ONCE per handle (cached in TextureOutput)
 * - Explicit CPU fallback if hardware path fails
 * - No FF_THREAD_FRAME (adds latency due to buffering)
 */

#pragma once

#include "platform-decoder.h"

#if defined(_WIN32) && defined(HAVE_FFMPEG_D3D11VA)

#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <mutex>
#include <vector>

// Forward declarations for FFmpeg types
extern "C" {
struct AVCodec;
struct AVCodecContext;
struct AVBufferRef;
struct AVFrame;
struct AVPacket;
}

namespace avolocam {

/**
 * FFmpeg D3D11VA H.264 decoder implementation
 *
 * Architecture: "Separate Device + Shared Texture"
 * - Decode thread operates on its own D3D11 device (no OBS lock contention)
 * - Decoded frames are copied to shared textures (D3D11_RESOURCE_MISC_SHARED)
 * - OBS render thread opens shared textures ONCE and caches them
 * - GPU→GPU copy is fast (~1ms) when on same physical adapter
 */
class FFmpegD3D11VADecoder : public PlatformDecoder {
public:
    FFmpegD3D11VADecoder(const DecoderConfig &config);
    ~FFmpegD3D11VADecoder() override;

    // Non-copyable
    FFmpegD3D11VADecoder(const FFmpegD3D11VADecoder&) = delete;
    FFmpegD3D11VADecoder& operator=(const FFmpegD3D11VADecoder&) = delete;

    // PlatformDecoder interface
    bool initialize(const uint8_t *sps, size_t sps_size,
                    const uint8_t *pps, size_t pps_size) override;
    bool decode(const uint8_t *data, size_t size, DecodedFrame &out) override;
    void flush() override;
    void reset() override;
    uint32_t get_width() const override;
    uint32_t get_height() const override;
    bool is_hardware() const override;
    const char *get_name() const override;
    bool is_initialized() const override;
    const DecodeTimingStats &get_timing_stats() const override;
    void reset_timing_stats() override;
    bool supports_gpu_output() const override;
    bool set_gpu_output(bool enable) override;

    // D3D11 device access (returns OUR device, not OBS's)
    void *get_d3d_device() const override { return d3d_device_; }
    void *get_d3d_context() const override { return d3d_context_; }

    /**
     * Get current shared handle for OBS to open
     * This handle is stable and should be cached by TextureOutput
     */
    HANDLE get_current_shared_handle() const { return current_shared_handle_; }

    /**
     * Check if D3D11VA hardware acceleration is available
     */
    static bool is_available();

private:
    DecoderConfig config_;

    // FFmpeg objects
    const AVCodec *codec_ = nullptr;
    AVCodecContext *codec_ctx_ = nullptr;
    AVBufferRef *hw_device_ctx_ = nullptr;
    AVFrame *frame_ = nullptr;
    AVFrame *sw_frame_ = nullptr;  // For CPU fallback
    AVPacket *packet_ = nullptr;

    // D3D11 device - SEPARATE from OBS (decode thread doesn't touch OBS graphics)
    ID3D11Device *d3d_device_ = nullptr;
    ID3D11DeviceContext *d3d_context_ = nullptr;

    // Shared texture pool for output (triple buffering)
    struct SharedTexture {
        ID3D11Texture2D *texture = nullptr;
        HANDLE shared_handle = nullptr;
        bool in_use = false;
        uint32_t width = 0;
        uint32_t height = 0;
    };
    static constexpr size_t SHARED_POOL_SIZE = 3;
    SharedTexture shared_pool_[SHARED_POOL_SIZE];
    HANDLE current_shared_handle_ = nullptr;
    size_t current_shared_index_ = 0;

    // Output buffer for CPU fallback path
    std::vector<uint8_t> output_buffer_;

    // Video dimensions (parsed from SPS)
    uint32_t width_ = 0;
    uint32_t height_ = 0;

    // Cached parameter sets (Annex-B format)
    std::vector<uint8_t> sps_;
    std::vector<uint8_t> pps_;

    // State
    bool initialized_ = false;
    bool hardware_mode_ = true;     // false = software fallback active
    bool gpu_output_enabled_ = true;
    bool decoder_flushed_ = false;

    // Timing instrumentation
    mutable DecodeTimingStats timing_stats_;

    // ============ Internal Methods ============

    /**
     * Create our own D3D11 device (NOT OBS's device!)
     * This avoids lock contention with OBS graphics mutex
     */
    bool init_d3d11_device();

    /**
     * Initialize FFmpeg with D3D11VA hardware context
     */
    bool init_ffmpeg_hwaccel();

    /**
     * Create or resize the shared texture pool
     */
    bool create_shared_texture_pool(uint32_t width, uint32_t height);

    /**
     * Release shared texture pool
     */
    void release_shared_texture_pool();

    /**
     * Get next available shared texture (round-robin)
     */
    SharedTexture* get_available_shared_texture();

    /**
     * Copy decoded GPU frame to shared texture
     * @param frame FFmpeg AVFrame with hw_frames_ctx (AV_PIX_FMT_D3D11)
     * @param out_shared Output shared texture pointer
     * @return true on success
     */
    bool copy_to_shared_texture(AVFrame *frame, SharedTexture *out_shared);

    /**
     * Explicit CPU fallback when GPU path fails
     * Uses av_hwframe_transfer_data() - SLOW but reliable
     */
    bool decode_software_fallback(AVFrame *frame, DecodedFrame &out);

    /**
     * Parse SPS for video dimensions
     */
    bool parse_sps_dimensions(const uint8_t *sps, size_t size);

    /**
     * Build Annex-B extradata from SPS/PPS for FFmpeg
     */
    bool build_annexb_extradata();

    /**
     * Destroy FFmpeg decoder resources
     */
    void destroy_decoder();

    /**
     * Destroy D3D11 device resources
     */
    void destroy_d3d11();

    /**
     * FFmpeg format callback to prefer D3D11
     */
    static enum AVPixelFormat get_hw_format(AVCodecContext *ctx,
                                            const enum AVPixelFormat *pix_fmts);
};

} // namespace avolocam

#endif // _WIN32 && HAVE_FFMPEG_D3D11VA
