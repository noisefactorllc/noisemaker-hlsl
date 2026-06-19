#ifndef NM_STRAYHAIR_INCLUDED
#define NM_STRAYHAIR_INCLUDED

// =============================================================================
// StrayHair.hlsl — filter/strayHair, ported PIXEL-IDENTICALLY from canonical WGSL:
//   shaders/effects/filter/strayHair/wgsl/strayHairBlend.wgsl
//
// Composites a CPU-rendered hair overlay (overlayTex) onto inputTex using
// premultiplied-alpha blending. Single GPU pass ("blend" / program "strayHairBlend").
//
// WGSL main():
//   let coord   = vec2<i32>(i32(pos.x), i32(pos.y));
//   let base    = textureLoad(inputTex, coord, 0);
//   let overlay = textureLoad(overlayTex, coord, 0);
//   let a       = overlay.a * alpha;
//   let result  = base.rgb * (1.0 - a) + overlay.rgb * a;
//   return vec4<f32>(result, base.a);
//
// PORTING-GUIDE notes:
//  * WGSL uses textureLoad (integer pixel coordinates, no sampler). HLSL equivalent:
//    Texture2D.Load(int3(x, y, 0)). NM_FragCoord(i) gives pixel center (+0.5);
//    truncate to int with (int2) to get the pixel index matching i32(pos.x/y).
//  * No per-effect math helpers — only the three named uniforms: density, seed, alpha.
//    density and seed are consumed by the CPU asyncInit (traceWorms); only alpha
//    is used in this GPU blend pass (definition.js passes[0].uniforms).
//  * No PRNG, no atan2, no nm_mod — no numeric hazards in this pass.
//  * overlayTex is a CPU-rendered rgba8 texture (the hair strands canvas).
//    Both textures are loaded at integer coords — no sampler state required for
//    the core logic. We still declare SamplerState objects in the .shader so that
//    the engine property system is satisfied, but Load() is used for actual reads.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
// density and seed drive the CPU asyncInit; only alpha is read in the GPU pass.
float density;  // globals.density.uniform "density", default 0.5
int   seed;     // globals.seed.uniform    "seed",    default 1
float alpha;    // globals.alpha.uniform   "alpha",   default 0.5

// -----------------------------------------------------------------------------
// nm_strayHairBlend — core per-pixel evaluation. Ported VERBATIM from WGSL.
//   base    : pixel fetched from inputTex  at integer coord
//   overlay : pixel fetched from overlayTex at integer coord
//   alpha   : uniform blend weight
// Returns blended RGBA.
// -----------------------------------------------------------------------------
float4 nm_strayHairBlend(float4 base, float4 overlay, float a_uniform)
{
    // WGSL: let a = overlay.a * alpha;
    float a = overlay.a * a_uniform;
    // WGSL: let result = base.rgb * (1.0 - a) + overlay.rgb * a;
    float3 result = base.rgb * (1.0 - a) + overlay.rgb * a;
    // WGSL: return vec4<f32>(result, base.a);
    return float4(result, base.a);
}

#endif // NM_STRAYHAIR_INCLUDED
