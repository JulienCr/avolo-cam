/**
 * videotoolbox-decoder.mm - macOS VideoToolbox H.264 decoder implementation
 */

#include "videotoolbox-decoder.h"

#ifdef __APPLE__

#include <obs-module.h>
#include <algorithm>

namespace avolocam {

VideoToolboxDecoder::VideoToolboxDecoder(const DecoderConfig &config)
    : config_(config)
{
    blog(LOG_INFO, "[avolocam] Creating VideoToolbox decoder");
}

VideoToolboxDecoder::~VideoToolboxDecoder()
{
    destroy_decompression_session();
    unlock_current_buffer();

    // Release any queued frames
    std::lock_guard<std::mutex> lock(frame_mutex_);
    for (auto &frame : output_frames_) {
        if (frame.pixel_buffer) {
            CVPixelBufferRelease(frame.pixel_buffer);
        }
    }
    output_frames_.clear();

    if (format_desc_) {
        CFRelease(format_desc_);
        format_desc_ = nullptr;
    }

    blog(LOG_INFO, "[avolocam] VideoToolbox decoder destroyed");
}

bool VideoToolboxDecoder::initialize(const uint8_t *sps, size_t sps_size,
                                      const uint8_t *pps, size_t pps_size)
{
    if (!sps || sps_size == 0 || !pps || pps_size == 0) {
        blog(LOG_ERROR, "[avolocam] Invalid SPS/PPS data");
        return false;
    }

    // Store parameter sets
    sps_.assign(sps, sps + sps_size);
    pps_.assign(pps, pps + pps_size);

    // Parse SPS to get dimensions
    if (!parse_sps_dimensions(sps, sps_size)) {
        blog(LOG_ERROR, "[avolocam] Failed to parse SPS");
        return false;
    }

    // Destroy existing session if dimensions changed
    if (format_desc_) {
        CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(format_desc_);
        if (dims.width != (int32_t)width_ || dims.height != (int32_t)height_) {
            blog(LOG_INFO, "[avolocam] Resolution changed, recreating session");
            destroy_decompression_session();
            CFRelease(format_desc_);
            format_desc_ = nullptr;
        }
    }

    // Create format description
    if (!format_desc_ && !create_format_description()) {
        blog(LOG_ERROR, "[avolocam] Failed to create format description");
        return false;
    }

    // Create decompression session
    if (!session_ && !create_decompression_session()) {
        blog(LOG_ERROR, "[avolocam] Failed to create decompression session");
        return false;
    }

    initialized_ = true;
    blog(LOG_INFO, "[avolocam] VideoToolbox decoder initialized: %ux%u, hardware=%d",
         width_, height_, hardware_enabled_);
    return true;
}

bool VideoToolboxDecoder::create_format_description()
{
    // Create parameter set arrays for CMVideoFormatDescription
    const uint8_t *param_sets[2] = { sps_.data(), pps_.data() };
    const size_t param_sizes[2] = { sps_.size(), pps_.size() };

    OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault,
        2,              // parameter set count
        param_sets,     // parameter sets
        param_sizes,    // parameter set sizes
        4,              // NAL unit length size (4 bytes for AVCC)
        &format_desc_);

    if (status != noErr) {
        blog(LOG_ERROR, "[avolocam] CMVideoFormatDescriptionCreateFromH264ParameterSets failed: %d",
             (int)status);
        return false;
    }

    // Get actual dimensions from format description (fixes resolution mismatch)
    // This bypasses the incomplete SPS parser - the format description has correct dimensions
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(format_desc_);
    width_ = dims.width;
    height_ = dims.height;

    blog(LOG_INFO, "[avolocam] Format description created: %dx%d",
         dims.width, dims.height);

    return true;
}

bool VideoToolboxDecoder::create_decompression_session()
{
    if (!format_desc_) {
        return false;
    }

    // Destroy existing session
    destroy_decompression_session();

    // Configure pixel buffer attributes
    NSDictionary *dest_attrs = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey:
            @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        (NSString *)kCVPixelBufferWidthKey: @(width_),
        (NSString *)kCVPixelBufferHeightKey: @(height_),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };

    // Configure decoder
    NSDictionary *decoder_attrs = @{
        // Enable hardware acceleration
        (NSString *)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: @YES,
        // Require hardware (comment out for fallback to software)
        // (NSString *)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: @YES,
    };

    // Callback configuration
    VTDecompressionOutputCallbackRecord callback;
    callback.decompressionOutputCallback = decode_callback;
    callback.decompressionOutputRefCon = this;

    OSStatus status = VTDecompressionSessionCreate(
        kCFAllocatorDefault,
        format_desc_,
        (__bridge CFDictionaryRef)decoder_attrs,
        (__bridge CFDictionaryRef)dest_attrs,
        &callback,
        &session_);

    if (status != noErr) {
        blog(LOG_ERROR, "[avolocam] VTDecompressionSessionCreate failed: %d", (int)status);
        return false;
    }

    // Check if hardware decoding is enabled
    hardware_enabled_ = false;
    CFBooleanRef using_hw;
    status = VTSessionCopyProperty(session_,
                                    kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                    kCFAllocatorDefault, &using_hw);
    if (status == noErr && using_hw) {
        hardware_enabled_ = CFBooleanGetValue(using_hw);
        CFRelease(using_hw);
    }

    blog(LOG_INFO, "[avolocam] VTDecompressionSession created, hardware=%d", hardware_enabled_);
    return true;
}

void VideoToolboxDecoder::destroy_decompression_session()
{
    if (session_) {
        VTDecompressionSessionWaitForAsynchronousFrames(session_);
        VTDecompressionSessionInvalidate(session_);
        CFRelease(session_);
        session_ = nullptr;
    }
}

void VideoToolboxDecoder::decode_callback(void *decompressionOutputRefCon,
                                           void *sourceFrameRefCon,
                                           OSStatus status,
                                           VTDecodeInfoFlags infoFlags,
                                           CVImageBufferRef imageBuffer,
                                           CMTime presentationTimeStamp,
                                           CMTime presentationDuration)
{
    auto *decoder = static_cast<VideoToolboxDecoder *>(decompressionOutputRefCon);
    (void)sourceFrameRefCon;
    (void)presentationDuration;

    decoder->on_frame_decoded((CVPixelBufferRef)imageBuffer, presentationTimeStamp,
                              status, infoFlags);
}

void VideoToolboxDecoder::on_frame_decoded(CVPixelBufferRef pixel_buffer, CMTime pts,
                                            OSStatus status, VTDecodeInfoFlags flags)
{
    if (status != noErr) {
        blog(LOG_WARNING, "[avolocam] Decode callback error: %d", (int)status);
        return;
    }

    if (!pixel_buffer) {
        blog(LOG_WARNING, "[avolocam] Decode callback: null pixel buffer");
        return;
    }

    if (flags & kVTDecodeInfo_FrameDropped) {
        blog(LOG_DEBUG, "[avolocam] Frame dropped by decoder");
        return;
    }

    // Add to output queue
    CVPixelBufferRetain(pixel_buffer);

    std::lock_guard<std::mutex> lock(frame_mutex_);

    // Limit queue size
    while (output_frames_.size() >= MAX_OUTPUT_FRAMES) {
        CVPixelBufferRelease(output_frames_.front().pixel_buffer);
        output_frames_.pop_front();
    }

    output_frames_.push_back({pixel_buffer, pts});
}

bool VideoToolboxDecoder::decode(const uint8_t *data, size_t size, DecodedFrame &out)
{
    if (!initialized_ || !session_ || !data || size == 0) {
        return false;
    }

    // Convert Annex B to AVCC format
    std::vector<uint8_t> avcc_data;
    if (!convert_annex_b_to_avcc(data, size, avcc_data)) {
        blog(LOG_WARNING, "[avolocam] Failed to convert Annex B to AVCC");
        return false;
    }

    if (avcc_data.empty()) {
        // AU only contained SPS/PPS - this is normal, not an error
        return true;
    }

    // Use CFData to manage memory lifetime - CFData copies the data and manages it
    CFDataRef cf_data = CFDataCreate(kCFAllocatorDefault, avcc_data.data(), avcc_data.size());
    if (!cf_data) {
        blog(LOG_ERROR, "[avolocam] CFDataCreate failed");
        return false;
    }

    // Create CMBlockBuffer wrapping the CFData
    CMBlockBufferRef block_buffer = nullptr;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault,
        (void*)CFDataGetBytePtr(cf_data),  // Data pointer from CFData
        CFDataGetLength(cf_data),           // Data length
        kCFAllocatorNull,                   // Block allocator (null = don't free the pointer)
        nullptr,                            // Custom block source
        0,                                  // Offset
        CFDataGetLength(cf_data),           // Length
        0,                                  // Flags
        &block_buffer);

    if (status != noErr) {
        blog(LOG_ERROR, "[avolocam] CMBlockBufferCreateWithMemoryBlock failed: %d", (int)status);
        CFRelease(cf_data);
        return false;
    }

    // Create CMSampleBuffer
    CMSampleBufferRef sample_buffer = nullptr;
    const size_t sample_size = avcc_data.size();
    status = CMSampleBufferCreateReady(
        kCFAllocatorDefault,
        block_buffer,
        format_desc_,
        1,              // number of samples
        0,              // timing info count
        nullptr,        // timing info
        1,              // sample size count
        &sample_size,   // sample size array
        &sample_buffer);

    CFRelease(block_buffer);

    if (status != noErr) {
        blog(LOG_ERROR, "[avolocam] CMSampleBufferCreateReady failed: %d", (int)status);
        CFRelease(cf_data);
        return false;
    }

    // Decode
    VTDecodeFrameFlags decode_flags = kVTDecodeFrame_EnableAsynchronousDecompression;
    if (config_.low_latency) {
        decode_flags |= kVTDecodeFrame_1xRealTimePlayback;
    }

    status = VTDecompressionSessionDecodeFrame(
        session_,
        sample_buffer,
        decode_flags,
        nullptr,        // source frame refcon
        nullptr);       // info flags out

    CFRelease(sample_buffer);

    if (status != noErr) {
        blog(LOG_WARNING, "[avolocam] VTDecompressionSessionDecodeFrame failed: %d", (int)status);
        CFRelease(cf_data);
        return false;
    }

    // Wait for output (for synchronous behavior)
    VTDecompressionSessionWaitForAsynchronousFrames(session_);

    // Release cf_data after decode is complete (data is no longer needed)
    CFRelease(cf_data);

    // Get decoded frame from queue
    std::lock_guard<std::mutex> lock(frame_mutex_);
    if (output_frames_.empty()) {
        return false;
    }

    // Unlock previous buffer
    unlock_current_buffer();

    // Get oldest frame
    OutputFrame frame = output_frames_.front();
    output_frames_.pop_front();

    current_locked_buffer_ = frame.pixel_buffer;

    // Lock the pixel buffer for CPU access
    status = CVPixelBufferLockBaseAddress(current_locked_buffer_, kCVPixelBufferLock_ReadOnly);
    if (status != noErr) {
        blog(LOG_WARNING, "[avolocam] CVPixelBufferLockBaseAddress failed: %d", (int)status);
        CVPixelBufferRelease(current_locked_buffer_);
        current_locked_buffer_ = nullptr;
        return false;
    }

    // Fill output structure
    out.width = (uint32_t)CVPixelBufferGetWidth(current_locked_buffer_);
    out.height = (uint32_t)CVPixelBufferGetHeight(current_locked_buffer_);
    out.y_plane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(current_locked_buffer_, 0);
    out.uv_plane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(current_locked_buffer_, 1);
    out.y_stride = (uint32_t)CVPixelBufferGetBytesPerRowOfPlane(current_locked_buffer_, 0);
    out.uv_stride = (uint32_t)CVPixelBufferGetBytesPerRowOfPlane(current_locked_buffer_, 1);
    out.pts = CMTIME_IS_VALID(frame.pts) ? (uint64_t)CMTimeGetSeconds(frame.pts) * 1000000000ULL : 0;
    out.owns_memory = true;  // We manage the lifetime
    out.platform_handle = current_locked_buffer_;

    return true;
}

void VideoToolboxDecoder::unlock_current_buffer()
{
    if (current_locked_buffer_) {
        CVPixelBufferUnlockBaseAddress(current_locked_buffer_, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(current_locked_buffer_);
        current_locked_buffer_ = nullptr;
    }
}

bool VideoToolboxDecoder::convert_annex_b_to_avcc(const uint8_t *data, size_t size,
                                                   std::vector<uint8_t> &avcc_data)
{
    avcc_data.clear();

    // Find NAL units in Annex B format and convert to AVCC
    size_t i = 0;
    while (i < size) {
        // Find start code (0x00 0x00 0x01 or 0x00 0x00 0x00 0x01)
        size_t start_code_len = 0;
        if (i + 3 <= size && data[i] == 0x00 && data[i + 1] == 0x00) {
            if (data[i + 2] == 0x01) {
                start_code_len = 3;
            } else if (i + 4 <= size && data[i + 2] == 0x00 && data[i + 3] == 0x01) {
                start_code_len = 4;
            }
        }

        if (start_code_len == 0) {
            i++;
            continue;
        }

        size_t nal_start = i + start_code_len;

        // Find end of NAL unit (next start code or end of data)
        size_t nal_end = size;
        for (size_t j = nal_start; j + 2 < size; j++) {
            if (data[j] == 0x00 && data[j + 1] == 0x00 &&
                (data[j + 2] == 0x01 || (j + 3 < size && data[j + 2] == 0x00 && data[j + 3] == 0x01))) {
                nal_end = j;
                break;
            }
        }

        size_t nal_size = nal_end - nal_start;
        if (nal_size == 0) {
            i = nal_end;
            continue;
        }

        // Get NAL type
        uint8_t nal_type = data[nal_start] & 0x1F;

        // Skip SPS/PPS - they're already in the format description
        if (nal_type == 7 || nal_type == 8) {
            i = nal_end;
            continue;
        }

        // Write NAL size (4 bytes, big endian)
        avcc_data.push_back((nal_size >> 24) & 0xFF);
        avcc_data.push_back((nal_size >> 16) & 0xFF);
        avcc_data.push_back((nal_size >> 8) & 0xFF);
        avcc_data.push_back(nal_size & 0xFF);

        // Write NAL data
        avcc_data.insert(avcc_data.end(), data + nal_start, data + nal_end);

        i = nal_end;
    }

    // Return true even if avcc_data is empty (parsing succeeded, just no slice NALs to decode)
    // Caller should check avcc_data.empty() separately
    return true;
}

bool VideoToolboxDecoder::parse_sps_dimensions(const uint8_t *sps, size_t size)
{
    // Basic SPS parsing to extract dimensions
    // SPS structure (simplified):
    // - nal_unit_type (5 bits in first byte, should be 7)
    // - profile_idc (8 bits)
    // - constraint_set flags (8 bits)
    // - level_idc (8 bits)
    // - seq_parameter_set_id (ue(v))
    // - For high profiles: chroma_format_idc, etc.
    // - log2_max_frame_num_minus4 (ue(v))
    // - pic_order_cnt_type (ue(v))
    // - ...
    // - pic_width_in_mbs_minus1 (ue(v))
    // - pic_height_in_map_units_minus1 (ue(v))
    // - frame_mbs_only_flag (1 bit)

    if (size < 4) {
        return false;
    }

    // Skip NAL header
    const uint8_t *p = sps + 1;
    size_t remaining = size - 1;

    if (remaining < 3) return false;

    uint8_t profile_idc = p[0];
    // uint8_t constraint_set = p[1];
    // uint8_t level_idc = p[2];
    p += 3;
    remaining -= 3;

    // For simplicity, use default dimensions if parsing fails
    // A full SPS parser would use exponential-golomb decoding

    // Check for high profile (requires more complex parsing)
    bool high_profile = (profile_idc == 100 || profile_idc == 110 ||
                        profile_idc == 122 || profile_idc == 244 ||
                        profile_idc == 44 || profile_idc == 83 ||
                        profile_idc == 86 || profile_idc == 118 ||
                        profile_idc == 128);

    (void)high_profile;

    // For now, set default dimensions and let VideoToolbox handle it
    // The format description will have the correct dimensions
    width_ = config_.max_width;
    height_ = config_.max_height;

    return true;
}

void VideoToolboxDecoder::flush()
{
    if (session_) {
        VTDecompressionSessionWaitForAsynchronousFrames(session_);
    }
}

void VideoToolboxDecoder::reset()
{
    flush();

    // Clear output queue
    std::lock_guard<std::mutex> lock(frame_mutex_);
    for (auto &frame : output_frames_) {
        if (frame.pixel_buffer) {
            CVPixelBufferRelease(frame.pixel_buffer);
        }
    }
    output_frames_.clear();

    unlock_current_buffer();
}

uint32_t VideoToolboxDecoder::get_width() const
{
    return width_;
}

uint32_t VideoToolboxDecoder::get_height() const
{
    return height_;
}

bool VideoToolboxDecoder::is_hardware() const
{
    return hardware_enabled_;
}

const char *VideoToolboxDecoder::get_name() const
{
    return hardware_enabled_ ? "VideoToolbox (Hardware)" : "VideoToolbox (Software)";
}

bool VideoToolboxDecoder::is_initialized() const
{
    return initialized_;
}

// Factory method implementation for macOS
std::unique_ptr<PlatformDecoder> PlatformDecoder::create(const DecoderConfig &config)
{
    blog(LOG_INFO, "[avolocam] Creating platform decoder (macOS)");
    return std::make_unique<VideoToolboxDecoder>(config);
}

} // namespace avolocam

#endif // __APPLE__
