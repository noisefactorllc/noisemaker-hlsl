#ifndef NM_SG_GRIME_INCLUDED
#define NM_SG_GRIME_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for filter/grime.
//
// Drops the effect into Shader Graph as a node. Each global param from
// definition.js maps to a named input:
//   strength -> Strength (float, strength) [0,1]   default 0.5
//   seed     -> Seed     (float, seed)     [1..100] default 1
// InputTex/SS/UV provide the source surface. UV must be the input texture's own
// 0..1 UV (the WGSL uses `input.uv` for BOTH the sample and all noise lookups).
//
// COORDINATE NOTE: the WGSL derives dims = max(resolution, 1) and px = 1/dims
// from the render-target resolution uniform. Shader Graph has no resolution
// global here, so `dims` is taken from the bound input texture's dimensions.
// This is exact when the input texture matches the render-target size (the
// runtime's untiled case). TODO(verify): if used at a mismatched resolution,
// feed an explicit Resolution input instead.
//
// Self-contained (does NOT include NMFullscreen.hlsl / NMCore.hlsl) so it is
// safe to drop into a Shader Graph Custom Function node. Helpers/core are
// mirrored VERBATIM from Shaders/Effects/filter/Grime.hlsl, name-prefixed
// `nmsg_` to avoid symbol clashes with the runtime include.
// =============================================================================

float nmsg_grime_clamp01(float v)
{
    return clamp(v, 0.0, 1.0);
}

float2 nmsg_grime_freq_for_shape(float freq, float w, float h)
{
    if (w <= 0.0 || h <= 0.0) { return float2(freq, freq); }
    if (abs(w - h) < 0.5) { return float2(freq, freq); }
    if (h < w) { return float2(freq, freq * w / h); }
    return float2(freq * h / w, freq);
}

// PCG 3D PRNG — verbatim (identical in all references). Local copy so the node
// is self-contained.
uint3 nmsg_grime_pcg(uint3 v)
{
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return v;
}

// hash21 / hash31 — bitcast<u32> -> asuint (BIT REINTERPRET). hash21 3rd lane 0u.
float nmsg_grime_hash21(float2 p)
{
    uint3 v = nmsg_grime_pcg(uint3(asuint(p.x), asuint(p.y), 0u));
    return float(v.x) / float(0xffffffffu);
}

float nmsg_grime_hash31(float3 p)
{
    uint3 v = nmsg_grime_pcg(uint3(asuint(p.x), asuint(p.y), asuint(p.z)));
    return float(v.x) / float(0xffffffffu);
}

float nmsg_grime_fade(float t)
{
    return t * t * (3.0 - 2.0 * t);
}

float nmsg_grime_value_noise(float2 coord, float s)
{
    float2 cell = floor(coord);
    float2 f = frac(coord);
    float tl = nmsg_grime_hash31(float3(cell, s));
    float tr = nmsg_grime_hash31(float3(cell + float2(1.0, 0.0), s));
    float bl = nmsg_grime_hash31(float3(cell + float2(0.0, 1.0), s));
    float br = nmsg_grime_hash31(float3(cell + float2(1.0, 1.0), s));
    float2 st = float2(nmsg_grime_fade(f.x), nmsg_grime_fade(f.y));
    return lerp(lerp(tl, tr, st.x), lerp(bl, br, st.x), st.y);
}

float2 nmsg_grime_seed_offset(float s)
{
    float angle = s * 0.1375;
    float radius = 0.35 * (0.25 + 0.75 * sin(s * 1.37));
    return float2(cos(angle), sin(angle)) * radius;
}

float nmsg_grime_simple_multires(float2 uv, float2 base_freq, float s)
{
    float2 freq = base_freq;
    float amp = 0.5;
    float total = 0.0;
    float accum = 0.0;

    for (uint i = 0u; i < 8u; i = i + 1u)
    {
        float os = s + float(i) * 37.11;
        float2 off = nmsg_grime_seed_offset(os) / freq;
        accum = accum + nmsg_grime_value_noise(uv * freq + off, os) * amp;
        total = total + amp;
        freq = freq * 2.0;
        amp = amp * 0.5;
    }

    return nmsg_grime_clamp01(accum / max(total, 0.001));
}

float nmsg_grime_refracted_field(float2 uv, float2 base_freq, float2 px, float disp, float s)
{
    float base_mask = nmsg_grime_simple_multires(uv, base_freq, s);
    float off_mask = nmsg_grime_simple_multires(frac(uv + float2(0.5, 0.5)), base_freq, s + 19.0);

    float2 off_vec = float2(
        (base_mask * 2.0 - 1.0) * disp * px.x,
        (off_mask * 2.0 - 1.0) * disp * px.y);
    return nmsg_grime_simple_multires(frac(uv + off_vec), base_freq, s + 41.0);
}

float nmsg_grime_chebyshev_gradient(float2 uv, float2 base_freq, float2 px, float disp, float s)
{
    float2 ox = float2(px.x, 0.0);
    float2 oy = float2(0.0, px.y);

    float r = nmsg_grime_refracted_field(frac(uv + ox), base_freq, px, disp, s);
    float l = nmsg_grime_refracted_field(frac(uv - ox), base_freq, px, disp, s);
    float u = nmsg_grime_refracted_field(frac(uv + oy), base_freq, px, disp, s);
    float d = nmsg_grime_refracted_field(frac(uv - oy), base_freq, px, disp, s);

    float dx = (r - l) * 0.5;
    float dy = (u - d) * 0.5;
    return nmsg_grime_clamp01(max(abs(dx), abs(dy)) * 4.0);
}

float nmsg_grime_exponential_noise(float2 uv, float2 freq, float s)
{
    float2 off = nmsg_grime_seed_offset(s + 7.0);
    return pow(nmsg_grime_clamp01(nmsg_grime_value_noise(uv * freq + off, s + 13.0)), 4.0);
}

float nmsg_grime_refracted_exponential(float2 uv, float2 freq, float2 px, float disp, float s)
{
    float base = nmsg_grime_exponential_noise(uv, freq, s);
    float ox = nmsg_grime_exponential_noise(uv, freq, s + 23.0);
    float oy = nmsg_grime_exponential_noise(frac(uv + float2(0.5, 0.5)), freq, s + 47.0);

    float2 off_vec = float2(
        (ox * 2.0 - 1.0) * disp * px.x,
        (oy * 2.0 - 1.0) * disp * px.y);
    float warped = nmsg_grime_exponential_noise(frac(uv + off_vec), freq, s + 59.0);
    return nmsg_grime_clamp01((base + warped) * 0.5);
}

// Core grime (param-injected), verbatim from Grime.hlsl NMFrag_grime() body.
float4 nmsg_grime(float4 base_color, float2 uv, float2 dims, float strength, float seed)
{
    float2 px = float2(1.0 / dims.x, 1.0 / dims.y);

    float str = max(strength, 0.0);
    float s = seed;

    float2 freq_mask = nmsg_grime_freq_for_shape(5.0, dims.x, dims.y);
    float mask_refracted = nmsg_grime_refracted_field(uv, freq_mask, px, 1.0, s + 11.0);
    float mask_gradient = nmsg_grime_chebyshev_gradient(uv, freq_mask, px, 1.0, s + 11.0);
    float mask_value = nmsg_grime_clamp01(lerp(mask_refracted, mask_gradient, 0.125));

    float mask_power = nmsg_grime_clamp01(mask_value * mask_value * 0.4);
    float3 dusty = lerp(base_color.rgb, float3(0.15, 0.15, 0.15), mask_power);

    float2 freq_specks = dims * 0.1;
    float dropout = (nmsg_grime_hash21(uv * dims + float2(s + 37.0, s * 1.37)) < 0.4) ? 1.0 : 0.0;
    float specks_field = nmsg_grime_refracted_exponential(uv, freq_specks, px, 0.25, s + 71.0) * dropout;
    float trimmed = nmsg_grime_clamp01((specks_field - 0.3) / 0.7);
    float specks = 1.0 - sqrt(trimmed);

    float sparse_mask = (nmsg_grime_hash21(uv * dims + float2(s + 113.0, s + 171.0)) < 0.25) ? 1.0 : 0.0;
    float sparse_noise = nmsg_grime_exponential_noise(uv, dims, s + 131.0) * sparse_mask;

    dusty = lerp(dusty, float3(sparse_noise, sparse_noise, sparse_noise), 0.15);
    dusty = dusty * specks;

    float blend_mask = nmsg_grime_clamp01(mask_value * str);
    float3 final_rgb = lerp(base_color.rgb, dusty, blend_mask);

    return float4(clamp(final_rgb, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0)), base_color.a);
}

// Shader Graph Custom Function entry. Samples InputTex at UV, derives `dims`
// from the bound texture (WGSL `resolution`, exact when input == render target).
// TODO(verify): SS must be a clamp, non-sRGB (linear) sampler state so it matches
// the runtime's bilinear/clamp/linear path (H7).
void NM_Grime_float(
    float          Strength,
    float          Seed,
    UnityTexture2D InputTex,
    UnitySamplerState SS,
    float2         UV,
    out float4     Out)
{
    float texW, texH;
    InputTex.GetDimensions(texW, texH);
    float2 dims = max(float2(texW, texH), float2(1.0, 1.0));

    float4 base_color = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, UV);
    Out = nmsg_grime(base_color, UV, dims, Strength, Seed);
}

#endif // NM_SG_GRIME_INCLUDED
