#ifndef NM_EFFECT_LENS_INCLUDED
#define NM_EFFECT_LENS_INCLUDED

// =============================================================================
// Lens.hlsl — filter/lens (func: "lens")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/filter/lens/wgsl/lens.wgsl
//
// Barrel or pincushion lens distortion. Warps sample coordinates radially
// around the frame center with optional aspect-correction and 4-tap antialias.
// Single render pass.
//
// PORTING-GUIDE notes / hazards handled:
//  * UV is (pos.xy + tileOffset) / dims, where dims = fullResolution when
//    fullResolution.x > 0, else textureDimensions(inputTex). We use
//    NM_GlobalCoord(i) for (pos.xy + tileOffset) and derive dims accordingly.
//    This matches the WGSL `uv = (pos.xy + tileOffset) / dims` exactly.
//  * WGSL `select(texSize, fullResolution, fullResolution.x > 0.0)` → HLSL
//    `(fullResolution.x > 0.0) ? fullResolution : texSize`.
//  * `isTile = length(tileOffset) > 0.0`. Non-tiling path uses fract() wrap.
//    Tiling path clamps displacement to 256px, then converts warpedGlobalUV
//    back to per-tile tex coords.
//  * aspectLens / antialias are int uniforms; tested `!= 0` (matches WGSL
//    `uniforms.aspectLens != 0`).
//  * WGSL `select(0.5, aspect*0.5, uniforms.aspectLens != 0)` →
//    `(uniforms.aspectLens != 0) ? (aspect * 0.5) : 0.5`.
//  * No PRNG / no PCG / no float-bit hazards in this effect.
//  * Antialias uses ddx/ddy (= dpdx/dpdy in WGSL). Four rotated taps, ×0.25.
//  * Linear, clamp-to-edge (or repeat for tiling), non-sRGB sampler (H7).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (reference binding: sampler@0, inputTex@1) ------
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
float lensDisplacement;  // globals.displacement.uniform, [-1,1] default 0
int   aspectLens;        // globals.aspectLens.uniform,   bool   default 1
int   antialias;         // globals.antialias.uniform,    bool   default 1

// =============================================================================
// nm_lens — core per-pixel evaluation. Mirrors WGSL main() body verbatim.
//
// WGSL @fragment main:
//   let texSize = vec2<f32>(textureDimensions(inputTex));
//   let tileOffset = uniforms.tileOffset;
//   let dims = select(texSize, uniforms.fullResolution, uniforms.fullResolution.x > 0.0);
//   let isTile = length(tileOffset) > 0.0;
//   let uv = (pos.xy + tileOffset) / dims;
//   var zoom = 0.0;
//   if (uniforms.lensDisplacement < 0.0) { zoom = uniforms.lensDisplacement * -0.25; }
//   let aspect = dims.x / dims.y;
//   let dist = uv - HALF_FRAME;        // HALF_FRAME = 0.5
//   var aDist = dist;
//   if (uniforms.aspectLens != 0) { aDist.x = aDist.x * aspect; }
//   let halfAspect = select(0.5, aspect * 0.5, uniforms.aspectLens != 0);
//   let maxDist = length(vec2<f32>(halfAspect, 0.5));
//   let distFromCenter = length(aDist);
//   let normalizedDist = clamp(distFromCenter / maxDist, 0.0, 1.0);
//   let centerWeight = 1.0 - normalizedDist;
//   let centerWeightSq = centerWeight * centerWeight;
//   var displacement = aDist * zoom + aDist * centerWeightSq * uniforms.lensDisplacement;
//   if (uniforms.aspectLens != 0) { displacement.x = displacement.x / aspect; }
//   if (isTile) { ... clamped tiling path ... }
//   let offset = fract(uv - displacement);
//   if (uniforms.antialias != 0) { ... 4-tap AA ... }
//   return textureSample(inputTex, inputSampler, offset);
// =============================================================================
float4 NMFrag_lens(NMVaryings i) : SV_Target
{
    // texSize = vec2<f32>(textureDimensions(inputTex))
    uint tw, th;
    inputTex.GetDimensions(tw, th);
    float2 texSize = float2((float)tw, (float)th);

    // dims = select(texSize, fullResolution, fullResolution.x > 0.0)
    //      = (fullResolution.x > 0.0) ? fullResolution : texSize
    float2 dims = (fullResolution.x > 0.0) ? fullResolution : texSize;

    // isTile = length(tileOffset) > 0.0
    float2 tileOff = tileOffset;  // NMFullscreen #define alias
    bool isTile = length(tileOff) > 0.0;

    // uv = (pos.xy + tileOffset) / dims
    float2 uv = (NM_FragCoord(i) + tileOff) / dims;

    // zoom for negative displacement (pincushion)
    float zoom = 0.0;
    if (lensDisplacement < 0.0)
    {
        zoom = lensDisplacement * -0.25;
    }

    // aspect-corrected distance from center
    float aspect = dims.x / dims.y;
    float2 dist = uv - (float2)0.5;  // HALF_FRAME = 0.5
    float2 aDist = dist;
    if (aspectLens != 0) { aDist.x = aDist.x * aspect; }

    // select(0.5, aspect * 0.5, uniforms.aspectLens != 0)
    // WGSL select(false_val, true_val, cond) → HLSL cond ? true_val : false_val
    float halfAspect = (aspectLens != 0) ? (aspect * 0.5) : 0.5;
    float maxDist = length(float2(halfAspect, 0.5));
    float distFromCenter = length(aDist);
    float normalizedDist = clamp(distFromCenter / maxDist, 0.0, 1.0);

    // center weight: stronger at edges, weaker at center
    float centerWeight = 1.0 - normalizedDist;
    float centerWeightSq = centerWeight * centerWeight;

    // radial displacement in aspect-corrected space
    float2 displacement = aDist * zoom + aDist * centerWeightSq * lensDisplacement;

    // convert displacement back to UV space
    if (aspectLens != 0) { displacement.x = displacement.x / aspect; }

    if (isTile)
    {
        // Limit displacement so sample stays within tile overlap (<=256px)
        float maxDispPixels = 256.0;
        float dispPixels = length(displacement * dims);
        if (dispPixels > maxDispPixels)
        {
            displacement = displacement * (maxDispPixels / dispPixels);
        }
        float2 warpedGlobalUV = uv - displacement;
        float2 offset = (warpedGlobalUV * dims - tileOff) / texSize;

        if (antialias != 0)
        {
            float2 dx = ddx(offset);
            float2 dy = ddy(offset);
            float4 col = (float4)0.0;
            col += inputTex.SampleGrad(sampler_inputTex, offset + dx * -0.375 + dy * -0.125, dx, dy);
            col += inputTex.SampleGrad(sampler_inputTex, offset + dx *  0.125 + dy * -0.375, dx, dy);
            col += inputTex.SampleGrad(sampler_inputTex, offset + dx *  0.375 + dy *  0.125, dx, dy);
            col += inputTex.SampleGrad(sampler_inputTex, offset + dx * -0.125 + dy *  0.375, dx, dy);
            return col * 0.25;
        }
        return inputTex.Sample(sampler_inputTex, offset);
    }

    // Non-tiling path: fract() wrap
    float2 offset = frac(uv - displacement);

    if (antialias != 0)
    {
        float2 dx = ddx(offset);
        float2 dy = ddy(offset);
        float4 col = (float4)0.0;
        col += inputTex.SampleGrad(sampler_inputTex, offset + dx * -0.375 + dy * -0.125, dx, dy);
        col += inputTex.SampleGrad(sampler_inputTex, offset + dx *  0.125 + dy * -0.375, dx, dy);
        col += inputTex.SampleGrad(sampler_inputTex, offset + dx *  0.375 + dy *  0.125, dx, dy);
        col += inputTex.SampleGrad(sampler_inputTex, offset + dx * -0.125 + dy *  0.375, dx, dy);
        return col * 0.25;
    }
    return inputTex.Sample(sampler_inputTex, offset);
}

#endif // NM_EFFECT_LENS_INCLUDED
