#ifndef NM_FIBERS_INCLUDED
#define NM_FIBERS_INCLUDED

// =============================================================================
// Fibers.hlsl — filter/fibers "blend" pass, ported PIXEL-IDENTICALLY from the
//   canonical WGSL: shaders/effects/filter/fibers/wgsl/fibersBlend.wgsl
//
// The fibers effect is two-stage:
//   1. CPU (asyncInit): worm-tracer renders colored fibers onto an offscreen
//      canvas and uploads the result to overlayTex.
//   2. GPU (fibersBlend pass, this file): alpha-composite overlay over inputTex.
//
// WGSL fibersBlend main():
//   let coord  = vec2<i32>(i32(pos.x), i32(pos.y));
//   let base   = textureLoad(inputTex,   coord, 0);
//   let overlay= textureLoad(overlayTex, coord, 0);
//   let a      = overlay.a * alpha;
//   let result = base.rgb * (1.0 - a) + overlay.rgb * a;
//   return vec4<f32>(result, base.a);
//
// KEY PORTING NOTE: the WGSL (and GLSL) uses textureLoad / texelFetch — integer
// pixel-coord access, NOT UV sampling. There is no sampler here; we use the HLSL
// equivalent Texture2D.Load(int3(coord, 0)) which is an exact bit-for-bit match.
// No division by texture dimensions; no bilinear interpolation.
//
// UNIFORMS (definition.js globals):
//   alpha   float  0.5   [0..1]   overlay mix weight
//
// (density and seed are CPU-side only — they drive asyncInit, not the GPU pass.
//  The GPU pass only needs alpha.)
//
// PORTING-GUIDE notes:
//  * nm_mod, NMCore PCG/prng not used — pure compositing, no PRNG needed.
//  * Full 32-bit float (H4). No half/min16float.
//  * textureLoad → Texture2D.Load: bit-exact, no filtering.
//  * WGSL coord truncates pos.x/pos.y to i32 — same as (int)NM_FragCoord(i).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// Per-effect uniform (definition.js globals.alpha.uniform = "alpha")
float alpha;   // default 0.5; range [0,1]

// -----------------------------------------------------------------------------
// nm_fibers_blend — core alpha-composite. base = inputTex pixel, over = overlay.
// Verbatim WGSL arithmetic: a = over.a * alpha; result = base*(1-a) + over*a.
// base.a is preserved as output alpha (WGSL: return vec4<f32>(result, base.a)).
// -----------------------------------------------------------------------------
float4 nm_fibers_blend(float4 base, float4 over)
{
    float a = over.a * alpha;
    float3 result = base.rgb * (1.0 - a) + over.rgb * a;
    return float4(result, base.a);
}

#endif // NM_FIBERS_INCLUDED
