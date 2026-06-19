#ifndef NM_SHARPEN_INCLUDED
#define NM_SHARPEN_INCLUDED

// =============================================================================
// Sharpen.hlsl — filter/sharpen, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/sharpen/wgsl/sharpen.wgsl
//
// Sharpen convolution using a 3x3 kernel that enhances edges and detail.
//
// WGSL main() summary:
//   let texSize    = vec2<f32>(textureDimensions(inputTex));
//   let uv         = pos.xy / texSize;
//   let texelSize  = 1.0 / texSize;
//   kernel = [-1, 0, -1, 0, 5, 0, -1, 0, -1]
//   offsets = 3x3 neighbour texel offsets (scaled by uniforms.amount)
//   conv = sum of sample.rgb * kernel[i]  for i in 0..8
//   return vec4<f32>(clamp(conv, 0, 1), origColor.a);
//
// PORTING NOTES:
//  * uv divides pos.xy by the INPUT TEXTURE's own dimensions
//    (textureDimensions(inputTex)), NOT fullResolution. Mirrored exactly.
//  * The offsets array is multiplied by uniforms.amount before the sample,
//    widening the kernel neighbourhood by the amount param.
//  * No per-effect helpers beyond the kernel loop — no PRNG, no hsv, etc.
//  * origColor.a is preserved from the center sample before the convolution.
//  * textureSampleLevel(..., 0.0) maps to inputTex.SampleLevel(..., 0) in HLSL.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// Per-effect uniform from definition.js globals:
//   amount: float, default 1.0, range [0.1, 5]
float amount;

// -----------------------------------------------------------------------------
// nm_sharpen — core convolution. inputTex + sampler_inputTex must be in scope
// (declared in the .shader pass that calls this function).
// texSize : float2(inputTex.GetDimensions()), uv : fragCoord / texSize
// -----------------------------------------------------------------------------
float4 nm_sharpen(Texture2D inputTex, SamplerState sampler_inputTex, float2 uv, float2 texSize)
{
    float2 texelSize = 1.0 / texSize;

    // WGSL: let origColor = textureSampleLevel(inputTex, inputSampler, uv, 0.0);
    float4 origColor = inputTex.SampleLevel(sampler_inputTex, uv, 0);

    // WGSL: let kernel = array<f32, 9>(-1.0, 0.0, -1.0, 0.0, 5.0, 0.0, -1.0, 0.0, -1.0);
    float kernel[9];
    kernel[0] = -1.0; kernel[1] =  0.0; kernel[2] = -1.0;
    kernel[3] =  0.0; kernel[4] =  5.0; kernel[5] =  0.0;
    kernel[6] = -1.0; kernel[7] =  0.0; kernel[8] = -1.0;

    // WGSL offsets array (verbatim order, top-left orientation matches WGSL)
    float2 offsets[9];
    offsets[0] = float2(-texelSize.x, -texelSize.y);
    offsets[1] = float2( 0.0,         -texelSize.y);
    offsets[2] = float2( texelSize.x, -texelSize.y);
    offsets[3] = float2(-texelSize.x,  0.0        );
    offsets[4] = float2( 0.0,          0.0        );
    offsets[5] = float2( texelSize.x,  0.0        );
    offsets[6] = float2(-texelSize.x,  texelSize.y);
    offsets[7] = float2( 0.0,          texelSize.y);
    offsets[8] = float2( texelSize.x,  texelSize.y);

    // WGSL: var conv = vec3<f32>(0.0);
    float3 conv = float3(0.0, 0.0, 0.0);

    // WGSL: for (var i = 0; i < 9; i = i + 1) {
    //           let sample = textureSampleLevel(inputTex, inputSampler, uv + offsets[i] * uniforms.amount, 0.0).rgb;
    //           conv = conv + sample * kernel[i];
    //       }
    [loop]
    for (int i = 0; i < 9; i = i + 1)
    {
        float3 s = inputTex.SampleLevel(sampler_inputTex, uv + offsets[i] * amount, 0).rgb;
        conv = conv + s * kernel[i];
    }

    // WGSL: return vec4<f32>(clamp(conv, vec3<f32>(0.0), vec3<f32>(1.0)), origColor.a);
    return float4(clamp(conv, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0)), origColor.a);
}

#endif // NM_SHARPEN_INCLUDED
