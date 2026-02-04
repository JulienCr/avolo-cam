/**
 * mf-decoder.cpp - Windows Media Foundation H.264 decoder implementation
 */

#include "mf-decoder.h"

#ifdef HAVE_FFMPEG_D3D11VA
#include "ffmpeg-d3d11va-decoder.h"
#endif

#ifdef _WIN32

#include <obs-module.h>
#include <codecapi.h>
#include <strmif.h>
#include <algorithm>

#pragma comment(lib, "mf.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "strmiids.lib")

// High-resolution timing helper
namespace {
    inline uint64_t get_time_ns() {
        LARGE_INTEGER freq, counter;
        QueryPerformanceFrequency(&freq);
        QueryPerformanceCounter(&counter);
        return (uint64_t)((counter.QuadPart * 1000000000LL) / freq.QuadPart);
    }
}

namespace avolocam {

// Shared D3D11 device across all MFDecoder instances to avoid hitting
// GPU hardware session limits (typically 4-8 on NVIDIA, fewer on Intel).
// Each MFDecoder creating its own D3D11Device + MFT instance risks exceeding
// the limit and crashing the GPU driver.
static ID3D11Device *g_shared_d3d_device = nullptr;
static ID3D11DeviceContext *g_shared_d3d_context = nullptr;
static IMFDXGIDeviceManager *g_shared_device_manager = nullptr;
static UINT g_shared_device_manager_token = 0;
static int g_shared_d3d_refcount = 0;
static std::mutex g_shared_d3d_mutex;

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
    release_staging_textures();

    if (using_shared_device_) {
        // All COM releases must be under the mutex to prevent a concurrent
        // create_d3d11_device() from AddRef'ing objects we're about to destroy.
        std::lock_guard<std::mutex> lock(g_shared_d3d_mutex);

        // Release instance COM references (AddRef'd copies of shared device)
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

        g_shared_d3d_refcount--;
        blog(LOG_INFO, "[avolocam] Released shared D3D11 device reference (refcount=%d)",
             g_shared_d3d_refcount);

        if (g_shared_d3d_refcount <= 0) {
            if (g_shared_device_manager) {
                g_shared_device_manager->Release();
                g_shared_device_manager = nullptr;
            }
            if (g_shared_d3d_context) {
                g_shared_d3d_context->Release();
                g_shared_d3d_context = nullptr;
            }
            if (g_shared_d3d_device) {
                g_shared_d3d_device->Release();
                g_shared_d3d_device = nullptr;
            }
            g_shared_d3d_refcount = 0;
            blog(LOG_INFO, "[avolocam] Shared D3D11 device destroyed (last reference)");
        }
    } else {
        // Non-shared device: release normally without lock
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
    }

    if (mf_initialized_) {
        MFShutdown();
        mf_initialized_ = false;
    }

    blog(LOG_INFO, "[avolocam] Media Foundation decoder destroyed");
}

void MFDecoder::release_staging_textures()
{
    for (int i = 0; i < 2; i++) {
        if (staging_textures_[i]) {
            staging_textures_[i]->Release();
            staging_textures_[i] = nullptr;
        }
    }
    staging_write_idx_ = 0;
    staging_read_idx_ = -1;
    staging_width_ = 0;
    staging_height_ = 0;
}

bool MFDecoder::create_staging_textures(uint32_t width, uint32_t height)
{
    if (!d3d_device_) return false;

    // Check if we need to recreate
    if (staging_textures_[0] && staging_width_ == width && staging_height_ == height) {
        return true;
    }

    release_staging_textures();

    D3D11_TEXTURE2D_DESC desc = {};
    desc.Width = width;
    desc.Height = height;
    desc.MipLevels = 1;
    desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_NV12;
    desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_STAGING;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;

    for (int i = 0; i < 2; i++) {
        HRESULT hr = d3d_device_->CreateTexture2D(&desc, nullptr, &staging_textures_[i]);
        if (FAILED(hr)) {
            blog(LOG_ERROR, "[avolocam] Failed to create staging texture %d: 0x%08X", i, hr);
            release_staging_textures();
            return false;
        }
    }

    staging_width_ = width;
    staging_height_ = height;
    blog(LOG_INFO, "[avolocam] Created async staging textures %ux%u", width, height);
    return true;
}

bool MFDecoder::create_d3d11_device()
{
    if (d3d_device_) {
        return true;
    }

    std::lock_guard<std::mutex> lock(g_shared_d3d_mutex);

    // Reuse existing shared device if available
    if (g_shared_d3d_device && g_shared_d3d_context && g_shared_device_manager) {
        d3d_device_ = g_shared_d3d_device;
        d3d_device_->AddRef();
        d3d_context_ = g_shared_d3d_context;
        d3d_context_->AddRef();
        device_manager_ = g_shared_device_manager;
        device_manager_->AddRef();
        device_manager_token_ = g_shared_device_manager_token;
        g_shared_d3d_refcount++;
        using_shared_device_ = true;

        blog(LOG_INFO, "[avolocam] Reusing shared D3D11 device (refcount=%d)",
             g_shared_d3d_refcount);
        return true;
    }

    // Create new D3D11 device (first instance)
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
        d3d_context_->Release();
        d3d_context_ = nullptr;
        d3d_device_->Release();
        d3d_device_ = nullptr;
        return false;
    }

    hr = device_manager_->ResetDevice(d3d_device_, device_manager_token_);
    if (FAILED(hr)) {
        blog(LOG_WARNING, "[avolocam] ResetDevice failed: 0x%08X", hr);
        device_manager_->Release();
        device_manager_ = nullptr;
        d3d_context_->Release();
        d3d_context_ = nullptr;
        d3d_device_->Release();
        d3d_device_ = nullptr;
        return false;
    }

    // Store as shared device for other instances
    g_shared_d3d_device = d3d_device_;
    g_shared_d3d_device->AddRef();
    g_shared_d3d_context = d3d_context_;
    g_shared_d3d_context->AddRef();
    g_shared_device_manager = device_manager_;
    g_shared_device_manager->AddRef();
    g_shared_device_manager_token = device_manager_token_;
    g_shared_d3d_refcount = 1;
    using_shared_device_ = true;

    blog(LOG_INFO, "[avolocam] Created shared D3D11 device for hardware decoding (refcount=1)");
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
    {
        std::lock_guard<std::mutex> lock(g_shared_d3d_mutex);
        blog(LOG_INFO, "[avolocam] MF decoder initialized: %ux%u, hardware=%d, "
             "active_hw_sessions=%d",
             width_, height_, hardware_enabled_,
             hardware_enabled_ ? g_shared_d3d_refcount : 0);
    }
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
        if (hardware_enabled_) {
            // Hardware decoder not found — fall back to software
            blog(LOG_WARNING, "[avolocam] No hardware H.264 decoder found (0x%08X), "
                 "falling back to software decoder", hr);
            hardware_enabled_ = false;
            return create_decoder();  // Retry without MFT_ENUM_FLAG_HARDWARE
        }
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
        if (hardware_enabled_) {
            // ActivateObject failed — GPU hardware session limit likely reached
            blog(LOG_WARNING, "[avolocam] Hardware decoder ActivateObject failed (0x%08X). "
                 "GPU session limit may be reached. Falling back to software decoder.", hr);
            hardware_enabled_ = false;
            return create_decoder();  // Retry with software
        }
        blog(LOG_ERROR, "[avolocam] ActivateObject failed: 0x%08X", hr);
        return false;
    }

    // Enable low-latency mode via MFT attributes (required for real-time streaming)
    // This prevents the decoder from buffering 16+ frames before output
    if (config_.low_latency) {
        IMFAttributes *attrs = nullptr;
        hr = decoder_->GetAttributes(&attrs);
        if (SUCCEEDED(hr) && attrs) {
            // MF_LOW_LATENCY has same GUID as CODECAPI_AVLowLatencyMode
            hr = attrs->SetUINT32(MF_LOW_LATENCY, TRUE);
            if (SUCCEEDED(hr)) {
                blog(LOG_INFO, "[avolocam] MF_LOW_LATENCY enabled via attributes");
            } else {
                blog(LOG_WARNING, "[avolocam] Failed to set MF_LOW_LATENCY: 0x%08X", hr);
            }
            attrs->Release();
        } else {
            blog(LOG_WARNING, "[avolocam] GetAttributes failed: 0x%08X, trying ICodecAPI", hr);
            // Fallback to ICodecAPI for older decoders
            ICodecAPI *codec_api = nullptr;
            hr = decoder_->QueryInterface(__uuidof(ICodecAPI), (void **)&codec_api);
            if (SUCCEEDED(hr) && codec_api) {
                VARIANT var;
                VariantInit(&var);
                var.vt = VT_UI4;  // H.264 decoder uses VT_UI4, not VT_BOOL
                var.ulVal = 1;
                hr = codec_api->SetValue(&CODECAPI_AVLowLatencyMode, &var);
                if (SUCCEEDED(hr)) {
                    blog(LOG_INFO, "[avolocam] Low-latency mode enabled via ICodecAPI");
                }
                codec_api->Release();
            }
        }
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
    if (output_type_) {
        output_type_->Release();
        output_type_ = nullptr;
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
    // Release any previously stored output type
    if (output_type_) {
        output_type_->Release();
        output_type_ = nullptr;
    }

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
            if (SUCCEEDED(hr)) {
                // Store the output type for stride queries
                output_type_ = media_type;
                return true;
            }
            media_type->Release();
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
    uint64_t start = get_time_ns();

    IMFSample *sample = create_sample(data, size);
    if (!sample) return false;

    HRESULT hr = decoder_->ProcessInput(0, sample, 0);
    sample->Release();

    timing_stats_.process_input_ns = get_time_ns() - start;

    if (hr == MF_E_NOTACCEPTING) {
        // Decoder needs output to be retrieved first
        return true;
    }

    return SUCCEEDED(hr);
}

bool MFDecoder::process_output(DecodedFrame &out)
{
    uint64_t start_total = get_time_ns();
    uint64_t lock_time = 0;
    uint64_t memcpy_time = 0;

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

    uint64_t process_start = get_time_ns();
    DWORD status = 0;
    hr = decoder_->ProcessOutput(0, 1, &output, &status);
    uint64_t process_time = get_time_ns() - process_start;

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

    // Get actual frame dimensions from output type (may differ from config)
    UINT32 actual_width = width_;
    UINT32 actual_height = height_;
    if (output_type_) {
        MFGetAttributeSize(output_type_, MF_MT_FRAME_SIZE, &actual_width, &actual_height);
    }

    // Try to get 2D buffer interface
    IMF2DBuffer *buffer_2d = nullptr;
    hr = media_buffer->QueryInterface(__uuidof(IMF2DBuffer), (void **)&buffer_2d);

    if (SUCCEEDED(hr) && buffer_2d) {
        // Use 2D buffer for stride information
        BYTE *data = nullptr;
        LONG pitch = 0;

        uint64_t lock_start = get_time_ns();
        hr = buffer_2d->Lock2D(&data, &pitch);
        lock_time = get_time_ns() - lock_start;

        if (SUCCEEDED(hr)) {
            // Use actual dimensions, not config dimensions
            // NV12: Y plane is pitch * height, UV plane is pitch * height/2
            size_t y_size = (size_t)pitch * actual_height;
            size_t uv_size = (size_t)pitch * actual_height / 2;
            output_buffer_.resize(y_size + uv_size);

            uint64_t copy_start = get_time_ns();

            // Copy Y plane row by row (handles padding correctly)
            BYTE *dst_y = output_buffer_.data();
            BYTE *src_y = data;
            for (UINT32 row = 0; row < actual_height; row++) {
                memcpy(dst_y + row * pitch, src_y + row * pitch, actual_width);
            }

            // Copy UV plane row by row
            // UV plane starts at pitch * actual_height in NV12 layout
            BYTE *dst_uv = output_buffer_.data() + y_size;
            BYTE *src_uv = data + (size_t)pitch * actual_height;
            for (UINT32 row = 0; row < actual_height / 2; row++) {
                memcpy(dst_uv + row * pitch, src_uv + row * pitch, actual_width);
            }

            memcpy_time = get_time_ns() - copy_start;

            buffer_2d->Unlock2D();

            out.width = actual_width;
            out.height = actual_height;
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

        uint64_t lock_start = get_time_ns();
        hr = media_buffer->Lock(&data, &max_length, &current_length);
        lock_time = get_time_ns() - lock_start;

        if (SUCCEEDED(hr)) {
            // Query the actual stride from Media Foundation
            LONG stride = 0;
            UINT32 default_stride = 0;
            if (output_type_ && SUCCEEDED(output_type_->GetUINT32(MF_MT_DEFAULT_STRIDE, &default_stride))) {
                stride = (LONG)default_stride;
            } else {
                // Fallback with 16-byte alignment typical for GPU
                stride = (actual_width + 15) & ~15;
            }

            size_t y_size = (size_t)stride * actual_height;
            size_t uv_size = (size_t)stride * actual_height / 2;

            if (current_length >= y_size + uv_size) {
                uint64_t copy_start = get_time_ns();
                output_buffer_.resize(y_size + uv_size);
                memcpy(output_buffer_.data(), data, y_size + uv_size);
                memcpy_time = get_time_ns() - copy_start;

                out.width = actual_width;
                out.height = actual_height;
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

    // Update timing stats
    timing_stats_.process_output_ns = process_time;
    timing_stats_.lock_buffer_ns = lock_time;
    timing_stats_.memcpy_ns = memcpy_time;
    timing_stats_.total_decode_ns = get_time_ns() - start_total;
    timing_stats_.accumulate();
    timing_stats_.reset_per_frame();

    return out.y_plane != nullptr;
}

bool MFDecoder::process_output_async(DecodedFrame &out)
{
    // Async double-buffered staging: read previous frame while GPU decodes current
    // This avoids waiting for GPU decode to complete

    uint64_t start_total = get_time_ns();

    MFT_OUTPUT_DATA_BUFFER output = {};
    MFT_OUTPUT_STREAM_INFO stream_info = {};

    HRESULT hr = decoder_->GetOutputStreamInfo(0, &stream_info);
    if (FAILED(hr)) return false;

    bool decoder_allocates = (stream_info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) != 0;

    IMFSample *output_sample = nullptr;
    if (!decoder_allocates) {
        IMFMediaBuffer *buffer = nullptr;
        hr = MFCreateMemoryBuffer(stream_info.cbSize, &buffer);
        if (FAILED(hr)) return false;

        hr = MFCreateSample(&output_sample);
        if (FAILED(hr)) { buffer->Release(); return false; }

        hr = output_sample->AddBuffer(buffer);
        buffer->Release();
        if (FAILED(hr)) { output_sample->Release(); return false; }
    }

    output.pSample = output_sample;

    DWORD status = 0;
    hr = decoder_->ProcessOutput(0, 1, &output, &status);

    if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) {
        if (output_sample) output_sample->Release();
        return false;
    }

    if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
        if (output.pSample) output.pSample->Release();
        if (!configure_output_type()) return false;
        return process_output_async(out);
    }

    if (FAILED(hr)) {
        if (output.pSample) output.pSample->Release();
        return false;
    }

    IMFSample *result_sample = output.pSample;
    if (!result_sample) return false;

    // Get buffer and try to get DXGI buffer for GPU texture
    IMFMediaBuffer *media_buffer = nullptr;
    hr = result_sample->GetBufferByIndex(0, &media_buffer);
    if (FAILED(hr)) {
        result_sample->Release();
        return false;
    }

    // Try DXGI buffer for async copy
    IMFDXGIBuffer *dxgi_buffer = nullptr;
    hr = media_buffer->QueryInterface(__uuidof(IMFDXGIBuffer), (void **)&dxgi_buffer);

    if (SUCCEEDED(hr) && dxgi_buffer && d3d_context_) {
        ID3D11Texture2D *decoder_texture = nullptr;
        UINT subresource = 0;

        hr = dxgi_buffer->GetResource(__uuidof(ID3D11Texture2D), (void **)&decoder_texture);
        if (SUCCEEDED(hr) && decoder_texture) {
            dxgi_buffer->GetSubresourceIndex(&subresource);

            D3D11_TEXTURE2D_DESC desc;
            decoder_texture->GetDesc(&desc);

            // Create staging textures if needed
            if (!create_staging_textures(desc.Width, desc.Height)) {
                decoder_texture->Release();
                dxgi_buffer->Release();
                media_buffer->Release();
                result_sample->Release();
                // Fall back to sync path
                return process_output(out);
            }

            // Copy to staging (async - returns immediately)
            d3d_context_->CopySubresourceRegion(
                staging_textures_[staging_write_idx_], 0,
                0, 0, 0,
                decoder_texture, subresource,
                nullptr);

            decoder_texture->Release();
            dxgi_buffer->Release();
            media_buffer->Release();
            result_sample->Release();

            // If we have a previous frame ready, read it
            if (staging_read_idx_ >= 0) {
                D3D11_MAPPED_SUBRESOURCE mapped;
                // Use DO_NOT_WAIT to avoid blocking if GPU isn't done
                hr = d3d_context_->Map(staging_textures_[staging_read_idx_], 0,
                                        D3D11_MAP_READ, D3D11_MAP_FLAG_DO_NOT_WAIT, &mapped);

                if (hr == DXGI_ERROR_WAS_STILL_DRAWING) {
                    // GPU not done yet - wait this time but next frame will be pipelined
                    hr = d3d_context_->Map(staging_textures_[staging_read_idx_], 0,
                                            D3D11_MAP_READ, 0, &mapped);
                }

                if (SUCCEEDED(hr)) {
                    // Copy to output buffer
                    size_t y_size = (size_t)mapped.RowPitch * staging_height_;
                    size_t uv_size = (size_t)mapped.RowPitch * staging_height_ / 2;
                    output_buffer_.resize(y_size + uv_size);

                    // Copy Y plane
                    memcpy(output_buffer_.data(), mapped.pData, y_size);
                    // Copy UV plane (follows Y in NV12)
                    memcpy(output_buffer_.data() + y_size,
                           (uint8_t*)mapped.pData + y_size, uv_size);

                    d3d_context_->Unmap(staging_textures_[staging_read_idx_], 0);

                    out.width = staging_width_;
                    out.height = staging_height_;
                    out.y_plane = output_buffer_.data();
                    out.uv_plane = output_buffer_.data() + y_size;
                    out.y_stride = (uint32_t)mapped.RowPitch;
                    out.uv_stride = (uint32_t)mapped.RowPitch;
                    out.owns_memory = true;

                    // Swap buffers
                    staging_read_idx_ = staging_write_idx_;
                    staging_write_idx_ = 1 - staging_write_idx_;

                    timing_stats_.total_decode_ns = get_time_ns() - start_total;
                    timing_stats_.accumulate();
                    timing_stats_.reset_per_frame();

                    return true;
                }
            }

            // First frame or map failed - swap and wait for next frame
            staging_read_idx_ = staging_write_idx_;
            staging_write_idx_ = 1 - staging_write_idx_;
            return false;  // No frame ready yet
        }
        if (dxgi_buffer) dxgi_buffer->Release();
    }

    // Fall back to synchronous path
    media_buffer->Release();
    result_sample->Release();
    return process_output(out);
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

    // Process output - use GPU path if enabled
    if (gpu_output_enabled_) {
        return process_output_gpu(out);
    }

    // Use async staging if hardware decoding is available
    if (use_async_staging_ && hardware_enabled_ && d3d_device_) {
        return process_output_async(out);
    }

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

const DecodeTimingStats &MFDecoder::get_timing_stats() const
{
    return timing_stats_;
}

void MFDecoder::reset_timing_stats()
{
    timing_stats_ = DecodeTimingStats{};
}

bool MFDecoder::supports_gpu_output() const
{
    // GPU output requires hardware decoding with D3D11
    return hardware_enabled_ && device_manager_ != nullptr;
}

bool MFDecoder::set_gpu_output(bool enable)
{
    if (enable && !supports_gpu_output()) {
        blog(LOG_WARNING, "[avolocam] GPU output requested but not supported");
        return false;
    }
    gpu_output_enabled_ = enable;
    blog(LOG_INFO, "[avolocam] GPU output %s", enable ? "enabled" : "disabled");
    return true;
}

bool MFDecoder::process_output_gpu(DecodedFrame &out)
{
    uint64_t start_total = get_time_ns();

    MFT_OUTPUT_DATA_BUFFER output = {};
    MFT_OUTPUT_STREAM_INFO stream_info = {};

    HRESULT hr = decoder_->GetOutputStreamInfo(0, &stream_info);
    if (FAILED(hr)) return false;

    // Hardware decoder should provide its own samples
    bool decoder_allocates = (stream_info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) != 0;
    if (!decoder_allocates) {
        // Fallback to CPU path - decoder doesn't provide GPU samples
        return process_output(out);
    }

    output.pSample = nullptr;

    uint64_t process_start = get_time_ns();
    DWORD status = 0;
    hr = decoder_->ProcessOutput(0, 1, &output, &status);
    uint64_t process_time = get_time_ns() - process_start;

    if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) {
        return false;
    }

    if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
        if (output.pSample) output.pSample->Release();
        if (!configure_output_type()) {
            return false;
        }
        return process_output_gpu(out);
    }

    if (FAILED(hr)) {
        if (output.pSample) output.pSample->Release();
        blog(LOG_WARNING, "[avolocam] ProcessOutput (GPU) failed: 0x%08X", hr);
        return false;
    }

    IMFSample *result_sample = output.pSample;
    if (!result_sample) {
        return false;
    }

    // Get the buffer
    IMFMediaBuffer *media_buffer = nullptr;
    hr = result_sample->GetBufferByIndex(0, &media_buffer);
    if (FAILED(hr)) {
        result_sample->Release();
        return false;
    }

    // Try to get DXGI buffer for GPU texture access
    IMFDXGIBuffer *dxgi_buffer = nullptr;
    hr = media_buffer->QueryInterface(__uuidof(IMFDXGIBuffer), (void **)&dxgi_buffer);

    if (SUCCEEDED(hr) && dxgi_buffer) {
        ID3D11Texture2D *texture = nullptr;
        UINT subresource = 0;

        hr = dxgi_buffer->GetResource(__uuidof(ID3D11Texture2D), (void **)&texture);
        if (SUCCEEDED(hr) && texture) {
            hr = dxgi_buffer->GetSubresourceIndex(&subresource);

            // Get dimensions from texture
            D3D11_TEXTURE2D_DESC desc;
            texture->GetDesc(&desc);

            out.width = desc.Width;
            out.height = desc.Height;
            out.gpu_texture = texture;
            out.gpu_subresource = subresource;
            out.has_gpu_texture = true;
            out.owns_memory = false;

            // Keep sample reference for texture lifetime
            out.platform_handle = result_sample;

            // Don't release texture or sample here - caller is responsible

            dxgi_buffer->Release();
            media_buffer->Release();

            // Update timing stats
            timing_stats_.process_output_ns = process_time;
            timing_stats_.lock_buffer_ns = 0;  // No lock in GPU path
            timing_stats_.memcpy_ns = 0;       // No memcpy in GPU path
            timing_stats_.total_decode_ns = get_time_ns() - start_total;
            timing_stats_.accumulate();
            timing_stats_.reset_per_frame();

            return true;
        }
        dxgi_buffer->Release();
    }

    // GPU extraction failed, fall back to CPU
    media_buffer->Release();
    result_sample->Release();

    blog(LOG_DEBUG, "[avolocam] GPU texture extraction failed, falling back to CPU");
    return process_output(out);
}

// Factory method implementation for Windows
std::unique_ptr<PlatformDecoder> PlatformDecoder::create(const DecoderConfig &config)
{
    blog(LOG_INFO, "[avolocam] Creating platform decoder (Windows), type=%d",
         static_cast<int>(config.decoder_type));

    switch (config.decoder_type) {
#ifdef HAVE_FFMPEG_D3D11VA
    case DecoderType::FFMPEG_D3D11VA:
        blog(LOG_INFO, "[avolocam] Explicitly requested FFmpeg D3D11VA decoder");
        if (FFmpegD3D11VADecoder::is_available()) {
            return std::make_unique<FFmpegD3D11VADecoder>(config);
        }
        blog(LOG_WARNING, "[avolocam] FFmpeg D3D11VA not available, falling back to MF");
        return std::make_unique<MFDecoder>(config);
#endif

    case DecoderType::MEDIA_FOUNDATION:
        blog(LOG_INFO, "[avolocam] Explicitly requested Media Foundation decoder");
        return std::make_unique<MFDecoder>(config);

    case DecoderType::AUTO:
    default:
        // AUTO: Use MF by default on Windows (proven stable)
        // User can explicitly select FFmpeg D3D11VA via UI if desired
        blog(LOG_INFO, "[avolocam] AUTO: Using Media Foundation decoder");
        return std::make_unique<MFDecoder>(config);
    }
}

} // namespace avolocam

#endif // _WIN32
