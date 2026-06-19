#ifndef NM_EFFECT_BLUR_INCLUDED
#define NM_EFFECT_BLUR_INCLUDED

// =============================================================================
// Blur.hlsl — filter/blur (func: "blur")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL sources:
//   shaders/effects/filter/blur/wgsl/blurH.wgsl  (horizontal pass, progName "blurH")
//   shaders/effects/filter/blur/wgsl/blurV.wgsl  (vertical   pass, progName "blurV")
//
// Two-pass separable Gaussian blur. blurH (inputTex -> _blurTemp) blurs along X
// using radiusX; blurV (_blurTemp -> outputTex) blurs along Y using radiusY.
// Each pass builds a Gaussian kernel of integer radius r (sigma = r/3), samples
// 2r+1 taps along its axis with weight exp(-(i*i)/(2*sigma*sigma)), and returns
// the weighted average. radius<=0 short-circuits to a passthrough sample.
//
// NOTE: this effect is multi-pass and ships as a runtime-rendered Texture2D
// (the C# runtime renders blurH into the internal _blurTemp target, then blurV
// into the output). No Shader Graph Custom Function wrapper is provided.
//
// PORTING-GUIDE notes / hazards handled:
//  * Ported from WGSL (top-left, canonical). The WGSL computes `radius = i32(
//    uniforms.radiusX)` with NO renderScale multiply (GLSL does `int(radiusX *
//    renderScale)`). We follow the WGSL (canonical) exactly: `radius = (int)
//    radiusX`. At renderScale==1 the two agree (PORTING-GUIDE H1).
//  * `uv = pos.xy / texSize` where texSize = textureDimensions(inputTex) — i.e.
//    fragCoord divided by the INPUT TEXTURE's own size, NOT fullResolution and
//    NOT tileOffset-shifted (WGSL adds no tileOffset). We mirror it exactly:
//    NM_FragCoord(i) / float2(w,h). NM_FragCoord is the @builtin(position) (top-
//    left, +0.5 centered) analog; no per-effect Y flip needed (H8).
//  * `int(radiusX)` is float->int TRUNCATION toward zero (HLSL (int) cast), which
//    matches WGSL `i32(f32)` and GLSL `int(float)`.
//  * Loop is radius-driven (dynamic bounds), so the index loop is marked [loop]
//    per reference 07 §8.2. Bounds are inclusive `i <= radius` exactly as written.
//  * exp/length/clamp map 1:1; vec4<f32>(0.0) splat -> float4(0,0,0,0).
//  * Linear, clamp-to-edge, non-sRGB sampler (H7) — set on the SamplerState in
//    Blur.shader. WebGL/WebGPU use bilinear clamp on RGBA (no sRGB decode).
//  * `_pad1`/`_pad2` in the WGSL Uniforms struct are alignment padding only; we
//    bind only the meaningful named uniforms radiusX / radiusY.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (reference binding: sampler@0, inputTex@1) ------
// blurH binds the effect's inputTex; blurV binds the internal _blurTemp target.
// Both use the same HLSL name `inputTex` (the runtime rebinds per pass).
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
// Bound by the runtime via MaterialPropertyBlock by these exact names.
float radiusX;  // globals.radiusX.uniform, [0,50] step 1, default 5
float radiusY;  // globals.radiusY.uniform, [0,50] step 1, default 5

// -----------------------------------------------------------------------------
// nm_blur_gaussian — verbatim from WGSL blurH/blurV main() (axis-parameterized).
// `uv`        sample coordinate (fragCoord / inputTex dimensions)
// `texelSize` 1.0 / inputTex dimensions
// `radiusF`   raw radius uniform for this axis (radiusX for H, radiusY for V)
// `axis`      (1,0) for the horizontal pass, (0,1) for the vertical pass; the
//             per-tap offset is `i * texelSize * axis` which reduces to the WGSL
//             `vec2(f32(i)*texelSize.x, 0.0)` / `vec2(0.0, f32(i)*texelSize.y)`.
//
// WGSL:
//   let radius = i32(uniforms.radiusX);
//   if (radius <= 0) { return textureSample(inputTex, inputSampler, uv); }
//   let sigma = f32(radius) / 3.0;
//   let sigma2 = sigma * sigma;
//   var sum = vec4<f32>(0.0); var weightSum = 0.0;
//   for (var i = -radius; i <= radius; i = i + 1) {
//       let x = f32(i);
//       let weight = exp(-(x * x) / (2.0 * sigma2));
//       let offset = vec2<f32>(f32(i) * texelSize.x, 0.0);
//       sum = sum + textureSample(inputTex, inputSampler, uv + offset) * weight;
//       weightSum = weightSum + weight;
//   }
//   return sum / weightSum;
// -----------------------------------------------------------------------------
float4 nm_blur_gaussian(float2 uv, float2 texelSize, float radiusF, float2 axis)
{
    int radius = (int)radiusF;
    if (radius <= 0)
    {
        return inputTex.Sample(sampler_inputTex, uv);
    }

    // Compute sigma for Gaussian (radius ~= 3*sigma)
    float sigma = (float)radius / 3.0;
    float sigma2 = sigma * sigma;

    float4 sum = float4(0.0, 0.0, 0.0, 0.0);
    float weightSum = 0.0;

    [loop]
    for (int i = -radius; i <= radius; i = i + 1)
    {
        float x = (float)i;
        float weight = exp(-(x * x) / (2.0 * sigma2));
        float2 offset = (float)i * texelSize * axis;
        sum = sum + inputTex.Sample(sampler_inputTex, uv + offset) * weight;
        weightSum = weightSum + weight;
    }

    return sum / weightSum;
}

// ---- Pass: "blurH" (progName "blurH") — horizontal blur using radiusX --------
float4 fragBlurH(NMVaryings i) : SV_Target
{
    // WGSL: texSize = vec2<f32>(textureDimensions(inputTex)); uv = pos.xy / texSize;
    uint w, h;
    inputTex.GetDimensions(w, h);
    float2 texSize = float2((float)w, (float)h);
    float2 uv = NM_FragCoord(i) / texSize;
    float2 texelSize = 1.0 / texSize;

    return nm_blur_gaussian(uv, texelSize, radiusX, float2(1.0, 0.0));
}

// ---- Pass: "blurV" (progName "blurV") — vertical blur using radiusY ----------
float4 fragBlurV(NMVaryings i) : SV_Target
{
    uint w, h;
    inputTex.GetDimensions(w, h);
    float2 texSize = float2((float)w, (float)h);
    float2 uv = NM_FragCoord(i) / texSize;
    float2 texelSize = 1.0 / texSize;

    return nm_blur_gaussian(uv, texelSize, radiusY, float2(0.0, 1.0));
}

#endif // NM_EFFECT_BLUR_INCLUDED
