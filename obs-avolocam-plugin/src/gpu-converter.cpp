/**
 * gpu-converter.cpp - D3D11 GPU colorspace converter implementation
 */

#include "gpu-converter.h"

#ifdef _WIN32

#include <obs-module.h>
#include <d3d11_3.h>
#include <d3dcompiler.h>
#include <cstring>

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
        blog(LOG_ERROR, "[avolocam] GPUConverter: null device or context");
        return false;
    }

    device_ = device;
    context_ = context;

    // Don't AddRef - we don't own these
    // The decoder owns the device lifetime

    if (!create_shader()) {
        blog(LOG_ERROR, "[avolocam] GPUConverter: failed to create shader");
        device_ = nullptr;
        context_ = nullptr;
        return false;
    }

    if (!create_constant_buffer()) {
        blog(LOG_ERROR, "[avolocam] GPUConverter: failed to create constant buffer");
        shader_->Release();
        shader_ = nullptr;
        device_ = nullptr;
        context_ = nullptr;
        return false;
    }

    if (!create_sampler()) {
        blog(LOG_ERROR, "[avolocam] GPUConverter: failed to create sampler");
        constant_buffer_->Release();
        constant_buffer_ = nullptr;
        shader_->Release();
        shader_ = nullptr;
        device_ = nullptr;
        context_ = nullptr;
        return false;
    }

    initialized_ = true;
    blog(LOG_INFO, "[avolocam] GPUConverter initialized");
    return true;
}

void GPUConverter::shutdown()
{
    if (!initialized_) return;

    release_input_srvs();

    // Release staging NV12 texture
    if (staging_nv12_) {
        staging_nv12_->Release();
        staging_nv12_ = nullptr;
    }
    staging_width_ = 0;
    staging_height_ = 0;

    // Release texture pool
    for (size_t i = 0; i < TEXTURE_POOL_SIZE; i++) {
        if (texture_pool_[i].uav) {
            texture_pool_[i].uav->Release();
            texture_pool_[i].uav = nullptr;
        }
        if (texture_pool_[i].texture) {
            texture_pool_[i].texture->Release();
            texture_pool_[i].texture = nullptr;
        }
        texture_pool_[i].shared_handle = nullptr;
        texture_pool_[i].in_use = false;
    }

    if (sampler_) {
        sampler_->Release();
        sampler_ = nullptr;
    }

    if (constant_buffer_) {
        constant_buffer_->Release();
        constant_buffer_ = nullptr;
    }

    if (shader_) {
        shader_->Release();
        shader_ = nullptr;
    }

    device_ = nullptr;
    context_ = nullptr;
    initialized_ = false;

    blog(LOG_INFO, "[avolocam] GPUConverter shutdown");
}

bool GPUConverter::create_shader()
{
    ID3DBlob *bytecode = nullptr;
    ID3DBlob *errors = nullptr;

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
            blog(LOG_ERROR, "[avolocam] Shader compile error: %s",
                 (const char *)errors->GetBufferPointer());
            errors->Release();
        }
        return false;
    }

    if (errors) errors->Release();

    hr = device_->CreateComputeShader(
        bytecode->GetBufferPointer(),
        bytecode->GetBufferSize(),
        nullptr,
        &shader_);

    bytecode->Release();

    if (FAILED(hr)) {
        blog(LOG_ERROR, "[avolocam] CreateComputeShader failed: 0x%08X", hr);
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
        blog(LOG_ERROR, "[avolocam] CreateBuffer (constants) failed: 0x%08X", hr);
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
        blog(LOG_ERROR, "[avolocam] CreateSamplerState failed: 0x%08X", hr);
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

            ID3D11Texture2D *texture = nullptr;
            HRESULT hr = device_->CreateTexture2D(&desc, nullptr, &texture);
            if (FAILED(hr)) {
                blog(LOG_ERROR, "[avolocam] CreateTexture2D (output) failed: 0x%08X", hr);
                return nullptr;
            }

            // Create UAV
            D3D11_UNORDERED_ACCESS_VIEW_DESC uav_desc = {};
            uav_desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
            uav_desc.ViewDimension = D3D11_UAV_DIMENSION_TEXTURE2D;
            uav_desc.Texture2D.MipSlice = 0;

            ID3D11UnorderedAccessView *uav = nullptr;
            hr = device_->CreateUnorderedAccessView(texture, &uav_desc, &uav);
            if (FAILED(hr)) {
                texture->Release();
                blog(LOG_ERROR, "[avolocam] CreateUnorderedAccessView failed: 0x%08X", hr);
                return nullptr;
            }

            // Get shared handle
            IDXGIResource *dxgi_resource = nullptr;
            hr = texture->QueryInterface(__uuidof(IDXGIResource), (void **)&dxgi_resource);
            HANDLE shared_handle = nullptr;
            if (SUCCEEDED(hr) && dxgi_resource) {
                dxgi_resource->GetSharedHandle(&shared_handle);
                dxgi_resource->Release();
            }

            texture_pool_[i].texture = texture;
            texture_pool_[i].uav = uav;
            texture_pool_[i].shared_handle = shared_handle;
            texture_pool_[i].width = width;
            texture_pool_[i].height = height;
            texture_pool_[i].in_use = true;

            blog(LOG_INFO, "[avolocam] Created output texture %ux%u in pool slot %zu",
                 width, height, i);

            return &texture_pool_[i];
        }
    }

    // Pool full - find least recently used (first not in use, any size)
    for (size_t i = 0; i < TEXTURE_POOL_SIZE; i++) {
        if (!texture_pool_[i].in_use) {
            // Release old resources and null out immediately to prevent
            // double-free if CreateTexture2D fails below
            if (texture_pool_[i].uav) texture_pool_[i].uav->Release();
            if (texture_pool_[i].texture) texture_pool_[i].texture->Release();
            texture_pool_[i].uav = nullptr;
            texture_pool_[i].texture = nullptr;
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

            ID3D11Texture2D *texture = nullptr;
            HRESULT hr = device_->CreateTexture2D(&desc, nullptr, &texture);
            if (FAILED(hr)) {
                blog(LOG_ERROR, "[avolocam] CreateTexture2D (pool resize) failed: 0x%08X", hr);
                return nullptr;
            }

            D3D11_UNORDERED_ACCESS_VIEW_DESC uav_desc = {};
            uav_desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
            uav_desc.ViewDimension = D3D11_UAV_DIMENSION_TEXTURE2D;

            ID3D11UnorderedAccessView *uav = nullptr;
            hr = device_->CreateUnorderedAccessView(texture, &uav_desc, &uav);
            if (FAILED(hr)) {
                texture->Release();
                return nullptr;
            }

            IDXGIResource *dxgi_resource = nullptr;
            hr = texture->QueryInterface(__uuidof(IDXGIResource), (void **)&dxgi_resource);
            HANDLE shared_handle = nullptr;
            if (SUCCEEDED(hr) && dxgi_resource) {
                dxgi_resource->GetSharedHandle(&shared_handle);
                dxgi_resource->Release();
            }

            texture_pool_[i].texture = texture;
            texture_pool_[i].uav = uav;
            texture_pool_[i].shared_handle = shared_handle;
            texture_pool_[i].width = width;
            texture_pool_[i].height = height;
            texture_pool_[i].in_use = true;

            return &texture_pool_[i];
        }
    }

    blog(LOG_WARNING, "[avolocam] Texture pool exhausted");
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
        if (staging_nv12_) {
            staging_nv12_->Release();
            staging_nv12_ = nullptr;
        }

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
            blog(LOG_ERROR, "[avolocam] Failed to create staging NV12 texture: 0x%08X", hr);
            return false;
        }

        staging_width_ = tex_desc.Width;
        staging_height_ = tex_desc.Height;

        blog(LOG_INFO, "[avolocam] Created staging NV12 texture %ux%u", staging_width_, staging_height_);
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
    ID3D11Device3 *device3 = nullptr;
    HRESULT hr = device_->QueryInterface(__uuidof(ID3D11Device3), (void **)&device3);
    if (FAILED(hr) || !device3) {
        blog(LOG_ERROR, "[avolocam] Failed to get ID3D11Device3: 0x%08X", hr);
        return false;
    }

    // Y plane SRV (plane 0) - R8_UNORM
    D3D11_SHADER_RESOURCE_VIEW_DESC1 y_srv_desc = {};
    y_srv_desc.Format = DXGI_FORMAT_R8_UNORM;
    y_srv_desc.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
    y_srv_desc.Texture2D.MostDetailedMip = 0;
    y_srv_desc.Texture2D.MipLevels = 1;
    y_srv_desc.Texture2D.PlaneSlice = 0;  // Y plane

    hr = device3->CreateShaderResourceView1(staging_nv12_, &y_srv_desc, (ID3D11ShaderResourceView1 **)&y_srv_);
    if (FAILED(hr)) {
        blog(LOG_ERROR, "[avolocam] CreateShaderResourceView1 (Y plane on staging) failed: 0x%08X", hr);
        device3->Release();
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
    device3->Release();

    if (FAILED(hr)) {
        blog(LOG_ERROR, "[avolocam] CreateShaderResourceView1 (UV plane on staging) failed: 0x%08X", hr);
        y_srv_->Release();
        y_srv_ = nullptr;
        return false;
    }

    srv_width_ = staging_width_;
    srv_height_ = staging_height_;

    blog(LOG_INFO, "[avolocam] Created NV12 plane SRVs on staging texture");
    return true;
}

void GPUConverter::release_input_srvs()
{
    if (y_srv_) {
        y_srv_->Release();
        y_srv_ = nullptr;
    }
    if (uv_srv_) {
        uv_srv_->Release();
        uv_srv_ = nullptr;
    }
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
    ID3D11ShaderResourceView *srvs[] = { y_srv_, uv_srv_ };
    context_->CSSetShaderResources(0, 2, srvs);
    context_->CSSetUnorderedAccessViews(0, 1, &out_tex->uav, nullptr);
    context_->CSSetConstantBuffers(0, 1, &constant_buffer_);
    context_->CSSetSamplers(0, 1, &sampler_);

    // Dispatch compute shader
    // 16x16 threads per group
    UINT groups_x = (input.width + 15) / 16;
    UINT groups_y = (input.height + 15) / 16;
    context_->Dispatch(groups_x, groups_y, 1);

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

    IDXGIResource *dxgi_resource = nullptr;
    HRESULT hr = texture->QueryInterface(__uuidof(IDXGIResource), (void **)&dxgi_resource);
    if (FAILED(hr) || !dxgi_resource) {
        return nullptr;
    }

    HANDLE handle = nullptr;
    dxgi_resource->GetSharedHandle(&handle);
    dxgi_resource->Release();

    return handle;
}

double GPUConverter::get_avg_conversion_time_ms() const
{
    if (conversion_count_ == 0) return 0.0;
    return (total_conversion_time_ns_ / conversion_count_) / 1e6;
}

} // namespace avolocam

#endif // _WIN32
