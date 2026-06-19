#ifndef NM_EFFECT_GRIME_INCLUDED
#define NM_EFFECT_GRIME_INCLUDED

// =============================================================================
// Grime.hlsl — filter/grime (func: "grime")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/filter/grime/wgsl/grime.wgsl
//
// Dusty speckles and grime overlay: multi-octave value noise with self-
// refraction, a Chebyshev (max-abs) derivative gradient, dropout specks, and
// sparse exponential noise blended to dirty the input. Single render pass.
// RGB is affected; alpha is passed through unchanged.
//
// PORTING-GUIDE notes / hazards handled:
//  * COORDINATES: the WGSL uses `uv = input.uv` (the fullscreen 0..1 varying)
//    for BOTH the inputTex sample AND all noise lookups, and
//    `dims = max(resolution, vec2(1,1))` with `px = 1/dims`. We mirror exactly:
//    uv = i.uv, dims = max(resolution, (1,1)). (The GLSL splits sample uv from a
//    fullResolution-based globalUV/px; WGSL is canonical and uses a single uv,
//    so we follow WGSL.) No per-effect Y flip (top-left origin, H8).
//  * PRNG bit hazard (H-floatbits): hash21/hash31 feed `bitcast<u32>(p.*)` into
//    pcg — a BIT REINTERPRET. In HLSL that is `asuint(...)`, NOT the `(uint3)`
//    truncation cast used by NMCore's nm_prng. hash21's third lane is the
//    literal `0u`, NOT a bitcast. We reuse NMCore's nm_pcg (identical PCG) but
//    declare effect-local hash21/hash31 with asuint to preserve bit-for-bit.
//  * PCG divisor is float(0xffffffffu) = 4294967295.0, NOT 2^32 (H11). We keep
//    the literal `0xffffffffu` exactly as the WGSL writes it.
//  * `select(0.0, 1.0, cond)` (WGSL) -> `cond ? 1.0 : 0.0` (H: select reversed).
//  * `mix`->`lerp`, `fract`->`frac`. nm_mod not needed (no modulo here).
//  * All math is full 32-bit float; loop bound `i < 8u` kept exactly.
//  * Linear, clamp-to-edge, non-sRGB sampler (H7) — set on the SamplerState.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (reference binding: sampler@0, inputTex@1) ------
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
// WGSL binds both as f32; the runtime sets them as floats. seed is logically an
// int control [1..100] but consumed as f32 (WGSL `var<uniform> seed: f32`).
float strength;  // globals.strength.uniform, [0,1]    default 0.5
float seed;      // globals.seed.uniform,     [1..100]  default 1

// -----------------------------------------------------------------------------
// clamp01 — verbatim.
// -----------------------------------------------------------------------------
float nm_grime_clamp01(float v)
{
    return clamp(v, 0.0, 1.0);
}

// -----------------------------------------------------------------------------
// freq_for_shape — verbatim.
// -----------------------------------------------------------------------------
float2 nm_grime_freq_for_shape(float freq, float w, float h)
{
    if (w <= 0.0 || h <= 0.0) { return float2(freq, freq); }
    if (abs(w - h) < 0.5) { return float2(freq, freq); }
    if (h < w) { return float2(freq, freq * w / h); }
    return float2(freq * h / w, freq);
}

// -----------------------------------------------------------------------------
// hash21 / hash31 — verbatim. bitcast<u32> -> asuint (BIT REINTERPRET, H-bits).
// hash21's 3rd lane is the literal 0u, NOT a bitcast. Reuses NMCore nm_pcg.
// -----------------------------------------------------------------------------
float nm_grime_hash21(float2 p)
{
    uint3 v = nm_pcg(uint3(asuint(p.x), asuint(p.y), 0u));
    return float(v.x) / float(0xffffffffu);
}

float nm_grime_hash31(float3 p)
{
    uint3 v = nm_pcg(uint3(asuint(p.x), asuint(p.y), asuint(p.z)));
    return float(v.x) / float(0xffffffffu);
}

// -----------------------------------------------------------------------------
// fade — verbatim smoothstep-style hermite.
// -----------------------------------------------------------------------------
float nm_grime_fade(float t)
{
    return t * t * (3.0 - 2.0 * t);
}

// -----------------------------------------------------------------------------
// value_noise — verbatim. Bilinear-faded value noise on a hash31 lattice.
// -----------------------------------------------------------------------------
float nm_grime_value_noise(float2 coord, float s)
{
    float2 cell = floor(coord);
    float2 f = frac(coord);
    float tl = nm_grime_hash31(float3(cell, s));
    float tr = nm_grime_hash31(float3(cell + float2(1.0, 0.0), s));
    float bl = nm_grime_hash31(float3(cell + float2(0.0, 1.0), s));
    float br = nm_grime_hash31(float3(cell + float2(1.0, 1.0), s));
    float2 st = float2(nm_grime_fade(f.x), nm_grime_fade(f.y));
    return lerp(lerp(tl, tr, st.x), lerp(bl, br, st.x), st.y);
}

// -----------------------------------------------------------------------------
// seed_offset — verbatim.
// -----------------------------------------------------------------------------
float2 nm_grime_seed_offset(float s)
{
    float angle = s * 0.1375;
    float radius = 0.35 * (0.25 + 0.75 * sin(s * 1.37));
    return float2(cos(angle), sin(angle)) * radius;
}

// -----------------------------------------------------------------------------
// simple_multires — verbatim. 8-octave fbm of value_noise. Loop bound kept (<8).
// -----------------------------------------------------------------------------
float nm_grime_simple_multires(float2 uv, float2 base_freq, float s)
{
    float2 freq = base_freq;
    float amp = 0.5;
    float total = 0.0;
    float accum = 0.0;

    for (uint i = 0u; i < 8u; i = i + 1u)
    {
        float os = s + float(i) * 37.11;
        float2 off = nm_grime_seed_offset(os) / freq;
        accum = accum + nm_grime_value_noise(uv * freq + off, os) * amp;
        total = total + amp;
        freq = freq * 2.0;
        amp = amp * 0.5;
    }

    return nm_grime_clamp01(accum / max(total, 0.001));
}

// -----------------------------------------------------------------------------
// refracted_field — verbatim. Self-displaced multires sampling.
// -----------------------------------------------------------------------------
float nm_grime_refracted_field(float2 uv, float2 base_freq, float2 px, float disp, float s)
{
    float base_mask = nm_grime_simple_multires(uv, base_freq, s);
    float off_mask = nm_grime_simple_multires(frac(uv + float2(0.5, 0.5)), base_freq, s + 19.0);

    float2 off_vec = float2(
        (base_mask * 2.0 - 1.0) * disp * px.x,
        (off_mask * 2.0 - 1.0) * disp * px.y);
    return nm_grime_simple_multires(frac(uv + off_vec), base_freq, s + 41.0);
}

// -----------------------------------------------------------------------------
// chebyshev_gradient — verbatim. Max-abs central-difference derivative.
// -----------------------------------------------------------------------------
float nm_grime_chebyshev_gradient(float2 uv, float2 base_freq, float2 px, float disp, float s)
{
    float2 ox = float2(px.x, 0.0);
    float2 oy = float2(0.0, px.y);

    float r = nm_grime_refracted_field(frac(uv + ox), base_freq, px, disp, s);
    float l = nm_grime_refracted_field(frac(uv - ox), base_freq, px, disp, s);
    float u = nm_grime_refracted_field(frac(uv + oy), base_freq, px, disp, s);
    float d = nm_grime_refracted_field(frac(uv - oy), base_freq, px, disp, s);

    float dx = (r - l) * 0.5;
    float dy = (u - d) * 0.5;
    return nm_grime_clamp01(max(abs(dx), abs(dy)) * 4.0);
}

// -----------------------------------------------------------------------------
// exponential_noise — verbatim. value_noise^4 with a seeded offset.
// -----------------------------------------------------------------------------
float nm_grime_exponential_noise(float2 uv, float2 freq, float s)
{
    float2 off = nm_grime_seed_offset(s + 7.0);
    return pow(nm_grime_clamp01(nm_grime_value_noise(uv * freq + off, s + 13.0)), 4.0);
}

// -----------------------------------------------------------------------------
// refracted_exponential — verbatim. Self-displaced exponential noise.
// -----------------------------------------------------------------------------
float nm_grime_refracted_exponential(float2 uv, float2 freq, float2 px, float disp, float s)
{
    float base = nm_grime_exponential_noise(uv, freq, s);
    float ox = nm_grime_exponential_noise(uv, freq, s + 23.0);
    float oy = nm_grime_exponential_noise(frac(uv + float2(0.5, 0.5)), freq, s + 47.0);

    float2 off_vec = float2(
        (ox * 2.0 - 1.0) * disp * px.x,
        (oy * 2.0 - 1.0) * disp * px.y);
    float warped = nm_grime_exponential_noise(frac(uv + off_vec), freq, s + 59.0);
    return nm_grime_clamp01((base + warped) * 0.5);
}

// ---- Pass: "grime" (progName "grime") ---------------------------------------
// Verbatim port of WGSL main(). uv = input.uv (i.uv); dims = max(resolution,1).
float4 NMFrag_grime(NMVaryings i) : SV_Target
{
    float2 dims = max(resolution, float2(1.0, 1.0));
    float2 px = float2(1.0 / dims.x, 1.0 / dims.y);
    float2 uv = i.uv;
    float4 base_color = inputTex.Sample(sampler_inputTex, uv);

    float str = max(strength, 0.0);
    float s = seed;

    // Multi-octave noise mask, self-refracted
    float2 freq_mask = nm_grime_freq_for_shape(5.0, dims.x, dims.y);
    float mask_refracted = nm_grime_refracted_field(uv, freq_mask, px, 1.0, s + 11.0);
    float mask_gradient = nm_grime_chebyshev_gradient(uv, freq_mask, px, 1.0, s + 11.0);
    float mask_value = nm_grime_clamp01(lerp(mask_refracted, mask_gradient, 0.125));

    // Blend input with dark dust using squared mask
    float mask_power = nm_grime_clamp01(mask_value * mask_value * 0.4);
    float3 dusty = lerp(base_color.rgb, float3(0.15, 0.15, 0.15), mask_power);

    // Speck overlay: dropout + exponential noise, refracted
    float2 freq_specks = dims * 0.1;
    float dropout = (nm_grime_hash21(uv * dims + float2(s + 37.0, s * 1.37)) < 0.4) ? 1.0 : 0.0;
    float specks_field = nm_grime_refracted_exponential(uv, freq_specks, px, 0.25, s + 71.0) * dropout;
    float trimmed = nm_grime_clamp01((specks_field - 0.3) / 0.7);
    float specks = 1.0 - sqrt(trimmed);

    // Sparse noise
    float sparse_mask = (nm_grime_hash21(uv * dims + float2(s + 113.0, s + 171.0)) < 0.25) ? 1.0 : 0.0;
    float sparse_noise = nm_grime_exponential_noise(uv, dims, s + 131.0) * sparse_mask;

    // Combine
    dusty = lerp(dusty, float3(sparse_noise, sparse_noise, sparse_noise), 0.15);
    dusty = dusty * specks;

    // Final blend: mix input toward dusty layer using mask * strength
    float blend_mask = nm_grime_clamp01(mask_value * str);
    float3 final_rgb = lerp(base_color.rgb, dusty, blend_mask);

    return float4(clamp(final_rgb, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0)), base_color.a);
}

#endif // NM_EFFECT_GRIME_INCLUDED
