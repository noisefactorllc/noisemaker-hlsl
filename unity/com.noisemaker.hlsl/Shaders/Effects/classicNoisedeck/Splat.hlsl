#ifndef NM_SPLAT_INCLUDED
#define NM_SPLAT_INCLUDED

// =============================================================================
// Splat.hlsl — classicNoisedeck/splat, ported PIXEL-IDENTICALLY from the
// canonical WGSL:  shaders/effects/classicNoisedeck/splat/wgsl/splat.wgsl
//
// Splatter paint compositor overlay. Builds deterministic multi-octave splat
// and speck masks from PCG-backed Perlin noise and composites them over the
// input surface in one of four modes (color / displace / invert / negative).
//
// KIND: single-input FILTER (definition.js inputs sample only "inputTex").
// PASSES: 1 (passes[0] name "render", program "splat").
//
// PORTING-GUIDE notes:
//  * Ported from WGSL (canonical, top-left/D3D — no per-effect Y flip).
//  * mapRange / smootherstep / smoothlerp / grid / perlin / splat / speckle are
//    this effect's OWN copies — ported VERBATIM inline (golden rule 2). Even
//    `mapRange` matches NMCore's nm_map exactly, but is copied per the verbatim
//    rule; the math is identical either way.
//  * pcg / prng come from NMCore (the only shared primitives). The WGSL prng's
//    sign-fold and `/ f32(0xffffffffu)` (= 4294967295.0) match nm_prng exactly,
//    and `u32(p.x)` truncation matches nm_pcg's `(uint3)p` truncation.
//  * COORD/SAMPLING parity (the #1 hazard): the WGSL divides BOTH the sample uv
//    AND the aspectRatio by the INPUT TEXTURE's own dimensions, NOT fullResolution:
//      let dims = vec2<f32>(textureDimensions(inputTex, 0));
//      let aspectRatio = dims.x / dims.y;
//      var uv = fragCoord.xy / dims;
//    We mirror this literally with inputTex.GetDimensions + NM_FragCoord. (The
//    GLSL uses fullResolution for aspectRatio but textureSize for sampling; per
//    golden rule 1 we follow the WGSL, which uses inputTex dims for both.)
//  * mode 1 (displace) samples inputTex at `uv + mask*0.1` DIRECTLY (no
//    fullResolution roundtrip) — WGSL lines 128 & 142. Followed literally.
//  * Compile-time #defines: none. enabled/useSpecks are runtime bool-as-int
//    uniforms; we branch with [branch], matching the WGSL `!= 0` tests.
//  * The GLSL `shape()` helper is dead code (unused, absent from WGSL) — omitted.
//  * Seeds (seed/speckSeed) and speeds (speed/speckSpeed) are FLOAT in the WGSL
//    Uniforms struct; they are added to vec2 coords / scaled — declared float here.
//  * Linear, clamp-to-edge, non-sRGB sampler (H7) — set in Splat.shader.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
// Bound by the runtime via MaterialPropertyBlock under these exact names.
// WGSL Uniforms struct types preserved (seeds/speeds are f32; modes are i32).
int    enabled;      // bool-as-int; WGSL: u.enabled != 0       default 1 (true)
int    mode;         // 0 color,1 displace,2 invert,3 negative  default 2
float  scale;        // 1..5                                    default 3
float  seed;         // 1..100                                  default 1
float3 color;        // splat color (RGB, linear)               default (1,1,1)
float  cutoff;       // 0..100                                  default 25
float  speed;        // 0..5                                    default 1
int    useSpecks;    // bool-as-int; WGSL: u.useSpecks != 0     default 1 (true)
int    speckMode;    // 0 color,1 displace,2 invert,3 negative  default 0
float  speckScale;   // 1..5                                    default 5
float  speckSeed;    // 1..100                                  default 1
float3 speckColor;   // speck color (RGB, linear)               default (.8,.8,.8)
float  speckCutoff;  // 0..100                                  default 70
float  speckSpeed;   // 0..5                                    default 1

#define NM_SPLAT_PI  3.14159265359
#define NM_SPLAT_TAU 6.28318530718

// -----------------------------------------------------------------------------
// mapRange — ported VERBATIM from splat.wgsl (mapRange). Per-effect copy.
//   return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
// -----------------------------------------------------------------------------
float nm_splat_mapRange(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

// -----------------------------------------------------------------------------
// smootherstep — ported VERBATIM from splat.wgsl.
//   return x * x * x * (x * (x * 6.0 - 15.0) + 10.0);
// -----------------------------------------------------------------------------
float nm_splat_smootherstep(float x)
{
    return x * x * x * (x * (x * 6.0 - 15.0) + 10.0);
}

// -----------------------------------------------------------------------------
// smoothlerp — ported VERBATIM from splat.wgsl.
//   return a + smootherstep(x) * (b - a);
// -----------------------------------------------------------------------------
float nm_splat_smoothlerp(float x, float a, float b)
{
    return a + nm_splat_smootherstep(x) * (b - a);
}

// -----------------------------------------------------------------------------
// grid — ported VERBATIM from splat.wgsl. Uses nm_prng (shared PCG primitive).
//   var angle = prng(vec3<f32>(cell, 1.0)).r * TAU;
//   angle = angle + u.time * TAU * speed;
//   let gradient = vec2<f32>(cos(angle), sin(angle));
//   let dist = st - cell;
//   return dot(gradient, dist);
// (.r == .x for the prng's vec3 result.)
// -----------------------------------------------------------------------------
float nm_splat_grid(float2 st, float2 cell, float speed)
{
    float angle = nm_prng(float3(cell, 1.0)).x * NM_SPLAT_TAU;
    angle = angle + time * NM_SPLAT_TAU * speed;
    float2 gradient = float2(cos(angle), sin(angle));
    float2 dist = st - cell;
    return dot(gradient, dist);
}

// -----------------------------------------------------------------------------
// perlin — ported VERBATIM from splat.wgsl.
//   var st = st_in - 0.5; st = st * scale; st = st + 0.5;
//   let cell = floor(st);
//   tl/tr/bl/br via grid(); smoothlerp the two axes; return val*0.5+0.5.
// -----------------------------------------------------------------------------
float nm_splat_perlin(float2 st_in, float2 scale, float speed)
{
    float2 st = st_in - 0.5;
    st = st * scale;
    st = st + 0.5;
    float2 cell = floor(st);
    float tl = nm_splat_grid(st, cell, speed);
    float tr = nm_splat_grid(st, float2(cell.x + 1.0, cell.y), speed);
    float bl = nm_splat_grid(st, float2(cell.x, cell.y + 1.0), speed);
    float br = nm_splat_grid(st, cell + 1.0, speed);
    float upper = nm_splat_smoothlerp(st.x - cell.x, tl, tr);
    float lower = nm_splat_smoothlerp(st.x - cell.x, bl, br);
    float val = nm_splat_smoothlerp(st.y - cell.y, upper, lower);
    return val * 0.5 + 0.5;
}

// -----------------------------------------------------------------------------
// splat — ported VERBATIM from splat.wgsl.
//   st.x = st.x + perlin(st + u.seed + 50.0, vec2(2,3), 0.0) * 0.5 - 0.5;
//   st.y = st.y + perlin(st + u.seed + 60.0, vec2(2,3), 0.0) * 0.5 - 0.5;
//   d = perlin(st, vec2(4)*scale, u.speed)
//     + perlin(st+10, vec2(8)*scale, u.speed)*0.5
//     + perlin(st+20, vec2(16)*scale, u.speed)*0.25;
//   return step(mapRange(u.cutoff, 0,100, 0.85,0.99), d);
// NOTE: `st + u.seed + 50.0` adds a scalar to a float2 (componentwise). Operator
// precedence: `* 0.5 - 0.5` applies after the perlin call (perlin(...)*0.5 - 0.5).
// -----------------------------------------------------------------------------
float nm_splat_splat(float2 st_in, float2 scaleArg)
{
    float2 st = st_in;
    st.x = st.x + nm_splat_perlin(st + seed + 50.0, float2(2.0, 3.0), 0.0) * 0.5 - 0.5;
    st.y = st.y + nm_splat_perlin(st + seed + 60.0, float2(2.0, 3.0), 0.0) * 0.5 - 0.5;
    float d = nm_splat_perlin(st, float2(4.0, 4.0) * scaleArg, speed) +
              (nm_splat_perlin(st + 10.0, float2(8.0, 8.0) * scaleArg, speed) * 0.5) +
              (nm_splat_perlin(st + 20.0, float2(16.0, 16.0) * scaleArg, speed) * 0.25);
    return step(nm_splat_mapRange(cutoff, 0.0, 100.0, 0.85, 0.99), d);
}

// -----------------------------------------------------------------------------
// speckle — ported VERBATIM from splat.wgsl.
//   var d = perlin(st, scale, u.speckSpeed) + perlin(st+10, scale*2, u.speckSpeed)*0.5;
//   d = d / 1.5;
//   return step(mapRange(u.speckCutoff, 0,100, 0.6,0.7), d);
// -----------------------------------------------------------------------------
float nm_splat_speckle(float2 st, float2 scaleArg)
{
    float d = nm_splat_perlin(st, scaleArg, speckSpeed) + (nm_splat_perlin(st + 10.0, scaleArg * 2.0, speckSpeed) * 0.5);
    d = d / 1.5;
    return step(nm_splat_mapRange(speckCutoff, 0.0, 100.0, 0.6, 0.7), d);
}

#endif // NM_SPLAT_INCLUDED
