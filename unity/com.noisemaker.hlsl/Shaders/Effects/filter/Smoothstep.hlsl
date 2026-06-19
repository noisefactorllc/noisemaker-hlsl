#ifndef NM_SMOOTHSTEP_INCLUDED
#define NM_SMOOTHSTEP_INCLUDED

// =============================================================================
// Smoothstep.hlsl — filter/smoothstep, ported PIXEL-IDENTICALLY from the
//   canonical WGSL: shaders/effects/filter/smoothstep/wgsl/smoothstep.wgsl
//
// WGSL main():
//   let texSize = vec2<f32>(textureDimensions(inputTex));
//   let uv = pos.xy / texSize;
//   var color = textureSampleLevel(inputTex, inputSampler, uv, 0.0);
//   color = vec4<f32>(smoothstep(vec3<f32>(edge0), vec3<f32>(edge1), color.rgb), color.a);
//   return color;
//
// PORTING-GUIDE notes:
//  * Two named uniforms from definition.js globals: edge0 (float, default 0.0),
//    edge1 (float, default 1.0). Declared as bare globals below.
//  * uv = fragCoord / the INPUT TEXTURE's own dimensions (WGSL divides by
//    textureDimensions(inputTex), NOT fullResolution). NM_FragCoord(i) / texSize.
//  * smoothstep is a built-in in both WGSL and HLSL; argument order is identical
//    (edge0, edge1, x). WGSL splats scalars to vec3 — HLSL smoothstep is
//    overloaded for float3, so smoothstep(float3(edge0), float3(edge1), color.rgb)
//    is the exact translation.
//  * No helpers beyond NMFullscreen; no PRNG, no math hazards.
//  * Full 32-bit float; no half/min16float. Linear, clamp-to-edge, non-sRGB.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// Per-effect uniforms (definition.js globals)
float edge0;   // default 0.0, range [0,1]
float edge1;   // default 1.0, range [0,1]

// -----------------------------------------------------------------------------
// nm_smoothstep — core per-pixel evaluation.
// color: already-sampled RGBA from inputTex.
// Returns smoothstepped RGB with alpha passed through.
// -----------------------------------------------------------------------------
float4 nm_smoothstep(float4 color)
{
    // WGSL: vec4<f32>(smoothstep(vec3<f32>(edge0), vec3<f32>(edge1), color.rgb), color.a)
    return float4(smoothstep(float3(edge0, edge0, edge0), float3(edge1, edge1, edge1), color.rgb), color.a);
}

#endif // NM_SMOOTHSTEP_INCLUDED
