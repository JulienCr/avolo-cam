/**
 * videotoolbox-decoder.h - macOS VideoToolbox H.264 decoder
 *
 * Hardware-accelerated decoder using Apple's VideoToolbox framework.
 * Outputs NV12 (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) format.
 */

#pragma once

#include "platform-decoder.h"

#ifdef __APPLE__

#include <VideoToolbox/VideoToolbox.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <atomic>
#include <mutex>
#include <deque>
#include <vector>

namespace avolocam {

/**
 * VideoToolbox H.264 decoder implementation
 */
class VideoToolboxDecoder : public PlatformDecoder {
public:
    VideoToolboxDecoder(const DecoderConfig &config);
    ~VideoToolboxDecoder() override;

    // Non-copyable
    VideoToolboxDecoder(const VideoToolboxDecoder&) = delete;
    VideoToolboxDecoder& operator=(const VideoToolboxDecoder&) = delete;

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

private:
    DecoderConfig config_;

    // VideoToolbox objects
    CMVideoFormatDescriptionRef format_desc_ = nullptr;
    VTDecompressionSessionRef session_ = nullptr;

    // Video dimensions extracted from SPS
    uint32_t width_ = 0;
    uint32_t height_ = 0;

    // Cached parameter sets
    std::vector<uint8_t> sps_;
    std::vector<uint8_t> pps_;

    // Decoded frame queue
    std::mutex frame_mutex_;
    struct OutputFrame {
        CVPixelBufferRef pixel_buffer;
        CMTime pts;
    };
    std::deque<OutputFrame> output_frames_;
    static constexpr size_t MAX_OUTPUT_FRAMES = 8;

    // Currently locked pixel buffer for output
    CVPixelBufferRef current_locked_buffer_ = nullptr;

    // State
    std::atomic<bool> initialized_{false};
    bool hardware_enabled_ = false;

    // Timing stats (for API compatibility)
    mutable DecodeTimingStats timing_stats_;

    // Mutex for initialization thread safety
    std::mutex init_mutex_;

    // Create format description from SPS/PPS
    bool create_format_description();

    // Create/destroy decompression session
    bool create_decompression_session();
    void destroy_decompression_session();

    // Decode callback
    static void decode_callback(void *decompressionOutputRefCon,
                                void *sourceFrameRefCon,
                                OSStatus status,
                                VTDecodeInfoFlags infoFlags,
                                CVImageBufferRef imageBuffer,
                                CMTime presentationTimeStamp,
                                CMTime presentationDuration);

    void on_frame_decoded(CVPixelBufferRef pixel_buffer, CMTime pts,
                          OSStatus status, VTDecodeInfoFlags flags);

    // Convert Annex B to AVCC format for VideoToolbox
    bool convert_annex_b_to_avcc(const uint8_t *data, size_t size,
                                 std::vector<uint8_t> &avcc_data);

    // Parse SPS to extract dimensions
    bool parse_sps_dimensions(const uint8_t *sps, size_t size);

    // Unlock current buffer if locked
    void unlock_current_buffer();
};

} // namespace avolocam

#endif // __APPLE__
