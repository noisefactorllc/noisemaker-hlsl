#ifndef NM_CHANNELCOMBINE_INCLUDED
#define NM_CHANNELCOMBINE_INCLUDED

// =============================================================================
// ChannelCombine.hlsl — mixer/channelCombine, ported PIXEL-IDENTICALLY from:
//   shaders/effects/mixer/channelCombine/wgsl/channelCombine.wgsl
//
// Samples three surfaces (rTex, gTex, bTex), converts each to luminance, scales
// by rLevel/gLevel/bLevel (0..100 range, divided by 100), and outputs an RGB
// triple with alpha 1.0. Single render pass.
//
// PORTING NOTES:
//  * luminance() is this effect's OWN helper — ported VERBATIM inline.
//  * WGSL uses a single `resolution` uniform: st = position.xy / resolution.
//    All three textures are sampled at the same `st`.  The GLSL divides each by
//    its own textureSize, but the canonical WGSL does not — we follow the WGSL.
//  * Three named float uniforms: rLevel, gLevel, bLevel (default 100 each).
//  * No PRNG / nm_mod / select / atan2 in this effect — no bit hazards.
//  * Linear, clamp-to-edge, non-sRGB samplers (H7).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
float rLevel;   // globals.rLevel.uniform "rLevel", default 100, range 0..100
float gLevel;   // globals.gLevel.uniform "gLevel", default 100, range 0..100
float bLevel;   // globals.bLevel.uniform "bLevel", default 100, range 0..100

// -----------------------------------------------------------------------------
// luminance — ported VERBATIM from channelCombine.wgsl.
// WGSL: return dot(c.rgb, vec3<f32>(0.2126, 0.7152, 0.0722));
// -----------------------------------------------------------------------------
float luminance(float4 c)
{
    return dot(c.rgb, float3(0.2126, 0.7152, 0.0722));
}

// -----------------------------------------------------------------------------
// nm_channelCombine — core per-pixel evaluation. Takes three already-sampled
// input colors and returns the combined RGBA. Pure function shared by the render
// pass and the Shader Graph wrapper.
// Ported VERBATIM from channelCombine.wgsl main() lines 18-22.
// -----------------------------------------------------------------------------
float4 nm_channelCombine(float4 rSample, float4 gSample, float4 bSample)
{
    float r = luminance(rSample) * rLevel / 100.0;
    float g = luminance(gSample) * gLevel / 100.0;
    float b = luminance(bSample) * bLevel / 100.0;
    return float4(r, g, b, 1.0);
}

#endif // NM_CHANNELCOMBINE_INCLUDED
