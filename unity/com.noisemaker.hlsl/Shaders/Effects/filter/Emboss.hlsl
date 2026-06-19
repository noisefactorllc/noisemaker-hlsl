#ifndef NM_EMBOSS_INCLUDED
#define NM_EMBOSS_INCLUDED

// =============================================================================
// Emboss.hlsl — filter/emboss, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/emboss/wgsl/emboss.wgsl
//
// WGSL main() summary:
//   texSize   = vec2<f32>(textureDimensions(inputTex))
//   uv        = pos.xy / texSize              // pos = @builtin(position), top-left
//   texelSize = 1.0 / texSize
//   origColor = textureSample(inputTex, inputSampler, uv)
//   kernel    = [-2,-1,0, -1,1,1, 0,1,2]     // 3×3 emboss
//   offsets   = 9 neighbour texel offsets (±texelSize)
//   for i in 0..9: conv += textureSample(inputTex, inputSampler, uv + offsets[i]*amount).rgb * kernel[i]
//   return vec4<f32>(clamp(conv, 0, 1), origColor.a)
//
// PORTING notes:
//  * One named uniform: float amount (definition.js globals.amount.uniform).
//  * uv divides by the INPUT TEXTURE's own dimensions (textureDimensions(inputTex)),
//    NOT fullResolution. NM_FragCoord(i) / inputTex dimensions is exact.
//  * No PRNG / no special math; no helpers beyond standard HLSL clamp/float ops.
//  * WGSL is canonical; no Y-flip needed.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// Per-effect uniform (definition.js globals.amount)
float amount;

// -----------------------------------------------------------------------------
// nm_emboss — core per-pixel evaluation.
// Caller is responsible for supplying the already-computed uv and texelSize
// (both derived from inputTex dimensions) so the SG wrapper and the render pass
// share identical math.
// -----------------------------------------------------------------------------
float4 nm_emboss(
    Texture2D    inputTex,
    SamplerState sampler_inputTex,
    float2       uv,
    float2       texelSize,
    float4       origColor)
{
    // Emboss kernel (row-major, matches WGSL array literal exactly):
    // -2 -1  0
    // -1  1  1
    //  0  1  2
    float kernel[9];
    kernel[0] = -2.0; kernel[1] = -1.0; kernel[2] =  0.0;
    kernel[3] = -1.0; kernel[4] =  1.0; kernel[5] =  1.0;
    kernel[6] =  0.0; kernel[7] =  1.0; kernel[8] =  2.0;

    float2 offsets[9];
    offsets[0] = float2(-texelSize.x, -texelSize.y);
    offsets[1] = float2( 0.0,         -texelSize.y);
    offsets[2] = float2( texelSize.x, -texelSize.y);
    offsets[3] = float2(-texelSize.x,  0.0);
    offsets[4] = float2( 0.0,          0.0);
    offsets[5] = float2( texelSize.x,  0.0);
    offsets[6] = float2(-texelSize.x,  texelSize.y);
    offsets[7] = float2( 0.0,          texelSize.y);
    offsets[8] = float2( texelSize.x,  texelSize.y);

    float3 conv = float3(0.0, 0.0, 0.0);

    // WGSL: for (var i = 0; i < 9; i = i + 1)
    [loop]
    for (int i = 0; i < 9; i = i + 1)
    {
        // WGSL: textureSample(inputTex, inputSampler, uv + offsets[i] * uniforms.amount).rgb
        float3 s = inputTex.Sample(sampler_inputTex, uv + offsets[i] * amount).rgb;
        conv = conv + s * kernel[i];
    }

    // WGSL: return vec4<f32>(clamp(conv, vec3<f32>(0.0), vec3<f32>(1.0)), origColor.a)
    return float4(clamp(conv, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0)), origColor.a);
}

#endif // NM_EMBOSS_INCLUDED
