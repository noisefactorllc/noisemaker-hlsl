#ifndef NM_COLOR_REPLACE_INCLUDED
#define NM_COLOR_REPLACE_INCLUDED

// =============================================================================
// ColorReplace.hlsl — filter/colorReplace, ported PIXEL-IDENTICALLY from the
//   canonical WGSL: shaders/effects/filter/colorReplace/wgsl/colorReplace.wgsl
//
// Color replacement with alpha output. Matches pixels near targetColor by
// euclidean RGB distance and remaps their RGB and/or alpha.
//
// WGSL main():
//   let size = max(textureDimensions(inputTex, 0), vec2<u32>(1u, 1u));
//   let st = position.xy / vec2<f32>(size);
//   let src = textureSampleLevel(inputTex, samp, st, 0.0);
//   let dist = length(src.rgb - targetColor) / 1.7320508;
//   let halfBand = smoothing * 0.5;
//   let edge0 = max(sensitivity - halfBand, 0.0);
//   let edge1 = sensitivity + halfBand;
//   let match_ = 1.0 - smoothstep(edge0, edge1, dist);
//   let outRgb = mix(src.rgb, replaceColor, vec3<f32>(match_ * colorMix));
//   let outA = src.a * mix(keepAlpha, replaceAlpha, match_);
//   return vec4<f32>(outRgb, outA);
//
// PORTING-GUIDE notes:
//  * Single render pass (definition.js passes[0].program "colorReplace").
//  * uv = NM_FragCoord(i) / inputTex dimensions (WGSL divides by
//    textureDimensions(inputTex, 0) clamped to min (1,1) — NOT fullResolution).
//  * No per-effect helpers to port (only stdlib: length, smoothstep, mix).
//    1.7320508 = sqrt(3): normalizes euclidean RGB distance to [0,1].
//  * No PRNG / no atan2 / no select — no bit hazards.
//  * targetColor / replaceColor are vec3 uniforms (RGB); all others are float.
//  * Linear, clamp-to-edge, non-sRGB sampler (H7).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
float3 targetColor;   // default (0,0,0)
float3 replaceColor;  // default (1,1,1)
float  sensitivity;   // default 0.3
float  smoothing;     // default 0.1
float  colorMix;      // default 1.0
float  replaceAlpha;  // default 1.0
float  keepAlpha;     // default 1.0

// -----------------------------------------------------------------------------
// nm_colorReplace — core per-pixel evaluation.
// Ported VERBATIM from colorReplace.wgsl main() (sans texture sample, which
// lives in the .shader pass / SG wrapper to allow sharing the core fn).
// -----------------------------------------------------------------------------
float4 nm_colorReplace(float4 src)
{
    // Normalized euclidean RGB distance: sqrt(3) ≈ 1.7320508 (max possible).
    float dist = length(src.rgb - targetColor) / 1.7320508;

    float halfBand = smoothing * 0.5;
    float edge0 = max(sensitivity - halfBand, 0.0);
    float edge1 = sensitivity + halfBand;
    float match_ = 1.0 - smoothstep(edge0, edge1, dist);

    // WGSL: mix(src.rgb, replaceColor, vec3<f32>(match_ * colorMix))
    float3 outRgb = lerp(src.rgb, replaceColor, float3(match_ * colorMix, match_ * colorMix, match_ * colorMix));
    // WGSL: src.a * mix(keepAlpha, replaceAlpha, match_)
    float outA = src.a * lerp(keepAlpha, replaceAlpha, match_);

    return float4(outRgb, outA);
}

#endif // NM_COLOR_REPLACE_INCLUDED
