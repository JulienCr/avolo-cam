/**
 * nv12_to_rgba.hlsl - NV12 to RGBA compute shader
 *
 * Converts NV12 (Y plane + interleaved UV plane) to RGBA on GPU.
 * Uses BT.709 full range color matrix matching iOS encoder output.
 *
 * Input:
 *   - Y plane: Texture2D (R8)
 *   - UV plane: Texture2D (R8G8)
 *
 * Output:
 *   - RGBA: RWTexture2D (R8G8B8A8)
 */

// Input textures
Texture2D<float> YPlane : register(t0);
Texture2D<float2> UVPlane : register(t1);

// Output texture
RWTexture2D<float4> OutputRGBA : register(u0);

// Sampler for UV interpolation
SamplerState LinearSampler : register(s0);

// Constants
cbuffer ConversionParams : register(b0)
{
    uint2 OutputSize;    // Output dimensions
    uint2 Padding;       // Padding for alignment
};

// BT.709 full range YUV to RGB conversion matrix
// Y:  0-255 -> 0-1
// U:  0-255 -> -0.5 to 0.5 (centered at 128)
// V:  0-255 -> -0.5 to 0.5 (centered at 128)
//
// RGB = | 1.0000   0.0000   1.5748  | * | Y     |
//       | 1.0000  -0.1873  -0.4681  |   | U-0.5 |
//       | 1.0000   1.8556   0.0000  |   | V-0.5 |

[numthreads(16, 16, 1)]
void CSMain(uint3 DTid : SV_DispatchThreadID)
{
    // Bounds check
    if (DTid.x >= OutputSize.x || DTid.y >= OutputSize.y)
        return;

    // Sample Y value at full resolution
    float Y = YPlane.Load(int3(DTid.xy, 0));

    // Sample UV at half resolution (NV12 UV plane is half size)
    // Use nearest neighbor for now (faster than bilinear for 4:2:0)
    uint2 uvCoord = DTid.xy / 2;
    float2 UV = UVPlane.Load(int3(uvCoord, 0));

    // Extract U and V, center them (0.5 = 128/255)
    float U = UV.x - 0.5f;
    float V = UV.y - 0.5f;

    // BT.709 full range conversion
    float R = Y + 1.5748f * V;
    float G = Y - 0.1873f * U - 0.4681f * V;
    float B = Y + 1.8556f * U;

    // Clamp to valid range
    R = saturate(R);
    G = saturate(G);
    B = saturate(B);

    // Output RGBA (alpha = 1.0)
    OutputRGBA[DTid.xy] = float4(R, G, B, 1.0f);
}

// Alternative version using shared NV12 texture (single texture, Y followed by UV)
// This is the more common layout from Media Foundation
[numthreads(16, 16, 1)]
void CSMainNV12Single(uint3 DTid : SV_DispatchThreadID)
{
    // Bounds check
    if (DTid.x >= OutputSize.x || DTid.y >= OutputSize.y)
        return;

    // In NV12 single-texture layout:
    // - Y plane: rows 0 to height-1
    // - UV plane: rows height to height*1.5-1 (interleaved U,V)

    // Sample Y value
    float Y = YPlane.Load(int3(DTid.xy, 0));

    // Calculate UV coordinates
    // UV is at half resolution, and starts after Y plane
    uint uvX = (DTid.x / 2) * 2;  // Align to 2-pixel boundary for UV pair
    uint uvY = OutputSize.y + (DTid.y / 2);

    // Load UV pair (interleaved as R=U, G=V in the texture)
    float2 UV = UVPlane.Load(int3(DTid.x / 2, DTid.y / 2, 0));

    // Extract U and V, center them
    float U = UV.x - 0.5f;
    float V = UV.y - 0.5f;

    // BT.709 full range conversion
    float R = Y + 1.5748f * V;
    float G = Y - 0.1873f * U - 0.4681f * V;
    float B = Y + 1.8556f * U;

    // Clamp and output
    OutputRGBA[DTid.xy] = float4(saturate(R), saturate(G), saturate(B), 1.0f);
}
