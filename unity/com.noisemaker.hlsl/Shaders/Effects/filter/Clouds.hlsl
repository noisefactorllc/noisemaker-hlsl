#ifndef NM_CLOUDS_INCLUDED
#define NM_CLOUDS_INCLUDED

// =============================================================================
// Clouds.hlsl — filter/clouds, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/clouds/wgsl/clouds.wgsl
//
// Ridged multi-octave 2D simplex noise shaped into clouds, composited with an
// offset shadow onto the input texture.
//
// PORTING NOTES:
//  * Single render pass ("clouds"). Filter: samples inputTex.
//  * uv = (fragCoord + tileOffset) / fullResolution — WGSL uses globalCoord/fullRes.
//  * shadowOffset divides by texSize (inputTex dimensions), matching WGSL exactly.
//  * shadowDist uses min(texSize.x, texSize.y) * 0.008 — texSize not fullResolution.
//  * WGSL select(b, a, cond) → HLSL (cond ? a : b).
//  * pow(2.0, f32(i)) stays as pow(2.0, (float)i) — exp2 is numerically identical
//    for integer i but we match the literal structure from WGSL.
//  * No NMCore primitives used (no pcg/prng/random/nm_mod/nm_positiveModulo/nm_map).
//  * All simplex helpers are this effect's own copies — not shared.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect uniforms (definition.js globals[*].uniform) -----------------
int   seed;   // default 1, range 1..100
float scale;  // default 0.25, range 0.1..1.0
int   speed;  // default 0, range 0..4

// ---- Simplex 2D helpers (Ashima Arts, MIT License) --------------------------
// Port from WGSL verbatim; renamed to avoid collision with other effects.
float3 nm_clouds_mod289v3(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float2 nm_clouds_mod289v2(float2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float3 nm_clouds_permute3(float3 x) { return nm_clouds_mod289v3(((x * 34.0) + 1.0) * x); }

float nm_clouds_simplex2d(float2 v)
{
    float4 C = float4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);

    float2 i  = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    // WGSL: if (x0.x > x0.y) { i1 = vec2<f32>(1.0, 0.0); } else { i1 = vec2<f32>(0.0, 1.0); }
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12 = float4(x12.xy - i1, x12.zw);

    float2 im = nm_clouds_mod289v2(i);
    float3 p = nm_clouds_permute3(nm_clouds_permute3(im.y + float3(0.0, i1.y, 1.0)) + im.x + float3(0.0, i1.x, 1.0));
    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), float3(0.0, 0.0, 0.0));
    m = m * m;
    m = m * m;

    float3 x  = 2.0 * frac(p * C.www) - 1.0;
    float3 h  = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;
    m = m * (1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h));

    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g = float3(g.x, a0.yz * x12.xz + h.yz * x12.yw);

    return 130.0 * dot(m, g);
}

// ---- Cloud FBM: octave loop (WGSL cloudNoise) --------------------------------
float nm_clouds_cloudNoise(float2 uv, float baseFreq, int octaves, float animPhase, float animSpeed)
{
    float accum    = 0.0;
    float totalAmp = 0.0;

    // WGSL: for (var i: i32 = 0; i < 8; i = i + 1) { if (i >= octaves) { break; } ... }
    for (int i = 0; i < 8; i = i + 1)
    {
        if (i >= octaves) { break; }
        float freq = baseFreq * pow(2.0, (float)i);
        float amp  = 1.0 / pow(2.0, (float)i);

        // Per-octave circular offset for morphing animation
        // Subtract initial position so offset is zero at time=0
        float octavePhase  = (float)i * 2.13;
        float octaveRadius = (0.25 + (float)i * 0.08) * animSpeed;
        float2 timeOffset  = (float2(cos(animPhase + octavePhase), sin(animPhase + octavePhase))
                            - float2(cos(octavePhase), sin(octavePhase))) * octaveRadius;

        float n = nm_clouds_simplex2d(uv * freq + float2((float)i * 37.0, (float)i * 53.0) + timeOffset);
        n = n * 0.5 + 0.5;

        accum    = accum + n * amp;
        totalAmp = totalAmp + amp;
    }

    return accum / totalAmp;
}

#endif // NM_CLOUDS_INCLUDED
