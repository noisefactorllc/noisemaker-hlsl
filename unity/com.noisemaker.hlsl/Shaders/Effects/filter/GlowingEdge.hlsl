#ifndef NM_GLOWING_EDGE_INCLUDED
#define NM_GLOWING_EDGE_INCLUDED

// =============================================================================
// GlowingEdge.hlsl — filter/glowingEdge, ported PIXEL-IDENTICALLY from WGSL:
//   shaders/effects/filter/glowingEdge/wgsl/glowingEdge.wgsl
//
// Single-pass Sobel edge detection with screen-blend glow.
//
// PORTING-GUIDE notes:
//  * uv = pos.xy / textureDimensions(inputTex)  — divide by INPUT tex dims, not
//    fullResolution. NM_FragCoord(i) (top-left, +0.5) is the @builtin(position)
//    analog. No per-effect Y flip needed (ported from WGSL).
//  * texel = uniforms.width / texSize — width is a float uniform; texel is the
//    per-axis step in UV space.
//  * sobelMetric is stored as float in WGSL uniforms; cast to int at use site
//    (WGSL: `let metric = i32(uniforms.sobelMetric)`). Declared as int uniform
//    here so the C# runtime can set it directly as an integer.
//  * distance_metric branches on an int — use [branch] to avoid ANGLE stalls.
//  * mix -> lerp; clamp, abs, max, sqrt, dot map 1:1.
//  * No PRNG / PCG / bit-reinterpret hazards.
//  * Linear, clamp-to-edge, non-sRGB sampler (H7).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (reference binding: sampler@0, inputTex@1) ------
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -------------
int   sobelMetric;  // globals.shape.uniform  — 0=Euclidean 1=Manhattan 2=Chebyshev 3=Minkowski
int   width;        // globals.width.uniform  — default 1
float alpha;        // globals.alpha.uniform  — default 1

// -----------------------------------------------------------------------------
// luminance — verbatim from WGSL
//   fn luminance(rgb: vec3<f32>) -> f32 { return dot(rgb, vec3<f32>(0.299, 0.587, 0.114)); }
// -----------------------------------------------------------------------------
float nm_glowingEdge_luminance(float3 rgb)
{
    return dot(rgb, float3(0.299, 0.587, 0.114));
}

// -----------------------------------------------------------------------------
// distance_metric — verbatim from WGSL
//   fn distance_metric(gx, gy, metric) -> f32
//   metric==1 : Manhattan    abs_gx + abs_gy
//   metric==2 : Chebyshev    max(abs_gx, abs_gy)
//   metric==3 : Minkowski    max((abs_gx+abs_gy)/1.414, max(abs_gx,abs_gy))
//   default   : Euclidean    sqrt(gx*gx + gy*gy)
// -----------------------------------------------------------------------------
float nm_glowingEdge_distMetric(float gx, float gy, int metric)
{
    float abs_gx = abs(gx);
    float abs_gy = abs(gy);

    [branch]
    if (metric == 1)
    {
        return abs_gx + abs_gy;
    }
    else if (metric == 2)
    {
        return max(abs_gx, abs_gy);
    }
    else if (metric == 3)
    {
        float cross_val = (abs_gx + abs_gy) / 1.414;
        return max(cross_val, max(abs_gx, abs_gy));
    }
    return sqrt(gx * gx + gy * gy);
}

// =============================================================================
// NMFrag_glowingEdge — single pass (progName "glowingEdge")
//
// WGSL main() ported verbatim:
//   texSize = vec2<f32>(textureDimensions(inputTex))
//   uv      = pos.xy / texSize
//   texel   = uniforms.width / texSize      // per-axis UV step
//   base    = textureSampleLevel(inputTex, inputSampler, uv, 0.0)
//   [3x3 Sobel neighborhood, textureSampleLevel at uv ± texel offsets]
//   gx = -tl - 2*ml - bl + tr + 2*mr + br
//   gy = -tl - 2*tc - tr + bl + 2*bc + br
//   edge   = clamp(distance_metric(gx,gy,metric)*3.0, 0, 1)
//   glow   = edge * base.rgb * 2.0
//   result = 1 - (1-base.rgb)*(1-glow)      // screen blend
//   mixed  = mix(base.rgb, result, alpha)
//   return vec4(clamp(mixed, 0, 1), base.a)
// =============================================================================
float4 NMFrag_glowingEdge(NMVaryings i) : SV_Target
{
    uint tw, th;
    inputTex.GetDimensions(tw, th);
    float2 texSize = float2((float)tw, (float)th);
    float2 uv = NM_FragCoord(i) / texSize;

    // WGSL: let texel = uniforms.width / texSize;
    float2 texel = (float)width / texSize;

    // Sample base color (textureSampleLevel with mip 0)
    float4 base = inputTex.SampleLevel(sampler_inputTex, uv, 0.0);

    // 3x3 neighborhood luminances (textureSampleLevel, mip 0)
    float tl = nm_glowingEdge_luminance(inputTex.SampleLevel(sampler_inputTex, uv + float2(-texel.x, -texel.y), 0.0).rgb);
    float tc = nm_glowingEdge_luminance(inputTex.SampleLevel(sampler_inputTex, uv + float2( 0.0,     -texel.y), 0.0).rgb);
    float tr = nm_glowingEdge_luminance(inputTex.SampleLevel(sampler_inputTex, uv + float2( texel.x, -texel.y), 0.0).rgb);
    float ml = nm_glowingEdge_luminance(inputTex.SampleLevel(sampler_inputTex, uv + float2(-texel.x,  0.0    ), 0.0).rgb);
    float mr = nm_glowingEdge_luminance(inputTex.SampleLevel(sampler_inputTex, uv + float2( texel.x,  0.0    ), 0.0).rgb);
    float bl = nm_glowingEdge_luminance(inputTex.SampleLevel(sampler_inputTex, uv + float2(-texel.x,  texel.y), 0.0).rgb);
    float bc = nm_glowingEdge_luminance(inputTex.SampleLevel(sampler_inputTex, uv + float2( 0.0,      texel.y), 0.0).rgb);
    float br = nm_glowingEdge_luminance(inputTex.SampleLevel(sampler_inputTex, uv + float2( texel.x,  texel.y), 0.0).rgb);

    // Sobel kernels
    float gx = -tl - 2.0 * ml - bl + tr + 2.0 * mr + br;
    float gy = -tl - 2.0 * tc - tr + bl + 2.0 * bc + br;

    // Edge magnitude
    float edge = clamp(nm_glowingEdge_distMetric(gx, gy, sobelMetric) * 3.0, 0.0, 1.0);

    // Glow: edges emit base color as additive light
    float3 glow = edge * base.rgb * 2.0;

    // Screen blend glow onto original
    float3 result = float3(1.0, 1.0, 1.0) - (float3(1.0, 1.0, 1.0) - base.rgb) * (float3(1.0, 1.0, 1.0) - glow);

    // Mix based on alpha
    float3 mixed = lerp(base.rgb, result, alpha);

    return float4(clamp(mixed, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0)), base.a);
}

#endif // NM_GLOWING_EDGE_INCLUDED
