#ifndef NM_DERIV_INCLUDED
#define NM_DERIV_INCLUDED

// =============================================================================
// Deriv.hlsl — filter/deriv, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/deriv/wgsl/deriv.wgsl
//
// Derivative-based edge detection. Samples neighbours offset by `amount` texels,
// desaturates, computes dx/dy differences, multiplies the original color by the
// Euclidean distance of the derivatives * 2.5.
//
// WGSL main():
//   let texSize    = vec2<f32>(textureDimensions(inputTex));
//   let uv         = pos.xy / texSize;
//   let texelSize  = 1.0 / texSize;
//   let color      = textureSample(inputTex, inputSampler, uv);
//   let center     = desaturate(color.rgb);
//   let right      = desaturate(textureSample(inputTex, inputSampler,
//                        uv + vec2<f32>(texelSize.x * amount, 0.0)).rgb);
//   let bottom     = desaturate(textureSample(inputTex, inputSampler,
//                        uv + vec2<f32>(0.0, texelSize.y * amount)).rgb);
//   let dx         = center - right;
//   let dy         = center - bottom;
//   let dist       = distance(dx, dy) * 2.5;
//   return vec4<f32>(clamp(color.rgb * dist, vec3<f32>(0.0), vec3<f32>(1.0)), color.a);
//
// PORTING-GUIDE notes:
//  * Single render pass (definition.js passes.length == 1, program "deriv").
//  * Kind: filter — samples "inputTex".
//  * uv is fragCoord / the INPUT TEXTURE's own dimensions (the WGSL divides by
//    textureDimensions(inputTex), not fullResolution). NM_FragCoord(i) / texSize.
//  * desaturate() is this effect's OWN helper — ported VERBATIM inline here.
//  * WGSL uses distance(vec3, vec3) (Euclidean distance on 3-component vectors).
//    HLSL distance() is generic over float3 — same computation, exact parity.
//  * amount: float uniform, default 2.0.
//  * No PRNG, no atan2, no select-reversal, no bit reinterpret in this effect.
//  * Linear, clamp-to-edge, non-sRGB sampler (H7).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
float amount;   // globals.amount.uniform "amount", default 2.0

// -----------------------------------------------------------------------------
// desaturate — ported VERBATIM from deriv.wgsl.
// WGSL: let avg = 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
//        return vec3<f32>(avg);
// -----------------------------------------------------------------------------
float3 desaturate(float3 color)
{
    float avg = 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
    return float3(avg, avg, avg);
}

// -----------------------------------------------------------------------------
// nm_deriv — core per-pixel evaluation.
// Takes the already-resolved uv, texSize, and inputTex + sampler; returns RGBA.
// Pure function so the Shader Graph wrapper and the render pass share identical
// math.
// -----------------------------------------------------------------------------
float4 nm_deriv(
    Texture2D    inputTex,
    SamplerState sampler_inputTex,
    float2       uv,
    float2       texSize)
{
    float2 texelSize = 1.0 / texSize;

    float4 color  = inputTex.Sample(sampler_inputTex, uv);

    // Desaturated center / right / bottom — verbatim from WGSL.
    float3 center = desaturate(color.rgb);
    float3 right  = desaturate(inputTex.Sample(sampler_inputTex,
                        uv + float2(texelSize.x * amount, 0.0)).rgb);
    float3 bottom = desaturate(inputTex.Sample(sampler_inputTex,
                        uv + float2(0.0, texelSize.y * amount)).rgb);

    float3 dx   = center - right;
    float3 dy   = center - bottom;

    float  dist = distance(dx, dy) * 2.5;

    return float4(clamp(color.rgb * dist, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0)), color.a);
}

#endif // NM_DERIV_INCLUDED
