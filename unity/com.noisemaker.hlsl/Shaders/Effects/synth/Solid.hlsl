#ifndef NM_EFFECT_SOLID_INCLUDED
#define NM_EFFECT_SOLID_INCLUDED

// =============================================================================
// Solid.hlsl — synth/solid (func: "solid")
//
// Ported VERBATIM from shaders/effects/synth/solid/wgsl/solid.wgsl:
//
//   @group(0) @binding(0) var<uniform> color: vec3<f32>;
//   @group(0) @binding(1) var<uniform> alpha: f32;
//   @fragment
//   fn main(@builtin(position) position: vec4<f32>) -> @location(0) vec4<f32> {
//     // Premultiply RGB by alpha for correct compositing
//     return vec4<f32>(color * alpha, alpha);
//   }
//
// Produces a constant color with premultiplied alpha. No coordinate, sampler,
// or PRNG math — `position` is unused, so no st / fullResolution.y divide here.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
// color: vec3 (globals.color, default [0.5,0.5,0.5])
// alpha: float (globals.alpha, default 1.0)
float3 color;
float  alpha;

// Core function: premultiply RGB by alpha for correct compositing.
// Verbatim from WGSL: vec4<f32>(color * alpha, alpha).
float4 nm_solid(float3 inColor, float inAlpha)
{
    // Premultiply RGB by alpha for correct compositing
    return float4(inColor * inAlpha, inAlpha);
}

// ---- Pass: "solid" (progName "solid") ---------------------------------------
float4 NMFrag_solid(NMVaryings i) : SV_Target
{
    // position.xy is unused by the WGSL body; coords intentionally not computed.
    return nm_solid(color, alpha);
}

#endif // NM_EFFECT_SOLID_INCLUDED
