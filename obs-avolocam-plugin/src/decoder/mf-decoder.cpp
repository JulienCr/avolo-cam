/**
 * mf-decoder.cpp - Windows Media Foundation H.264 decoder implementation
 */

#include "mf-decoder.h"

#ifdef _WIN32

#include <obs-module.h>
#include <codecapi.h>
#include <algorithm>

#pragma comment(lib, "mf.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")

namespace avolocam {

// GUIDs for H.264 decoder
static const GUID MFVideoFormat_H264 = {0x34363248, 0x0000, 0x0010,
    {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
static const GUID MFVideoFormat_NV12 = {0x3231564E, 0x0000, 0x0010,
    {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};

MFDecoder::MFDecoder(const DecoderConfig &config)
    : config_(config)
{
    blog(LOG_INFO, "[avolocam] Creating Media Foundation decoder");

    // Initialize Media Foundation
    HRESULT hr = MFStartup(MF_VERSION);
    if (SUCCEEDED(hr)) {
        mf_initialized_ = true;
    } else {
        blog(LOG_ERROR, "[avolocam] MFStartup failed: 0x%08X", hr);
    }
}

MFDecoder::~MFDecoder()
{
    destroy_decoder();

    if (device_manager_) {
        device_manager_->Release();
        device_manager_ = nullptr;
    }

    if (d3d_context_) {
        d3d_context_->Release();
        d3d_context_ = nullptr;
    }

    if (d3d_device_) {
        d3d_device_->Release();
        d3d_device_ = nullptr;
    }

    if (mf_initialized_) {
        MFShutdown();
        mf_initialized_ = false;
    }

    blog(LOG_INFO, "[avolocam] Media Foundation decoder destroyed");
}

bool MFDecoder::create_d3d11_device()
{
    if (d3d_device_) {
        return true;
    }

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

    D3D_FEATURE_LEVEL feature_level;
    HRESULT hr = D3D11CreateDevice(
        nullptr,                    // Adapter
        D3D_DRIVER_TYPE_HARDWARE,   // Driver type
        nullptr,                    // Software
        flags,
        feature_levels,
        ARRAYSIZE(feature_levels),
        D3D11_SDK_VERSION,
        &d3d_device_,
        &feature_level,
        &d3d_context_);

    if (FAILED(hr)) {
        blog(LOG_WARNING, "[avolocam] D3D11CreateDevice failed: 0x%08X", hr);
        return false;
    }

    // Enable multithread protection
    ID3D10Multithread *mt = nullptr;
    hr = d3d_device_->QueryInterface(__uuidof(ID3D10Multithread), (void **)&mt);
    if (SUCCEEDED(hr)) {
        mt->SetMultithreadProtected(TRUE);
        mt->Release();
    }

    // Create DXGI device manager
    hr = MFCreateDXGIDeviceManager(&device_manager_token_, &device_manager_);
    if (FAILED(hr)) {
        blog(LOG_WARNING, "[avolocam] MFCreateDXGIDeviceManager failed: 0x%08X", hr);
        return false;
    }

    hr = device_manager_->ResetDevice(d3d_device_, device_manager_token_);
    if (FAILED(hr)) {
        blog(LOG_WARNING, "[avolocam] ResetDevice failed: 0x%08X", hr);
        device_manager_->Release();
        device_manager_ = nullptr;
        return false;
    }

    blog(LOG_INFO, "[avolocam] D3D11 device created for hardware decoding");
    return true;
}

bool MFDecoder::initialize(const uint8_t *sps, size_t sps_size,
                            const uint8_t *pps, size_t pps_size)
{
    if (!mf_initialized_) {
        return false;
    }

    if (!sps || sps_size == 0 || !pps || pps_size == 0) {
        blog(LOG_ERROR, "[avolocam] Invalid SPS/PPS data");
        return false;
    }

    // Store parameter sets
    sps_.assign(sps, sps + sps_size);
    pps_.assign(pps, pps + pps_size);

    // Parse SPS for dimensions
    if (!parse_sps_dimensions(sps, sps_size)) {
        blog(LOG_ERROR, "[avolocam] Failed to parse SPS");
        return false;
    }

    // Try to create D3D11 device for hardware acceleration
    if (config_.prefer_hardware) {
        hardware_enabled_ = create_d3d11_device();
    }

    // Create decoder
    if (!create_decoder()) {
        blog(LOG_ERROR, "[avolocam] Failed to create decoder");
        return false;
    }

    initialized_ = true;
    blog(LOG_INFO, "[avolocam] MF decoder initialized: %ux%u, hardware=%d",
         width_, height_, hardware_enabled_);
    return true;
}

bool MFDecoder::create_decoder()
{
    destroy_decoder();

    // Find H.264 decoder
    MFT_REGISTER_TYPE_INFO input_type = {MFMediaType_Video, MFVideoFormat_H264};
    MFT_REGISTER_TYPE_INFO output_type = {MFMediaType_Video, MFVideoFormat_NV12};

    UINT32 flags = MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT | MFT_ENUM_FLAG_SORTANDFILTER;
    if (hardware_enabled_) {
        flags |= MFT_ENUM_FLAG_HARDWARE;
    }

    IMFActivate **activates = nullptr;
    UINT32 num_activates = 0;

    HRESULT hr = MFTEnumEx(
        MFT_CATEGORY_VIDEO_DECODER,
        flags,
        &input_type,
        &output_type,
        &activates,
        &num_activates);

    if (FAILED(hr) || num_activates == 0) {
        blog(LOG_ERROR, "[avolocam] No H.264 decoder found: 0x%08X", hr);
        return false;
    }

    // Activate first decoder
    hr = activates[0]->ActivateObject(__uuidof(IMFTransform), (void **)&decoder_);

    // Free activates
    for (UINT32 i = 0; i < num_activates; i++) {
        activates[i]->Release();
    }
    CoTaskMemFree(activates);

    if (FAILED(hr)) {
        blog(LOG_ERROR, "[avolocam] ActivateObject failed: 0x%08X", hr);
        return false;
    }

    // Set D3D11 device manager if hardware decoding
    if (hardware_enabled_ && device_manager_) {
        hr = decoder_->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER,
                                       (ULONG_PTR)device_manager_);
        if (FAILED(hr)) {
            blog(LOG_WARNING, "[avolocam] Failed to set D3D manager: 0x%08X", hr);
            hardware_enabled_ = false;
        }
    }

    // Configure input type
    if (!configure_input_type()) {
        blog(LOG_ERROR, "[avolocam] Failed to configure input type");
        return false;
    }

    // Configure output type
    if (!configure_output_type()) {
        blog(LOG_ERROR, "[avolocam] Failed to configure output type");
        return false;
    }

    // Start streaming
    hr = decoder_->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    if (FAILED(hr)) {
        blog(LOG_WARNING, "[avolocam] Failed to notify begin streaming: 0x%08X", hr);
    }

    hr = decoder_->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    if (FAILED(hr)) {
        blog(LOG_WARNING, "[avolocam] Failed to notify start of stream: 0x%08X", hr);
    }

    input_started_ = true;
    return true;
}

void MFDecoder::destroy_decoder()
{
    if (decoder_) {
        if (input_started_) {
            decoder_->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
            decoder_->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
        }
        decoder_->Release();
        decoder_ = nullptr;
    }
    input_started_ = false;
    drain_mode_ = false;
}

bool MFDecoder::configure_input_type()
{
    IMFMediaType *media_type = nullptr;
    HRESULT hr = MFCreateMediaType(&media_type);
    if (FAILED(hr)) return false;

    hr = media_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    if (FAILED(hr)) { media_type->Release(); return false; }

    hr = media_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
    if (FAILED(hr)) { media_type->Release(); return false; }

    hr = MFSetAttributeSize(media_type, MF_MT_FRAME_SIZE, width_, height_);
    if (FAILED(hr)) { media_type->Release(); return false; }

    hr = MFSetAttributeRatio(media_type, MF_MT_FRAME_RATE, 30, 1);
    if (FAILED(hr)) { media_type->Release(); return false; }

    hr = MFSetAttributeRatio(media_type, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    if (FAILED(hr)) { media_type->Release(); return false; }

    // Set interlace mode to progressive
    hr = media_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    if (FAILED(hr)) { media_type->Release(); return false; }

    // Build AVCC extradata (decoder configuration record)
    std::vector<uint8_t> extradata = build_avcc_extradata();
    if (!extradata.empty()) {
        hr = media_type->SetBlob(MF_MT_USER_DATA, extradata.data(), (UINT32)extradata.size());
    }

    hr = decoder_->SetInputType(0, media_type, 0);
    media_type->Release();

    if (FAILED(hr)) {
        blog(LOG_ERROR, "[avolocam] SetInputType failed: 0x%08X", hr);
        return false;
    }

    return true;
}

bool MFDecoder::configure_output_type()
{
    // Get available output types
    for (DWORD i = 0; ; i++) {
        IMFMediaType *media_type = nullptr;
        HRESULT hr = decoder_->GetOutputAvailableType(0, i, &media_type);
        if (hr == MF_E_NO_MORE_TYPES) break;
        if (FAILED(hr)) break;

        GUID subtype;
        hr = media_type->GetGUID(MF_MT_SUBTYPE, &subtype);
        if (SUCCEEDED(hr) && subtype == MFVideoFormat_NV12) {
            hr = decoder_->SetOutputType(0, media_type, 0);
            media_type->Release();
            if (SUCCEEDED(hr)) {
                return true;
            }
        } else {
            media_type->Release();
        }
    }

    blog(LOG_ERROR, "[avolocam] No suitable output type found");
    return false;
}

std::vector<uint8_t> MFDecoder::build_avcc_extradata()
{
    // Build AVCC decoder configuration record
    // Format:
    // configurationVersion (1 byte) = 1
    // AVCProfileIndication (1 byte)
    // profile_compatibility (1 byte)
    // AVCLevelIndication (1 byte)
    // lengthSizeMinusOne (1 byte) = 0xFF (4 bytes)
    // numOfSequenceParameterSets (1 byte) = 0xE1 (1 SPS)
    // sequenceParameterSetLength (2 bytes)
    // sequenceParameterSetNALUnit (variable)
    // numOfPictureParameterSets (1 byte) = 1
    // pictureParameterSetLength (2 bytes)
    // pictureParameterSetNALUnit (variable)

    if (sps_.size() < 4) return {};

    std::vector<uint8_t> extradata;
    extradata.reserve(11 + sps_.size() + pps_.size());

    extradata.push_back(1);              // configurationVersion
    extradata.push_back(sps_[1]);        // AVCProfileIndication
    extradata.push_back(sps_[2]);        // profile_compatibility
    extradata.push_back(sps_[3]);        // AVCLevelIndication
    extradata.push_back(0xFF);           // lengthSizeMinusOne (3 + 1 = 4 bytes)

    // SPS
    extradata.push_back(0xE1);           // numOfSequenceParameterSets (1)
    extradata.push_back((sps_.size() >> 8) & 0xFF);
    extradata.push_back(sps_.size() & 0xFF);
    extradata.insert(extradata.end(), sps_.begin(), sps_.end());

    // PPS
    extradata.push_back(1);              // numOfPictureParameterSets
    extradata.push_back((pps_.size() >> 8) & 0xFF);
    extradata.push_back(pps_.size() & 0xFF);
    extradata.insert(extradata.end(), pps_.begin(), pps_.end());

    return extradata;
}

bool MFDecoder::parse_sps_dimensions(const uint8_t *sps, size_t size)
{
    // Simple SPS parsing for baseline dimensions
    // Full parsing requires exponential-golomb decoding
    if (size < 4) return false;

    // For now, use configured max dimensions
    // The decoder will provide actual dimensions in output type
    width_ = config_.max_width;
    height_ = config_.max_height;

    return true;
}

IMFSample *MFDecoder::create_sample(const uint8_t *data, size_t size)
{
    IMFMediaBuffer *buffer = nullptr;
    HRESULT hr = MFCreateMemoryBuffer((DWORD)size, &buffer);
    if (FAILED(hr)) return nullptr;

    BYTE *buffer_data = nullptr;
    hr = buffer->Lock(&buffer_data, nullptr, nullptr);
    if (FAILED(hr)) {
        buffer->Release();
        return nullptr;
    }

    memcpy(buffer_data, data, size);
    buffer->Unlock();
    buffer->SetCurrentLength((DWORD)size);

    IMFSample *sample = nullptr;
    hr = MFCreateSample(&sample);
    if (FAILED(hr)) {
        buffer->Release();
        return nullptr;
    }

    hr = sample->AddBuffer(buffer);
    buffer->Release();

    if (FAILED(hr)) {
        sample->Release();
        return nullptr;
    }

    return sample;
}

bool MFDecoder::process_input(const uint8_t *data, size_t size)
{
    IMFSample *sample = create_sample(data, size);
    if (!sample) return false;

    HRESULT hr = decoder_->ProcessInput(0, sample, 0);
    sample->Release();

    if (hr == MF_E_NOTACCEPTING) {
        // Decoder needs output to be retrieved first
        return true;
    }

    return SUCCEEDED(hr);
}

bool MFDecoder::process_output(DecodedFrame &out)
{
    MFT_OUTPUT_DATA_BUFFER output = {};
    MFT_OUTPUT_STREAM_INFO stream_info = {};

    HRESULT hr = decoder_->GetOutputStreamInfo(0, &stream_info);
    if (FAILED(hr)) return false;

    // Check if decoder allocates its own samples
    bool decoder_allocates = (stream_info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) != 0;

    IMFSample *output_sample = nullptr;
    if (!decoder_allocates) {
        // We need to provide output buffer
        IMFMediaBuffer *buffer = nullptr;
        hr = MFCreateMemoryBuffer(stream_info.cbSize, &buffer);
        if (FAILED(hr)) return false;

        hr = MFCreateSample(&output_sample);
        if (FAILED(hr)) {
            buffer->Release();
            return false;
        }

        hr = output_sample->AddBuffer(buffer);
        buffer->Release();
        if (FAILED(hr)) {
            output_sample->Release();
            return false;
        }
    }

    output.pSample = output_sample;

    DWORD status = 0;
    hr = decoder_->ProcessOutput(0, 1, &output, &status);

    if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) {
        if (output_sample) output_sample->Release();
        return false;
    }

    if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
        // Output format changed, reconfigure
        if (output.pSample) output.pSample->Release();
        if (!configure_output_type()) {
            return false;
        }
        // Try again
        return process_output(out);
    }

    if (FAILED(hr)) {
        if (output.pSample) output.pSample->Release();
        blog(LOG_WARNING, "[avolocam] ProcessOutput failed: 0x%08X", hr);
        return false;
    }

    // Get the output sample
    IMFSample *result_sample = output.pSample;
    if (!result_sample) {
        return false;
    }

    // Get buffer from sample
    IMFMediaBuffer *media_buffer = nullptr;
    hr = result_sample->ConvertToContiguousBuffer(&media_buffer);
    if (FAILED(hr)) {
        result_sample->Release();
        return false;
    }

    // Try to get 2D buffer interface
    IMF2DBuffer *buffer_2d = nullptr;
    hr = media_buffer->QueryInterface(__uuidof(IMF2DBuffer), (void **)&buffer_2d);

    if (SUCCEEDED(hr) && buffer_2d) {
        // Use 2D buffer for stride information
        BYTE *data = nullptr;
        LONG pitch = 0;
        hr = buffer_2d->Lock2D(&data, &pitch);
        if (SUCCEEDED(hr)) {
            // Allocate output buffer
            size_t y_size = (size_t)pitch * height_;
            size_t uv_size = (size_t)pitch * height_ / 2;
            output_buffer_.resize(y_size + uv_size);

            // Copy Y plane
            memcpy(output_buffer_.data(), data, y_size);
            // Copy UV plane
            memcpy(output_buffer_.data() + y_size, data + y_size, uv_size);

            buffer_2d->Unlock2D();

            out.width = width_;
            out.height = height_;
            out.y_plane = output_buffer_.data();
            out.uv_plane = output_buffer_.data() + y_size;
            out.y_stride = (uint32_t)pitch;
            out.uv_stride = (uint32_t)pitch;
            out.owns_memory = true;
        }
        buffer_2d->Release();
    } else {
        // Fall back to linear buffer
        BYTE *data = nullptr;
        DWORD max_length = 0;
        DWORD current_length = 0;

        hr = media_buffer->Lock(&data, &max_length, &current_length);
        if (SUCCEEDED(hr)) {
            // Assume NV12 layout with default stride
            LONG stride = width_;
            size_t y_size = (size_t)stride * height_;
            size_t uv_size = (size_t)stride * height_ / 2;

            if (current_length >= y_size + uv_size) {
                output_buffer_.resize(y_size + uv_size);
                memcpy(output_buffer_.data(), data, y_size + uv_size);

                out.width = width_;
                out.height = height_;
                out.y_plane = output_buffer_.data();
                out.uv_plane = output_buffer_.data() + y_size;
                out.y_stride = (uint32_t)stride;
                out.uv_stride = (uint32_t)stride;
                out.owns_memory = true;
            }
            media_buffer->Unlock();
        }
    }

    media_buffer->Release();
    result_sample->Release();

    return out.y_plane != nullptr;
}

bool MFDecoder::decode(const uint8_t *data, size_t size, DecodedFrame &out)
{
    if (!initialized_ || !decoder_ || !data || size == 0) {
        return false;
    }

    // Process input
    if (!process_input(data, size)) {
        blog(LOG_WARNING, "[avolocam] Failed to process input");
        // Still try to get output
    }

    // Process output
    return process_output(out);
}

void MFDecoder::flush()
{
    if (!decoder_ || !input_started_) return;

    // Send drain message
    decoder_->ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0);

    // Retrieve remaining frames
    DecodedFrame dummy;
    while (process_output(dummy)) {
        // Discard frames
    }
}

void MFDecoder::reset()
{
    if (!decoder_) return;

    // Flush and restart
    decoder_->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);

    if (input_started_) {
        decoder_->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    }

    drain_mode_ = false;
}

uint32_t MFDecoder::get_width() const
{
    return width_;
}

uint32_t MFDecoder::get_height() const
{
    return height_;
}

bool MFDecoder::is_hardware() const
{
    return hardware_enabled_;
}

const char *MFDecoder::get_name() const
{
    return hardware_enabled_ ? "Media Foundation (D3D11VA)" : "Media Foundation (Software)";
}

bool MFDecoder::is_initialized() const
{
    return initialized_;
}

// Factory method implementation for Windows
std::unique_ptr<PlatformDecoder> PlatformDecoder::create(const DecoderConfig &config)
{
    blog(LOG_INFO, "[avolocam] Creating platform decoder (Windows)");
    return std::make_unique<MFDecoder>(config);
}

} // namespace avolocam

#endif // _WIN32
