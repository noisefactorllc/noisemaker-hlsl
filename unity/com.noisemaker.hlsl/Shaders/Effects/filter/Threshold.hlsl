#ifndef NM_THRESHOLD_INCLUDED
#define NM_THRESHOLD_INCLUDED

// =============================================================================
// Threshold.hlsl — filter/threshold, ported PIXEL-IDENTICALLY from the canonical
// WGSL: shaders/effects/filter/threshold/wgsl/thresh.wgsl
//
// Binary threshold with adjustable edge softness. Computes luminance via the
// Rec.601 weights, then smoothsteps across [level - sharpness, level + sharpness]
// and writes the result to all three channels (alpha = 1.0).
//
// WGSL main():
//   let st = position.xy / vec2<f32>(textureDimensions(inputTex, 0));
//   let c  = textureSample(inputTex, samp, st);
//   let l  = dot(c.rgb, vec3<f32>(0.299, 0.587, 0.114));
//   let e  = smoothstep(level - sharpness, level + sharpness, l);
//   return vec4<f32>(vec3<f32>(e), 1.0);
//
// PORTING-GUIDE notes:
//  * Single render pass (definition.js passes[].length == 1, program "thresh").
//  * uv is fragCoord / the INPUT TEXTURE's own dimensions. WGSL divides by
//    textureDimensions(inputTex, 0) (NOT fullResolution). We mirror exactly:
//    NM_FragCoord(i) (top-left, +0.5 centered) divided by the input tex size.
//    The GLSL computes a globalCoord (fragCoord + tileOffset) but does NOT use it
//    for the sample uv — it samples with gl_FragCoord.xy / textureSize. WGSL is
//    canonical, so tileOffset does not enter the sample coordinate. (H8 handled by
//    NMFullscreen's top-left UV; no per-effect flip needed.)
//  * No PRNG / no atan2 / no select / no nm_mod in this effect — no bit hazards.
//  * HLSL `smoothstep(edge0, edge1, x)` matches WGSL `smoothstep(low, high, x)`
//    argument order exactly (edge0 = level - sharpness, edge1 = level + sharpness).
//    Note: if sharpness == 0 the two edges coincide; HLSL smoothstep with edge0 ==
//    edge1 returns a step (0 below, 1 at/above), matching the WGSL/GLSL behavior.
//  * level / sharpness are f32 uniforms (definition.js globals[*].uniform).
//  * Linear, clamp-to-edge, non-sRGB sampler (H7) — set on the SamplerState in
//    Threshold.shader / supplied by the Shader Graph node.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
// Bound by the runtime via MaterialPropertyBlock under these exact names.
float level;       // globals.level.uniform "level",       default 0.5
float sharpness;   // globals.sharpness.uniform "sharpness", default 0.5

// -----------------------------------------------------------------------------
// nm_threshold — core per-pixel evaluation. Takes the already-sampled input color
// and returns the thresholded RGBA. Pure function so the Shader Graph wrapper and
// the render pass share identical math. Ported VERBATIM from thresh.wgsl main().
//   let l = dot(c.rgb, vec3<f32>(0.299, 0.587, 0.114));
//   let e = smoothstep(level - sharpness, level + sharpness, l);
//   return vec4<f32>(vec3<f32>(e), 1.0);
// -----------------------------------------------------------------------------
float4 nm_threshold(float4 c)
{
    float l = dot(c.rgb, float3(0.299, 0.587, 0.114));
    float e = smoothstep(level - sharpness, level + sharpness, l);
    return float4(e, e, e, 1.0);
}

#endif // NM_THRESHOLD_INCLUDED
