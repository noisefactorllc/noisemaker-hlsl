#ifndef NM_EFFECT_GRAIN_INCLUDED
#define NM_EFFECT_GRAIN_INCLUDED

// =============================================================================
// Grain.hlsl — filter/grain (func: "grain")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/filter/grain/wgsl/grain.wgsl
//
// Film grain: blend the source image with animated value noise (simplex-based
// value noise with bicubic interpolation along x/y and time). Single pass.
// RGB is affected; alpha is passed through unchanged.
//
// PORTING-GUIDE notes / hazards handled:
//  * The WGSL is a COMPUTE shader writing to a storage buffer; we emit it as a
//    single fullscreen RENDER pass (the runtime treats compute grain as a GPGPU
//    render pass, mirroring the GLSL fragment port). The per-pixel math is
//    identical.
//  * Pixel coordinates: WGSL uses gid.xy (global invocation id) as the integer
//    pixel coords for BOTH the textureLoad and the noise UV. The GLSL adds
//    tileOffset for the bounds/UV (global_pixel) but uses gl_FragCoord (no
//    offset) for the texelFetch. We follow the WGSL canonical form: a single
//    integer pixel coord = floor(NM_GlobalCoord) used for both sampling and
//    noise. With no tiling (tileOffset=0, renderScale=1) these agree exactly.
//  * dims fed to sample_grain_noise: WGSL passes the dispatch size (width,
//    height) = the OUTPUT/INPUT pixel dimensions. GLSL divides by renderScale
//    (rs = max(renderScale,1)). We use fullResolution / max(renderScale,1) to
//    match the GLSL's render-path dims so the noise frequency is resolution-
//    independent across tiled renders; untiled (rs=1) this equals the WGSL.
//  * UINT32_TO_FLOAT divisor is 2^32 = 4294967296.0 here (NOT 0xffffffff). This
//    is grain's OWN normalization; ported verbatim — do NOT use nm_prng.
//  * pcg3d is bit-identical to NMCore nm_pcg (the shared PCG primitive); reused.
//  * `select(time, 0.0, pause > 0.5)` -> WGSL select picks arg[1] (0.0) when the
//    condition is true. HLSL ternary: `(pause > 0.5) ? 0.0 : time`.
//  * `bitcast<u32>(cell.x)` (int two's-complement -> uint) -> HLSL `(uint)cell.x`
//    (reinterpret cast; two's-complement preserved for negative cells, H37).
//  * `i32(floor(x))` lattice coords -> `(int)floor(x)` numeric truncation.
//  * Do NOT reassociate blend_cubic's redundant terms (H-golden-rule 3).
//  * mix -> lerp; fract -> frac; clamp/floor/sin/cos/abs map 1:1.
//  * Linear, clamp-to-edge, non-sRGB sampler (H7).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (reference binding: inputTex@0) -----------------
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
float alpha;   // globals.alpha.uniform, [0,1]   default 0.25
float pause;   // globals.pause.uniform (bool as 0/1) default 0 (false)

// ---- Constants (verbatim from WGSL) ------------------------------------------
static const float NM_GRAIN_PI   = 3.14159265358979323846;
static const float NM_GRAIN_TAU  = 6.28318530717958647692;
static const float NM_GRAIN_UINT32_TO_FLOAT = 1.0 / 4294967296.0;
static const uint  NM_GRAIN_INTERPOLATION_CONSTANT = 0u;
static const uint  NM_GRAIN_INTERPOLATION_LINEAR   = 1u;
static const uint  NM_GRAIN_INTERPOLATION_COSINE   = 2u;
static const uint  NM_GRAIN_INTERPOLATION_BICUBIC  = 3u;
static const uint  NM_GRAIN_BASE_SEED = 0x1234u;

// -----------------------------------------------------------------------------
float nm_grain_clamp01(float value)
{
    return clamp(value, 0.0, 1.0);
}

// pcg3d — bit-identical to NMCore nm_pcg (shared PCG primitive).
uint3 nm_grain_pcg3d(uint3 v_in)
{
    uint3 v = v_in * 1664525u + 1013904223u;
    v.x = v.x + v.y * v.z;
    v.y = v.y + v.z * v.x;
    v.z = v.z + v.x * v.y;
    v = v ^ (v >> uint3(16u, 16u, 16u));
    v.x = v.x + v.y * v.z;
    v.y = v.y + v.z * v.x;
    v.z = v.z + v.x * v.y;
    return v;
}

// random_from_cell_3d — verbatim. bitcast<u32>(cell.x) -> (uint)cell.x (two's-
// complement reinterpret); normalized by 2^32.
float nm_grain_random_from_cell_3d(int3 cell, uint seed)
{
    uint3 hashed = uint3(
        (uint)cell.x ^ seed,
        (uint)cell.y ^ (seed * 0x9e3779b9u + 0x7f4a7c15u),
        (uint)cell.z ^ (seed * 0x632be59bu + 0x5bf03635u)
    );
    uint3 noise = nm_grain_pcg3d(hashed);
    return (float)noise.x * NM_GRAIN_UINT32_TO_FLOAT;
}

float nm_grain_periodic_value(float time_value, float sample_val)
{
    return (sin((time_value - sample_val) * NM_GRAIN_TAU) + 1.0) * 0.5;
}

float nm_grain_interpolation_weight(float value, uint spline_order)
{
    if (spline_order == NM_GRAIN_INTERPOLATION_COSINE)
    {
        float clamped = clamp(value, 0.0, 1.0);
        float angle = clamped * NM_GRAIN_PI;
        float cos_value = cos(angle);
        return (1.0 - cos_value) * 0.5;
    }
    return value;
}

// blend_cubic — reproduce the redundant/partially-cancelling terms LITERALLY.
float nm_grain_blend_cubic(float a, float b, float c, float d, float g)
{
    float t = clamp(g, 0.0, 1.0);
    float t2 = t * t;
    float a0 = ((d - c) - a) + b;
    float a1 = (a - b) - a0;
    float a2 = c - a;
    float a3 = b;
    float term1 = (a0 * t) * t2;
    float term2 = a1 * t2;
    float term3 = (a2 * t) + a3;
    return (term1 + term2) + term3;
}

float nm_grain_sample_bicubic_layer(int2 cell, float2 frac_uv, int z_cell, uint base_seed)
{
    float row0 = nm_grain_blend_cubic(
        nm_grain_random_from_cell_3d(int3(cell.x - 1, cell.y - 1, z_cell), base_seed),
        nm_grain_random_from_cell_3d(int3(cell.x + 0, cell.y - 1, z_cell), base_seed),
        nm_grain_random_from_cell_3d(int3(cell.x + 1, cell.y - 1, z_cell), base_seed),
        nm_grain_random_from_cell_3d(int3(cell.x + 2, cell.y - 1, z_cell), base_seed),
        frac_uv.x
    );
    float row1 = nm_grain_blend_cubic(
        nm_grain_random_from_cell_3d(int3(cell.x - 1, cell.y + 0, z_cell), base_seed),
        nm_grain_random_from_cell_3d(int3(cell.x + 0, cell.y + 0, z_cell), base_seed),
        nm_grain_random_from_cell_3d(int3(cell.x + 1, cell.y + 0, z_cell), base_seed),
        nm_grain_random_from_cell_3d(int3(cell.x + 2, cell.y + 0, z_cell), base_seed),
        frac_uv.x
    );
    float row2 = nm_grain_blend_cubic(
        nm_grain_random_from_cell_3d(int3(cell.x - 1, cell.y + 1, z_cell), base_seed),
        nm_grain_random_from_cell_3d(int3(cell.x + 0, cell.y + 1, z_cell), base_seed),
        nm_grain_random_from_cell_3d(int3(cell.x + 1, cell.y + 1, z_cell), base_seed),
        nm_grain_random_from_cell_3d(int3(cell.x + 2, cell.y + 1, z_cell), base_seed),
        frac_uv.x
    );
    float row3 = nm_grain_blend_cubic(
        nm_grain_random_from_cell_3d(int3(cell.x - 1, cell.y + 2, z_cell), base_seed),
        nm_grain_random_from_cell_3d(int3(cell.x + 0, cell.y + 2, z_cell), base_seed),
        nm_grain_random_from_cell_3d(int3(cell.x + 1, cell.y + 2, z_cell), base_seed),
        nm_grain_random_from_cell_3d(int3(cell.x + 2, cell.y + 2, z_cell), base_seed),
        frac_uv.x
    );
    return nm_grain_blend_cubic(row0, row1, row2, row3, frac_uv.y);
}

float nm_grain_sample_raw_value_noise(
    float2 uv,
    float2 freq,
    uint base_seed,
    float time_value,
    float speed_value,
    uint spline_order)
{
    float2 scaled_freq = max(freq, float2(1.0, 1.0));
    float2 scaled_uv = uv * scaled_freq;
    float2 cell_f = floor(scaled_uv);
    int2 cell = int2((int)cell_f.x, (int)cell_f.y);
    float2 frac_uv = frac(scaled_uv);
    float angle = time_value * NM_GRAIN_TAU;
    float time_coord = cos(angle) * speed_value;
    float time_floor = floor(time_coord);
    int time_cell = (int)time_floor;
    float time_frac = frac(time_coord);

    if (spline_order == NM_GRAIN_INTERPOLATION_CONSTANT)
    {
        return nm_grain_random_from_cell_3d(int3(cell.x, cell.y, time_cell), base_seed);
    }

    if (spline_order == NM_GRAIN_INTERPOLATION_LINEAR)
    {
        float tl = nm_grain_random_from_cell_3d(int3(cell.x, cell.y, time_cell), base_seed);
        float tr = nm_grain_random_from_cell_3d(int3(cell.x + 1, cell.y, time_cell), base_seed);
        float bl = nm_grain_random_from_cell_3d(int3(cell.x, cell.y + 1, time_cell), base_seed);
        float br = nm_grain_random_from_cell_3d(int3(cell.x + 1, cell.y + 1, time_cell), base_seed);
        float weight_x = nm_grain_interpolation_weight(frac_uv.x, spline_order);
        float top = lerp(tl, tr, weight_x);
        float bottom = lerp(bl, br, weight_x);
        float weight_y = nm_grain_interpolation_weight(frac_uv.y, spline_order);
        return lerp(top, bottom, weight_y);
    }

    if (spline_order == NM_GRAIN_INTERPOLATION_COSINE)
    {
        float weight_x = nm_grain_interpolation_weight(frac_uv.x, spline_order);
        float weight_y = nm_grain_interpolation_weight(frac_uv.y, spline_order);
        float tl = nm_grain_random_from_cell_3d(int3(cell.x, cell.y, time_cell), base_seed);
        float tr = nm_grain_random_from_cell_3d(int3(cell.x + 1, cell.y, time_cell), base_seed);
        float bl = nm_grain_random_from_cell_3d(int3(cell.x, cell.y + 1, time_cell), base_seed);
        float br = nm_grain_random_from_cell_3d(int3(cell.x + 1, cell.y + 1, time_cell), base_seed);
        float top = lerp(tl, tr, weight_x);
        float bottom = lerp(bl, br, weight_x);
        return lerp(top, bottom, weight_y);
    }

    float slice0 = nm_grain_sample_bicubic_layer(cell, frac_uv, time_cell - 1, base_seed);
    float slice1 = nm_grain_sample_bicubic_layer(cell, frac_uv, time_cell + 0, base_seed);
    float slice2 = nm_grain_sample_bicubic_layer(cell, frac_uv, time_cell + 1, base_seed);
    float slice3 = nm_grain_sample_bicubic_layer(cell, frac_uv, time_cell + 2, base_seed);
    return nm_grain_blend_cubic(slice0, slice1, slice2, slice3, time_frac);
}

float nm_grain_sample_value_noise(
    float2 uv,
    float2 freq,
    uint seed,
    float time_value,
    float speed_value,
    uint spline_order)
{
    uint base_seed = seed;
    float base_value = nm_grain_sample_raw_value_noise(
        uv,
        freq,
        base_seed,
        time_value,
        speed_value,
        spline_order
    );

    if (speed_value == 0.0 || time_value == 0.0)
    {
        return base_value;
    }

    uint time_seed = base_seed + 0x9e3779b1u;
    float time_field = nm_grain_sample_raw_value_noise(
        uv,
        freq,
        time_seed,
        0.0,
        1.0,
        spline_order
    );
    float scaled_time = nm_grain_periodic_value(time_value, time_field) * speed_value;
    return nm_grain_periodic_value(scaled_time, base_value);
}

float nm_grain_sample_grain_noise(
    uint2 pixel_coords,
    float2 dims,
    float time_value,
    float speed_value)
{
    float width = max(dims.x, 1.0);
    float height = max(dims.y, 1.0);
    float2 uv = float2((float)pixel_coords.x / width, (float)pixel_coords.y / height);
    float2 freq = float2(width, height);
    return nm_grain_sample_value_noise(uv, freq, NM_GRAIN_BASE_SEED, time_value, speed_value, NM_GRAIN_INTERPOLATION_BICUBIC);
}

// =============================================================================
// nm_grain — core per-pixel evaluation. `texel` is the sampled input RGBA;
// `pixel_coords` is the integer global pixel coord; `dims` is the noise-domain
// resolution (fullResolution / max(renderScale,1)). Returns RGBA.
//
// WGSL main() body:
//   blend_alpha = clamp(alpha, 0, 1); if (<=0) return texel;
//   effective_time = select(time, 0.0, pause > 0.5);
//   noise = sample_grain_noise(gid.xy, dims, effective_time, 100.0);
//   mixed = mix(texel.rgb, vec3(noise), blend_alpha);
//   return vec4(clamp01(mixed), texel.a);
// =============================================================================
float4 nm_grain(float4 texel, uint2 pixel_coords, float2 dims)
{
    float blend_alpha = clamp(alpha, 0.0, 1.0);
    if (blend_alpha <= 0.0)
    {
        return texel;
    }

    // When paused, use time=0 for static noise; otherwise use actual time.
    float effective_time = (pause > 0.5) ? 0.0 : time;

    float noise_value = nm_grain_sample_grain_noise(
        pixel_coords,
        dims,
        effective_time,
        100.0
    );
    float3 noise_rgb = float3(noise_value, noise_value, noise_value);
    float3 mixed_rgb = lerp(texel.rgb, noise_rgb, blend_alpha);
    return float4(
        nm_grain_clamp01(mixed_rgb.x),
        nm_grain_clamp01(mixed_rgb.y),
        nm_grain_clamp01(mixed_rgb.z),
        texel.a
    );
}

// ---- Pass: "grain" (progName "grain") ---------------------------------------
float4 NMFrag_grain(NMVaryings i) : SV_Target
{
    // WGSL: gid.xy = integer global pixel coords (used for textureLoad + noise).
    // GLSL render path: global_pixel = floor(fragCoord + tileOffset), and dims =
    // fullResolution / max(renderScale,1). NM_GlobalCoord = fragCoord+tileOffset.
    float2 globalCoord = NM_GlobalCoord(i);
    uint2 pixel_coords = uint2((uint)globalCoord.x, (uint)globalCoord.y);

    float rs = max(renderScale, 1.0);
    float2 dims = float2(fullResolution.x / rs, fullResolution.y / rs);

    // textureLoad at integer coords -> integer-centered UV sample (no offset by
    // tileOffset, matching the GLSL texelFetch(inputTex, gl_FragCoord)).
    float2 sampleUV = NM_FragCoord(i) / max(resolution, float2(1.0, 1.0));
    float4 texel = inputTex.Sample(sampler_inputTex, sampleUV);

    return nm_grain(texel, pixel_coords, dims);
}

#endif // NM_EFFECT_GRAIN_INCLUDED
