#ifndef NM_EFFECT_WARP_INCLUDED
#define NM_EFFECT_WARP_INCLUDED

// =============================================================================
// Warp.hlsl — filter/warp (func: "warp")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/filter/warp/wgsl/warp.wgsl
//
// Perlin noise-based warp distortion. Samples a per-axis gradient-noise offset
// (dx, dy) from an aspect-corrected coordinate, displaces UV by it, applies a
// wrap mode (mirror/repeat/clamp), then samples the input — optionally with a
// 4-tap derivative-jittered antialias. Single render pass.
//
// PORTING-GUIDE notes / hazards handled:
//  * Sample/displace UV uses `uv = pos.xy / textureDimensions(inputTex)` in the
//    WGSL — fragCoord divided by the INPUT TEXTURE's own dimensions, NOT
//    fullResolution. WGSL is canonical, so we mirror it: NM_FragCoord(i)/texSize.
//    `aspectRatio` here is ALSO derived from the input texture (texSize.x/.y),
//    not the engine fullResolution alias (the WGSL computes it from texSize).
//  * pcg/prng are the shared bit-exact primitives from NMCore (nm_pcg/nm_prng);
//    their bodies match this effect's pcg/prng verbatim.
//  * `select(-p.x*2+1, p.x*2, p.x>=0)` -> the WGSL true value is the 2nd arg, so
//    `p.x>=0 ? p.x*2 : -p.x*2+1` (handled inside nm_prng — identical here).
//  * `mod` (WGSL `%` on floats) -> nm_mod (NEVER fmod, H6): mirror/repeat use it.
//  * dpdx/dpdy -> ddx/ddy (screen-space derivatives in the fragment stage).
//  * `f32(seed)` / `f32(speed)` are numeric int->float conversions -> (float).
//  * Linear, clamp-to-edge, non-sRGB sampler (H7) — set on the SamplerState in
//    Warp.shader / supplied by the Shader Graph node.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (reference binding: sampler@0, inputTex@1) ------
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
// Bound by the runtime via MaterialPropertyBlock by these exact names.
float strength;   // globals.strength.uniform  [0,100]  default 75
float scale;      // globals.scale.uniform      [0,5]   default 1
int   seed;       // globals.seed.uniform       [1,100] default 1
int   speed;      // globals.speed.uniform      [0,5]   default 0
int   wrap;       // globals.wrap.uniform   0=mirror 1=repeat 2=clamp  default 0
int   antialias;  // globals.antialias.uniform  bool    default 1 (true)

#define WARP_TAU 6.28318530718

// -----------------------------------------------------------------------------
// smootherstep(x) = x*x*x*(x*(x*6-15)+10)   — verbatim from WGSL.
// -----------------------------------------------------------------------------
float nm_warp_smootherstep(float x)
{
    return x * x * x * (x * (x * 6.0 - 15.0) + 10.0);
}

// smoothlerp(x,a,b) = a + smootherstep(x)*(b-a)   — verbatim from WGSL.
float nm_warp_smoothlerp(float x, float a, float b)
{
    return a + nm_warp_smootherstep(x) * (b - a);
}

// -----------------------------------------------------------------------------
// grid(st, cell, t) — verbatim from WGSL grid(st, cell, t):
//   angle = prng(vec3(cell, 1.0)).r * TAU;
//   angle += t * TAU * f32(uniforms.speed);
//   gradient = vec2(cos(angle), sin(angle));
//   dist = st - cell;
//   return dot(gradient, dist);
// (prng -> nm_prng; .r is the .x component of the returned float3.)
// -----------------------------------------------------------------------------
float nm_warp_grid(float2 st, float2 cell, float t)
{
    float angle = nm_prng(float3(cell, 1.0)).r * WARP_TAU;
    angle = angle + t * WARP_TAU * (float)speed;
    float2 gradient = float2(cos(angle), sin(angle));
    float2 dist = st - cell;
    return dot(gradient, dist);
}

// -----------------------------------------------------------------------------
// perlinNoise(st, noiseScale, t) — verbatim from WGSL perlinNoise():
//   st *= noiseScale;
//   cell = floor(st);
//   tl = grid(st, cell, t);
//   tr = grid(st, vec2(cell.x+1, cell.y), t);
//   bl = grid(st, vec2(cell.x, cell.y+1), t);
//   br = grid(st, cell+1, t);
//   upper = smoothlerp(st.x-cell.x, tl, tr);
//   lower = smoothlerp(st.x-cell.x, bl, br);
//   val   = smoothlerp(st.y-cell.y, upper, lower);
//   return val*0.5 + 0.5;
// -----------------------------------------------------------------------------
float nm_warp_perlinNoise(float2 st_in, float2 noiseScale, float t)
{
    float2 st = st_in * noiseScale;
    float2 cell = floor(st);
    float tl = nm_warp_grid(st, cell, t);
    float tr = nm_warp_grid(st, float2(cell.x + 1.0, cell.y), t);
    float bl = nm_warp_grid(st, float2(cell.x, cell.y + 1.0), t);
    float br = nm_warp_grid(st, cell + 1.0, t);
    float upper = nm_warp_smoothlerp(st.x - cell.x, tl, tr);
    float lower = nm_warp_smoothlerp(st.x - cell.x, bl, br);
    float val = nm_warp_smoothlerp(st.y - cell.y, upper, lower);
    return val * 0.5 + 0.5;
}

// ---- Pass: "warp" (progName "warp") -----------------------------------------
float4 NMFrag_warp(NMVaryings i) : SV_Target
{
    // WGSL: texSize = vec2<f32>(textureDimensions(inputTex));
    //       aspectRatio = texSize.x / texSize.y;
    //       uv = pos.xy / texSize;   (pos = @builtin(position), top-left)
    uint w, h;
    inputTex.GetDimensions(w, h);
    float2 texSize = float2((float)w, (float)h);
    float aspectRatioLocal = texSize.x / texSize.y;
    float2 uv = NM_FragCoord(i) / texSize;

    float t = time;

    // Perlin warp — sample both axes before applying either.
    float2 noiseCoord = uv * float2(aspectRatioLocal, 1.0);
    float2 noiseScale = float2(abs(scale * 3.0), abs(scale * 3.0));
    float dx = (nm_warp_perlinNoise(noiseCoord + (float)seed, noiseScale, t) - 0.5) * strength * 0.01;
    float dy = (nm_warp_perlinNoise(noiseCoord + (float)seed + 10.0, noiseScale, t) - 0.5) * strength * 0.01;
    uv.x = uv.x + dx;
    uv.y = uv.y + dy;

    // Apply wrap mode.
    if (wrap == 0)
    {
        // mirror: abs(((uv + 1.0) % 2.0 + 2.0) % 2.0 - 1.0)
        uv = abs(nm_mod(nm_mod(uv + 1.0, float2(2.0, 2.0)) + 2.0, float2(2.0, 2.0)) - 1.0);
    }
    else if (wrap == 1)
    {
        // repeat: (uv % 1.0 + 1.0) % 1.0
        uv = nm_mod(nm_mod(uv, float2(1.0, 1.0)) + 1.0, float2(1.0, 1.0));
    }
    else
    {
        // clamp
        uv = clamp(uv, float2(0.0, 0.0), float2(1.0, 1.0));
    }

    if (antialias != 0)
    {
        float2 ddxUv = ddx(uv);
        float2 ddyUv = ddy(uv);
        float4 col = float4(0.0, 0.0, 0.0, 0.0);
        col += inputTex.Sample(sampler_inputTex, uv + ddxUv * -0.375 + ddyUv * -0.125);
        col += inputTex.Sample(sampler_inputTex, uv + ddxUv *  0.125 + ddyUv * -0.375);
        col += inputTex.Sample(sampler_inputTex, uv + ddxUv *  0.375 + ddyUv *  0.125);
        col += inputTex.Sample(sampler_inputTex, uv + ddxUv * -0.125 + ddyUv *  0.375);
        return col * 0.25;
    }
    else
    {
        return inputTex.Sample(sampler_inputTex, uv);
    }
}

#endif // NM_EFFECT_WARP_INCLUDED
