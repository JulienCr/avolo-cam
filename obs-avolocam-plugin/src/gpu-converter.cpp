/**
 * gpu-converter.cpp - D3D11 GPU colorspace converter implementation
 */

#include "gpu-converter.h"

#ifdef _WIN32

#include <cstring>

#include <d3d11_3.h>
#include <d3dcompiler.h>

#include <obs-module.h>

#include "logging.h"

#pragma comment(lib, "d3dcompiler.lib")

namespace avolocam {

// Embedded shader source (compiled at runtime for flexibility)
// In production, this could be pre-compiled to CSO files
static const char *NV12_TO_RGBA_SHADER = R"(
Texture2D<float> YPlane : register(t0);
Texture2D<float2> UVPlane : register(t1);
RWTexture2D<float4> OutputRGBA : register(u0);

cbuffer ConversionParams : register(b0)
{
    uint2 OutputSize;
    uint2 Padding;
};

[numthreads(16, 16, 1)]
void CSMain(uint3 DTid : SV_DispatchThreadID)
{
    if (DTid.x >= OutputSize.x || DTid.y >= OutputSize.y)
        return;

    float Y = YPlane.Load(int3(DTid.xy, 0));
    uint2 uvCoord = DTid.xy / 2;
    float2 UV = UVPlane.Load(int3(uvCoord, 0));

    float U = UV.x - 0.5f;
    float V = UV.y - 0.5f;

    // BT.709 full range
    float R = Y + 1.5748f * V;
    float G = Y - 0.1873f * U - 0.4681f * V;
    float B = Y + 1.8556f * U;

    OutputRGBA[DTid.xy] = float4(saturate(R), saturate(G), saturate(B), 1.0f);
}
)";

// High-resolution timing
static inline uint64_t get_time_ns() {
    LARGE_INTEGER freq, counter;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&counter);
    return (uint64_t)((counter.QuadPart * 1000000000LL) / freq.QuadPart);
}

GPUConverter::GPUConverter()
{
}

GPUConverter::~GPUConverter()
{
    shutdown();
}

bool GPUConverter::initialize(ID3D11Device *device, ID3D11DeviceContext *context)
{
    if (!device || !context) {
        ALOG_GPU(LOG_ERROR, "null device or context");
        return false;
    }

    // Option B: AddRef via operator= (safe even if decoder destroyed first)
    device_ = device;
    context_ = context;

    if (!create_shader()) {
        ALOG_GPU(LOG_ERROR, "failed to create shader");
        device_.Clear();
        context_.Clear();
        return false;
    }

    if (!create_constant_buffer()) {
        ALOG_GPU(LOG_ERROR, "failed to create constant buffer");
        shader_.Clear();
        device_.Clear();
        context_.Clear();
        return false;
    }

    if (!create_sampler()) {
        ALOG_GPU(LOG_ERROR, "failed to create sampler");
        constant_buffer_.Clear();
        shader_.Clear();
        device_.Clear();
        context_.Clear();
        return false;
    }

    initialized_ = true;
    ALOG_GPU(LOG_INFO, "GPUConverter initialized");
    return true;
}

void GPUConverter::shutdown()
{
    if (!initialized_) return;

    release_input_srvs();

    staging_nv12_.Clear();
    staging_width_ = 0;
    staging_height_ = 0;

    // Release texture pool
    for (size_t i = 0; i < TEXTURE_POOL_SIZE; i++) {
        texture_pool_[i].uav.Clear();
        texture_pool_[i].texture.Clear();
        texture_pool_[i].shared_handle = nullptr;
        texture_pool_[i].in_use = false;
    }

    sampler_.Clear();
    constant_buffer_.Clear();
    shader_.Clear();
    device_.Clear();
    context_.Clear();
    initialized_ = false;

    ALOG_GPU(LOG_INFO, "GPUConverter shutdown");
}

bool GPUConverter::create_shader()
{
    ComPtr<ID3DBlob> bytecode;
    ComPtr<ID3DBlob> errors;

    UINT flags = D3DCOMPILE_OPTIMIZATION_LEVEL3;
#ifdef _DEBUG
    flags |= D3DCOMPILE_DEBUG;
#endif

    HRESULT hr = D3DCompile(
        NV12_TO_RGBA_SHADER,
        strlen(NV12_TO_RGBA_SHADER),
        "nv12_to_rgba.hlsl",
        nullptr,  // defines
        nullptr,  // include
        "CSMain",
        "cs_5_0",
        flags,
        0,
        &bytecode,
        &errors);

    if (FAILED(hr)) {
        if (errors) {
            ALOG_GPU(LOG_ERROR, "Shader compile error: %s",
                 (const char *)errors->GetBufferPointer());
        }
        return false;
    }

    hr = device_->CreateComputeShader(
        bytecode->GetBufferPointer(),
        bytecode->GetBufferSize(),
        nullptr,
        &shader_);

    if (FAILED(hr)) {
        ALOG_GPU(LOG_ERROR, "CreateComputeShader failed: 0x%08X", hr);
        return false;
    }

    return true;
}

bool GPUConverter::create_constant_buffer()
{
    struct ConstantData {
        uint32_t width;
        uint32_t height;
        uint32_t padding[2];
    };

    D3D11_BUFFER_DESC desc = {};
    desc.ByteWidth = sizeof(ConstantData);
    desc.Usage = D3D11_USAGE_DYNAMIC;
    desc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;

    HRESULT hr = device_->CreateBuffer(&desc, nullptr, &constant_buffer_);
    if (FAILED(hr)) {
        ALOG_GPU(LOG_ERROR, "CreateBuffer (constants) failed: 0x%08X", hr);
        return false;
    }

    return true;
}

bool GPUConverter::create_sampler()
{
    D3D11_SAMPLER_DESC desc = {};
    desc.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    desc.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
    desc.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
    desc.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;

    HRESULT hr = device_->CreateSamplerState(&desc, &sampler_);
    if (FAILED(hr)) {
        ALOG_GPU(LOG_ERROR, "CreateSamplerState failed: 0x%08X", hr);
        return false;
    }

    return true;
}

GPUConverter::PooledTexture *GPUConverter::get_or_create_output_texture(
    uint32_t width, uint32_t height)
{
    // First, look for an existing texture of the right size that's not in use
    for (size_t i = 0; i < TEXTURE_POOL_SIZE; i++) {
        if (!texture_pool_[i].in_use &&
            texture_pool_[i].width == width &&
            texture_pool_[i].height == height) {
            texture_pool_[i].in_use = true;
            return &texture_pool_[i];
        }
    }

    // Next, look for an empty slot
    for (size_t i = 0; i < TEXTURE_POOL_SIZE; i++) {
        if (!texture_pool_[i].texture) {
            // Create new texture
            D3D11_TEXTURE2D_DESC desc = {};
            desc.Width = width;
            desc.Height = height;
            desc.MipLevels = 1;
            desc.ArraySize = 1;
            desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
            desc.SampleDesc.Count = 1;
            desc.Usage = D3D11_USAGE_DEFAULT;
            desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_UNORDERED_ACCESS;
            desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;

            HRESULT hr = device_->CreateTexture2D(&desc, nullptr, &texture_pool_[i].texture);
            if (FAILED(hr)) {
                ALOG_GPU(LOG_ERROR, "CreateTexture2D (output) failed: 0x%08X", hr);
                return nullptr;
            }

            // Create UAV
            D3D11_UNORDERED_ACCESS_VIEW_DESC uav_desc = {};
            uav_desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
            uav_desc.ViewDimension = D3D11_UAV_DIMENSION_TEXTURE2D;
            uav_desc.Texture2D.MipSlice = 0;

            hr = device_->CreateUnorderedAccessView(texture_pool_[i].texture, &uav_desc, &texture_pool_[i].uav);
            if (FAILED(hr)) {
                texture_pool_[i].texture.Clear();
                ALOG_GPU(LOG_ERROR, "CreateUnorderedAccessView failed: 0x%08X", hr);
                return nullptr;
            }

            // Get shared handle
            ComQIPtr<IDXGIResource> dxgi_resource(texture_pool_[i].texture);
            HANDLE shared_handle = nullptr;
            if (dxgi_resource) {
                dxgi_resource->GetSharedHandle(&shared_handle);
            }

            texture_pool_[i].shared_handle = shared_handle;
            texture_pool_[i].width = width;
            texture_pool_[i].height = height;
            texture_pool_[i].in_use = true;

            ALOG_GPU(LOG_INFO, "Created output texture %ux%u in pool slot %zu",
                 width, height, i);

            return &texture_pool_[i];
        }
    }

    // Pool full - find least recently used (first not in use, any size)
    for (size_t i = 0; i < TEXTURE_POOL_SIZE; i++) {
        if (!texture_pool_[i].in_use) {
            // Release old resources
            texture_pool_[i].uav.Clear();
            texture_pool_[i].texture.Clear();
            texture_pool_[i].shared_handle = nullptr;
            texture_pool_[i].width = 0;
            texture_pool_[i].height = 0;

            // Create new texture at new size
            D3D11_TEXTURE2D_DESC desc = {};
            desc.Width = width;
            desc.Height = height;
            desc.MipLevels = 1;
            desc.ArraySize = 1;
            desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
            desc.SampleDesc.Count = 1;
            desc.Usage = D3D11_USAGE_DEFAULT;
            desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_UNORDERED_ACCESS;
            desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;

            HRESULT hr = device_->CreateTexture2D(&desc, nullptr, &texture_pool_[i].texture);
            if (FAILED(hr)) {
                ALOG_GPU(LOG_ERROR, "CreateTexture2D (pool resize) failed: 0x%08X", hr);
                return nullptr;
            }

            D3D11_UNORDERED_ACCESS_VIEW_DESC uav_desc = {};
            uav_desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
            uav_desc.ViewDimension = D3D11_UAV_DIMENSION_TEXTURE2D;

            hr = device_->CreateUnorderedAccessView(texture_pool_[i].texture, &uav_desc, &texture_pool_[i].uav);
            if (FAILED(hr)) {
                texture_pool_[i].texture.Clear();
                return nullptr;
            }

            ComQIPtr<IDXGIResource> dxgi_resource(texture_pool_[i].texture);
            HANDLE shared_handle = nullptr;
            if (dxgi_resource) {
                dxgi_resource->GetSharedHandle(&shared_handle);
            }

            texture_pool_[i].shared_handle = shared_handle;
            texture_pool_[i].width = width;
            texture_pool_[i].height = height;
            texture_pool_[i].in_use = true;

            return &texture_pool_[i];
        }
    }

    ALOG_GPU(LOG_WARNING, "Texture pool exhausted");
    return nullptr;
}

bool GPUConverter::create_input_srvs(ID3D11Texture2D *texture, uint32_t subresource,
                                      uint32_t width, uint32_t height)
{
    // The MF decoder's texture doesn't have D3D11_BIND_SHADER_RESOURCE flag,
    // so we need to copy to a staging texture that does have this flag.

    D3D11_TEXTURE2D_DESC tex_desc;
    texture->GetDesc(&tex_desc);

    // Create or recreate staging texture if dimensions changed
    if (!staging_nv12_ || staging_width_ != tex_desc.Width || staging_height_ != tex_desc.Height) {
        // Release old resources
        release_input_srvs();
        staging_nv12_.Clear();

        // Create staging NV12 texture with SHADER_RESOURCE flag
        D3D11_TEXTURE2D_DESC staging_desc = {};
        staging_desc.Width = tex_desc.Width;
        staging_desc.Height = tex_desc.Height;
        staging_desc.MipLevels = 1;
        staging_desc.ArraySize = 1;
        staging_desc.Format = DXGI_FORMAT_NV12;
        staging_desc.SampleDesc.Count = 1;
        staging_desc.Usage = D3D11_USAGE_DEFAULT;
        staging_desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;  // This is the key flag!

        HRESULT hr = device_->CreateTexture2D(&staging_desc, nullptr, &staging_nv12_);
        if (FAILED(hr)) {
            ALOG_GPU(LOG_ERROR, "Failed to create staging NV12 texture: 0x%08X", hr);
            return false;
        }

        staging_width_ = tex_desc.Width;
        staging_height_ = tex_desc.Height;

        ALOG_GPU(LOG_INFO, "Created staging NV12 texture %ux%u", staging_width_, staging_height_);
    }

    // Copy input texture to staging texture (GPU-GPU copy, very fast)
    context_->CopySubresourceRegion(
        staging_nv12_, 0,  // Dest
        0, 0, 0,           // Dest x, y, z
        texture, subresource,  // Src
        nullptr);          // Copy entire resource

    // Now create SRVs on the staging texture if needed
    if (y_srv_ && uv_srv_ && srv_width_ == staging_width_ && srv_height_ == staging_height_) {
        // SRVs already exist for this size
        return true;
    }

    // Release old SRVs
    release_input_srvs();

    // Need ID3D11Device3 for CreateShaderResourceView1 with PlaneSlice
    ComQIPtr<ID3D11Device3> device3(device_);
    if (!device3) {
        ALOG_GPU(LOG_ERROR, "Failed to get ID3D11Device3");
        return false;
    }

    // Y plane SRV (plane 0) - R8_UNORM
    D3D11_SHADER_RESOURCE_VIEW_DESC1 y_srv_desc = {};
    y_srv_desc.Format = DXGI_FORMAT_R8_UNORM;
    y_srv_desc.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
    y_srv_desc.Texture2D.MostDetailedMip = 0;
    y_srv_desc.Texture2D.MipLevels = 1;
    y_srv_desc.Texture2D.PlaneSlice = 0;  // Y plane

    HRESULT hr = device3->CreateShaderResourceView1(staging_nv12_, &y_srv_desc, (ID3D11ShaderResourceView1 **)&y_srv_);
    if (FAILED(hr)) {
        ALOG_GPU(LOG_ERROR, "CreateShaderResourceView1 (Y plane on staging) failed: 0x%08X", hr);
        return false;
    }

    // UV plane SRV (plane 1) - R8G8_UNORM
    D3D11_SHADER_RESOURCE_VIEW_DESC1 uv_srv_desc = {};
    uv_srv_desc.Format = DXGI_FORMAT_R8G8_UNORM;
    uv_srv_desc.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
    uv_srv_desc.Texture2D.MostDetailedMip = 0;
    uv_srv_desc.Texture2D.MipLevels = 1;
    uv_srv_desc.Texture2D.PlaneSlice = 1;  // UV plane

    hr = device3->CreateShaderResourceView1(staging_nv12_, &uv_srv_desc, (ID3D11ShaderResourceView1 **)&uv_srv_);
    if (FAILED(hr)) {
        ALOG_GPU(LOG_ERROR, "CreateShaderResourceView1 (UV plane on staging) failed: 0x%08X", hr);
        y_srv_.Clear();
        return false;
    }

    srv_width_ = staging_width_;
    srv_height_ = staging_height_;

    ALOG_GPU(LOG_INFO, "Created NV12 plane SRVs on staging texture");
    return true;
}

void GPUConverter::release_input_srvs()
{
    y_srv_.Clear();
    uv_srv_.Clear();
    srv_width_ = 0;
    srv_height_ = 0;
}

bool GPUConverter::convert(const GPUDecodedFrame &input, ConvertedFrame &output)
{
    if (!initialized_ || !input.texture) {
        return false;
    }

    uint64_t start = get_time_ns();

    // Get or create output texture
    PooledTexture *out_tex = get_or_create_output_texture(input.width, input.height);
    if (!out_tex) {
        return false;
    }

    // Create SRVs for input texture
    if (!create_input_srvs(input.texture, input.subresource, input.width, input.height)) {
        out_tex->in_use = false;
        return false;
    }

    // Update constant buffer
    struct ConstantData {
        uint32_t width;
        uint32_t height;
        uint32_t padding[2];
    } constants = { input.width, input.height, {0, 0} };

    D3D11_MAPPED_SUBRESOURCE mapped;
    HRESULT hr = context_->Map(constant_buffer_, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped);
    if (SUCCEEDED(hr)) {
        memcpy(mapped.pData, &constants, sizeof(constants));
        context_->Unmap(constant_buffer_, 0);
    }

    // Set compute shader
    context_->CSSetShader(shader_, nullptr, 0);

    // Set resources
    ID3D11ShaderResourceView *srvs[] = { y_srv_.Get(), uv_srv_.Get() };
    context_->CSSetShaderResources(0, 2, srvs);
    ID3D11UnorderedAccessView *uav_raw = out_tex->uav.Get();
    context_->CSSetUnorderedAccessViews(0, 1, &uav_raw, nullptr);
    ID3D11Buffer *cb_raw = constant_buffer_.Get();
    context_->CSSetConstantBuffers(0, 1, &cb_raw);
    ID3D11SamplerState *sampler_raw = sampler_.Get();
    context_->CSSetSamplers(0, 1, &sampler_raw);

    // Dispatch compute shader
    // 16x16 threads per group
    UINT groups_x = (input.width + 15) / 16;
    UINT groups_y = (input.height + 15) / 16;
    context_->Dispatch(groups_x, groups_y, 1);
    context_->Flush();

    // Unbind resources
    ID3D11ShaderResourceView *null_srvs[] = { nullptr, nullptr };
    ID3D11UnorderedAccessView *null_uav = nullptr;
    context_->CSSetShaderResources(0, 2, null_srvs);
    context_->CSSetUnorderedAccessViews(0, 1, &null_uav, nullptr);

    // Fill output
    output.rgba_texture = out_tex->texture;
    output.shared_handle = out_tex->shared_handle;
    output.width = input.width;
    output.height = input.height;
    output.pts = input.pts;

    // Update stats
    uint64_t elapsed = get_time_ns() - start;
    total_conversion_time_ns_ += elapsed;
    conversion_count_++;

    return true;
}

void GPUConverter::release_frame(ConvertedFrame &frame)
{
    // Find the texture in the pool and mark it as not in use
    for (size_t i = 0; i < TEXTURE_POOL_SIZE; i++) {
        if (texture_pool_[i].texture == frame.rgba_texture) {
            texture_pool_[i].in_use = false;
            break;
        }
    }

    frame.rgba_texture = nullptr;
    frame.shared_handle = nullptr;
}

HANDLE GPUConverter::get_shared_handle(ID3D11Texture2D *texture)
{
    if (!texture) return nullptr;

    ComQIPtr<IDXGIResource> dxgi_resource(texture);
    if (!dxgi_resource) {
        return nullptr;
    }

    HANDLE handle = nullptr;
    dxgi_resource->GetSharedHandle(&handle);
    return handle;
}

double GPUConverter::get_avg_conversion_time_ms() const
{
    if (conversion_count_ == 0) return 0.0;
    return (total_conversion_time_ns_ / conversion_count_) / 1e6;
}

} // namespace avolocam

#endif // _WIN32
