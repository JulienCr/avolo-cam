/**
 * mf-decoder.h - Windows Media Foundation H.264 decoder
 *
 * Hardware-accelerated decoder using Windows Media Foundation.
 * Uses D3D11VA when available for GPU decoding.
 */

#pragma once

#include "platform-decoder.h"

#ifdef _WIN32

#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <d3d11.h>
#include <dxgi.h>
#include <mutex>
#include <deque>
#include <vector>
#include <memory>

namespace avolocam {

/**
 * Media Foundation H.264 decoder implementation
 */
class MFDecoder : public PlatformDecoder {
public:
    MFDecoder(const DecoderConfig &config);
    ~MFDecoder() override;

    // Non-copyable
    MFDecoder(const MFDecoder&) = delete;
    MFDecoder& operator=(const MFDecoder&) = delete;

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

    // D3D11 device access for GPU output
    void *get_d3d_device() const { return d3d_device_; }
    void *get_d3d_context() const { return d3d_context_; }

private:
    DecoderConfig config_;

    // Media Foundation objects
    IMFTransform *decoder_ = nullptr;
    IMFMediaType *output_type_ = nullptr;
    IMFDXGIDeviceManager *device_manager_ = nullptr;
    UINT device_manager_token_ = 0;

    // D3D11 objects for hardware decoding
    ID3D11Device *d3d_device_ = nullptr;
    ID3D11DeviceContext *d3d_context_ = nullptr;

    // Video dimensions
    uint32_t width_ = 0;
    uint32_t height_ = 0;

    // Cached parameter sets
    std::vector<uint8_t> sps_;
    std::vector<uint8_t> pps_;

    // Output buffer for software path
    std::vector<uint8_t> output_buffer_;

    // Async staging textures for low-latency GPU→CPU copy
    // Double-buffered: read from one while writing to the other
    ID3D11Texture2D *staging_textures_[2] = {nullptr, nullptr};
    int staging_write_idx_ = 0;      // Index to write next frame
    int staging_read_idx_ = -1;      // Index with valid data to read (-1 = none)
    uint32_t staging_width_ = 0;
    uint32_t staging_height_ = 0;

    bool create_staging_textures(uint32_t width, uint32_t height);
    void release_staging_textures();
    bool process_output_async(DecodedFrame &out);

    // State
    bool initialized_ = false;
    bool hardware_enabled_ = false;
    bool mf_initialized_ = false;
    bool input_started_ = false;
    bool drain_mode_ = false;
    bool gpu_output_enabled_ = false;
    bool use_async_staging_ = false;  // Disabled: causes frame drops, needs fix
    bool using_shared_device_ = false;  // True if using the global shared D3D11 device

    // Async staging diagnostics (per-instance, NOT static)
    int async_frame_count_ = 0;
    uint64_t total_async_time_ = 0;

    // Timing instrumentation
    mutable DecodeTimingStats timing_stats_;

    // Create D3D11 device for hardware acceleration
    bool create_d3d11_device();

    // Create/destroy decoder
    bool create_decoder();
    void destroy_decoder();

    // Configure decoder input/output types
    bool configure_input_type();
    bool configure_output_type();

    // Process input/output samples
    bool process_input(const uint8_t *data, size_t size);
    bool process_output(DecodedFrame &out);
    bool process_output_gpu(DecodedFrame &out);  // GPU texture path

    // Create sample from data
    IMFSample *create_sample(const uint8_t *data, size_t size);

    // Parse SPS for dimensions
    bool parse_sps_dimensions(const uint8_t *sps, size_t size);

    // Build decoder extradata from SPS/PPS
    std::vector<uint8_t> build_avcc_extradata();
};

} // namespace avolocam

#endif // _WIN32
