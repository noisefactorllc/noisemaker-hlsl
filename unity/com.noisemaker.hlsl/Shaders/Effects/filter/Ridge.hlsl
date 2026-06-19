#ifndef NM_RIDGE_INCLUDED
#define NM_RIDGE_INCLUDED

// =============================================================================
// Ridge.hlsl — filter/ridge, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/ridge/wgsl/ridge.wgsl
//
// Ridge/crease enhancement with configurable midpoint level.
//
// WGSL ridge_transform(value, lvl):
//   let denom  = max(lvl, 1.0 - lvl);
//   let result = vec4<f32>(1.0) - abs(value - vec4<f32>(lvl)) / denom;
//   return clamp(result, vec4<f32>(0.0), vec4<f32>(1.0));
//
// WGSL main():
//   uv = fragCoord.xy / vec2(textureDimensions(inputTex))
//   texel = textureLoad (WGSL compute) / textureSample (GLSL analog)
//   ridged = ridge_transform(texel, level)
//   out_color = vec4(ridged.xyz, 1.0)
//
// PORTING-GUIDE notes:
//  * Single filter pass, one uniform: level (float, default 0.5).
//  * uv is fragCoord / the INPUT TEXTURE's own dimensions (GLSL uses
//    gl_FragCoord.xy / textureSize(inputTex, 0)) — not fullResolution.
//  * Alpha is forced to 1.0, matching the WGSL `out_color = vec4(ridged.xyz, 1.0)`.
//  * No PRNG, no rotation helpers, no per-effect math beyond ridge_transform.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// Per-effect uniform (definition.js globals.level)
float level;

// -----------------------------------------------------------------------------
// nm_ridge_transform — verbatim from WGSL ridge_transform().
// -----------------------------------------------------------------------------
float4 nm_ridge_transform(float4 value, float lvl)
{
    // WGSL: let denom = max(lvl, 1.0 - lvl);
    float denom = max(lvl, 1.0 - lvl);
    // WGSL: vec4<f32>(1.0) - abs(value - vec4<f32>(lvl)) / denom
    float4 result = float4(1.0, 1.0, 1.0, 1.0) - abs(value - float4(lvl, lvl, lvl, lvl)) / denom;
    return clamp(result, float4(0.0, 0.0, 0.0, 0.0), float4(1.0, 1.0, 1.0, 1.0));
}

// -----------------------------------------------------------------------------
// nm_ridge — entry used by both the render pass and the Shader Graph wrapper.
// texel: already-sampled input color. Returns ridged RGBA with alpha forced 1.0.
// -----------------------------------------------------------------------------
float4 nm_ridge(float4 texel, float lvl)
{
    float4 ridged = nm_ridge_transform(texel, lvl);
    // WGSL: out_color = vec4(ridged.xyz, 1.0)
    return float4(ridged.xyz, 1.0);
}

#endif // NM_RIDGE_INCLUDED
