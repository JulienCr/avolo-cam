/**
 * gpu-converter.h - D3D11 GPU colorspace converter
 *
 * Provides GPU-accelerated NV12 to RGBA conversion using compute shaders.
 * Eliminates CPU memcpy by keeping data on GPU throughout the pipeline.
 */

#pragma once

#ifdef _WIN32

#include <cstdint>
#include <memory>
#include <d3d11.h>

namespace avolocam {

/**
 * GPU frame with D3D11 texture
 */
struct GPUDecodedFrame {
    ID3D11Texture2D *texture = nullptr;  // Source NV12 texture from decoder
    uint32_t subresource = 0;            // Subresource index (for texture arrays)
    uint32_t width = 0;
    uint32_t height = 0;
    uint64_t pts = 0;
    void *sample_ref = nullptr;          // IMFSample* to keep texture alive
};

/**
 * Converted GPU frame ready for OBS
 */
struct ConvertedFrame {
    ID3D11Texture2D *rgba_texture = nullptr;  // RGBA texture
    HANDLE shared_handle = nullptr;           // Shared handle for cross-device access
    uint32_t width = 0;
    uint32_t height = 0;
    uint64_t pts = 0;
};

/**
 * D3D11 GPU colorspace converter
 *
 * Converts NV12 textures to RGBA using compute shaders.
 * Manages a pool of output textures for efficient reuse.
 */
class GPUConverter {
public:
    GPUConverter();
    ~GPUConverter();

    // Non-copyable
    GPUConverter(const GPUConverter&) = delete;
    GPUConverter& operator=(const GPUConverter&) = delete;

    /**
     * Initialize with D3D11 device
     * @param device D3D11 device from decoder
     * @param context Device context
     * @return true on success
     */
    bool initialize(ID3D11Device *device, ID3D11DeviceContext *context);

    /**
     * Shutdown and release resources
     */
    void shutdown();

    /**
     * Check if converter is ready
     */
    bool is_initialized() const { return initialized_; }

    /**
     * Convert NV12 texture to RGBA
     *
     * @param input Input GPU frame (NV12)
     * @param output Output converted frame (RGBA)
     * @return true on success
     */
    bool convert(const GPUDecodedFrame &input, ConvertedFrame &output);

    /**
     * Release a converted frame back to the pool
     * @param frame Frame to release
     */
    void release_frame(ConvertedFrame &frame);

    /**
     * Get shared handle for a texture (for cross-device sharing)
     * @param texture Texture to get handle for
     * @return Shared handle, or nullptr on failure
     */
    HANDLE get_shared_handle(ID3D11Texture2D *texture);

    /**
     * Get performance statistics
     */
    uint64_t get_conversion_count() const { return conversion_count_; }
    double get_avg_conversion_time_ms() const;

private:
    ID3D11Device *device_ = nullptr;
    ID3D11DeviceContext *context_ = nullptr;
    ID3D11ComputeShader *shader_ = nullptr;
    ID3D11Buffer *constant_buffer_ = nullptr;
    ID3D11SamplerState *sampler_ = nullptr;

    // Texture pool for output RGBA textures
    static const size_t TEXTURE_POOL_SIZE = 4;
    struct PooledTexture {
        ID3D11Texture2D *texture = nullptr;
        ID3D11UnorderedAccessView *uav = nullptr;
        HANDLE shared_handle = nullptr;
        uint32_t width = 0;
        uint32_t height = 0;
        bool in_use = false;
    };
    PooledTexture texture_pool_[TEXTURE_POOL_SIZE];

    // Staging NV12 texture for input (decoder textures don't have SHADER_RESOURCE flag)
    ID3D11Texture2D *staging_nv12_ = nullptr;
    uint32_t staging_width_ = 0;
    uint32_t staging_height_ = 0;

    // SRVs for input textures (created on staging texture)
    ID3D11ShaderResourceView *y_srv_ = nullptr;
    ID3D11ShaderResourceView *uv_srv_ = nullptr;
    uint32_t srv_width_ = 0;
    uint32_t srv_height_ = 0;

    bool initialized_ = false;

    // Performance stats
    uint64_t conversion_count_ = 0;
    uint64_t total_conversion_time_ns_ = 0;

    // Internal methods
    bool create_shader();
    bool create_constant_buffer();
    bool create_sampler();
    PooledTexture *get_or_create_output_texture(uint32_t width, uint32_t height);
    bool create_input_srvs(ID3D11Texture2D *texture, uint32_t subresource,
                           uint32_t width, uint32_t height);
    void release_input_srvs();
};

/**
 * Compile HLSL compute shader from source
 * @param source HLSL source code
 * @param entry_point Entry point function name
 * @param bytecode Output bytecode blob
 * @return true on success
 */
bool compile_compute_shader(const char *source, const char *entry_point,
                            ID3DBlob **bytecode);

} // namespace avolocam

#endif // _WIN32
