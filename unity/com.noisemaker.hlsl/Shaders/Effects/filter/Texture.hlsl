#ifndef NM_EFFECT_TEXTURE_INCLUDED
#define NM_EFFECT_TEXTURE_INCLUDED

// =============================================================================
// Texture.hlsl — filter/texture (func: "texture")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/filter/texture/wgsl/texture.wgsl
//
// Generate a height field from one of several texture modes (canvas, crosshatch,
// halftone, paper, stucco), derive shading from the height-field gradient, then
// blend the shaded result back into the source pixels by `alpha`. Single render
// pass. RGB only is affected; alpha is passed through unchanged.
//
// PORTING-GUIDE notes / hazards handled:
//  * Sampling UV is the fullscreen 0..1 `uv` (WGSL `in.uv`), used directly for
//    the textureSample AND as the height-field domain. NM_FragCoord(i) is the
//    @builtin(position) analog; we use i.uv (the canonical top-left UV) directly,
//    matching the WGSL `in.uv`. No per-effect Y flip (H8).
//  * `dims = textureDimensions(inputTex)` is the INPUT TEXTURE size; `pixel_step
//    = 1/dims` is the neighbor offset for the gradient. We mirror exactly.
//  * MODE is a compile-time const in WGSL (definition.js globals.mode.define =
//    "MODE"). Per PORTING-GUIDE it is dispatched at runtime with [branch] (same
//    variants the WGSL keeps; runtime const-folds). It is declared as an `int`
//    uniform named `MODE` — the EXACT define key the runtime injects, since
//    UniformBinder writes define ints by their key (mpb.SetInt("MODE", ...)),
//    mirroring Noise.hlsl's `int NOISE_TYPE`. A lowercase `mode` would never be
//    bound and would silently default to 0 (canvas). Default 3 = paper.
//  * fast_hash uses `bitcast<u32>(p.x)` for the int lattice coords -> HLSL
//    `asuint(p.x)` (two's-complement reinterpret of the i32). p is int3, so this
//    is a bit reinterpret of a signed int, identical to WGSL bitcast.
//  * hash_uint uses unsigned multiplies/shifts with literal 32-bit constants
//    (0x7feb352du etc.) — copy verbatim; wraps mod 2^32.
//  * value_noise z-wrap: `z0 = int(floor(motion)) % Z_LOOP` — HLSL `%` is trunc,
//    matching WGSL i32 `%`. Z_LOOP = 2.
//  * INV_UINT32_MAX = 1.0 / 4294967295.0 (full-precision divisor, H11).
//  * `mix` -> `lerp`; `fract` -> `frac`; `f32(u)`/`f32(octave)` -> (float)cast.
//  * Linear, clamp-to-edge, non-sRGB sampler (H7) — set on the SamplerState in
//    Texture.shader / supplied by the Shader Graph node.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (reference binding: sampler@0, inputTex@1) ------
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
// Bound by the runtime via MaterialPropertyBlock by these exact names.
int   MODE;   // globals.mode.define = "MODE", choices 0..4, default 3 (paper)
float alpha;  // globals.alpha.uniform, [0,1] default 0.5
float scale;  // globals.scale.uniform, [0.1,10] default 1.0
// `time` is engine-provided via NMFullscreen alias.

// ---- Effect-local constants (verbatim from WGSL) ----------------------------
static const float TEX_PI = 3.14159265359;
static const float INV_UINT32_MAX = 1.0 / 4294967295.0;
static const int   Z_LOOP = 2;
static const float SHADE_GAIN = 4.4;

float nm_texture_clamp01(float value)
{
    return clamp(value, 0.0, 1.0);
}

float nm_texture_fade(float t)
{
    return t * t * (3.0 - 2.0 * t);
}

float2 nm_texture_freq_for_shape(float base_freq, float2 dims)
{
    float w = max(dims.x, 1.0);
    float h = max(dims.y, 1.0);
    if (abs(w - h) < 0.5)
    {
        return float2(base_freq, base_freq);
    }
    if (w > h)
    {
        return float2(base_freq, base_freq * w / h);
    }
    return float2(base_freq * h / w, base_freq);
}

uint nm_texture_hash_uint(uint x_in)
{
    uint x = x_in;
    x ^= x >> 16u;
    x *= 0x7feb352du;
    x ^= x >> 15u;
    x *= 0x846ca68bu;
    x ^= x >> 16u;
    return x;
}

float nm_texture_fast_hash(int3 p, uint salt)
{
    uint h = salt ^ 0x9e3779b9u;
    h ^= asuint(p.x) * 0x27d4eb2du;
    h = nm_texture_hash_uint(h);
    h ^= asuint(p.y) * 0xc2b2ae35u;
    h = nm_texture_hash_uint(h);
    h ^= asuint(p.z) * 0x165667b1u;
    h = nm_texture_hash_uint(h);
    return (float)h * INV_UINT32_MAX;
}

float nm_texture_value_noise(float2 uv, float2 freq, float motion, uint salt)
{
    float2 scaled_uv = uv * max(freq, float2(1.0, 1.0));
    float2 cell_floor = floor(scaled_uv);
    float2 frac_part = frac(scaled_uv);
    int2 base_cell = int2((int)cell_floor.x, (int)cell_floor.y);

    float z_floor = floor(motion);
    float z_frac = frac(motion);
    int z0 = (int)z_floor % Z_LOOP;
    int z1 = (z0 + 1) % Z_LOOP;

    float c000 = nm_texture_fast_hash(int3(base_cell.x + 0, base_cell.y + 0, z0), salt);
    float c100 = nm_texture_fast_hash(int3(base_cell.x + 1, base_cell.y + 0, z0), salt);
    float c010 = nm_texture_fast_hash(int3(base_cell.x + 0, base_cell.y + 1, z0), salt);
    float c110 = nm_texture_fast_hash(int3(base_cell.x + 1, base_cell.y + 1, z0), salt);
    float c001 = nm_texture_fast_hash(int3(base_cell.x + 0, base_cell.y + 0, z1), salt);
    float c101 = nm_texture_fast_hash(int3(base_cell.x + 1, base_cell.y + 0, z1), salt);
    float c011 = nm_texture_fast_hash(int3(base_cell.x + 0, base_cell.y + 1, z1), salt);
    float c111 = nm_texture_fast_hash(int3(base_cell.x + 1, base_cell.y + 1, z1), salt);

    float tx = nm_texture_fade(frac_part.x);
    float ty = nm_texture_fade(frac_part.y);
    float tz = nm_texture_fade(z_frac);

    float x00 = lerp(c000, c100, tx);
    float x10 = lerp(c010, c110, tx);
    float x01 = lerp(c001, c101, tx);
    float x11 = lerp(c011, c111, tx);

    float y0 = lerp(x00, x10, ty);
    float y1 = lerp(x01, x11, ty);

    return lerp(y0, y1, tz);
}

// Paper: 3-octave ridged noise (original texture)
float nm_texture_height_paper(float2 uv, float2 base_freq, float motion)
{
    float2 freq = max(base_freq, float2(1.0, 1.0));
    float amplitude = 0.5;
    float accum = 0.0;
    float total = 0.0;

    for (uint octave = 0u; octave < 3u; octave = octave + 1u)
    {
        uint salt = 0x9e3779b9u * (octave + 1u);
        float sample_val = nm_texture_value_noise(uv, freq, motion + (float)octave * 0.37, salt);
        float ridged = 1.0 - abs(sample_val * 2.0 - 1.0);
        accum = accum + ridged * amplitude;
        total = total + amplitude;
        freq = freq * 2.0;
        amplitude = amplitude * 0.55;
    }

    if (total <= 0.0) { return nm_texture_clamp01(accum); }
    return nm_texture_clamp01(accum / total);
}

// Stucco: 2-octave smooth noise, lower frequency, rounder bumps
float nm_texture_height_stucco(float2 uv, float2 base_freq, float motion)
{
    float2 freq = max(base_freq, float2(1.0, 1.0));
    float amplitude = 0.5;
    float accum = 0.0;
    float total = 0.0;

    for (uint octave = 0u; octave < 2u; octave = octave + 1u)
    {
        uint salt = 0x9e3779b9u * (octave + 1u);
        float sample_val = nm_texture_value_noise(uv, freq, motion + (float)octave * 0.37, salt);
        accum = accum + sample_val * amplitude;
        total = total + amplitude;
        freq = freq * 2.0;
        amplitude = amplitude * 0.5;
    }

    if (total <= 0.0) { return nm_texture_clamp01(accum); }
    return nm_texture_clamp01(accum / total);
}

// Canvas: woven fabric pattern with slight noise perturbation
float nm_texture_height_canvas(float2 uv, float2 base_freq, float motion)
{
    float2 st = uv * base_freq;
    float warpX = abs(sin(st.x * TEX_PI));
    float weftY = abs(sin(st.y * TEX_PI));
    float weave = warpX * weftY;

    float noise = nm_texture_value_noise(uv, base_freq * 0.5, motion, 0x12345678u);
    return nm_texture_clamp01(weave * 0.85 + noise * 0.15);
}

// Halftone: regular circular dot grid
float nm_texture_height_halftone(float2 uv, float2 base_freq)
{
    float2 st = uv * base_freq;
    float2 cell = frac(st) - 0.5;
    float dotv = 1.0 - nm_texture_clamp01(length(cell) * 3.0);
    return dotv * dotv;
}

// Crosshatch: two overlapping diagonal sine ridges
float nm_texture_height_crosshatch(float2 uv, float2 base_freq)
{
    float2 st = uv * base_freq;
    float d1 = abs(sin((st.x + st.y) * TEX_PI));
    float d2 = abs(sin((st.x - st.y) * TEX_PI));
    return nm_texture_clamp01(d1 * d2);
}

// Dispatch to the active mode's height function. WGSL const-folds MODE; in HLSL
// MODE is a runtime int uniform branched with [branch] (PORTING-GUIDE). The
// uniform name MUST be the injected define key "MODE" (UniformBinder writes
// define ints by their key via mpb.SetInt), matching Noise.hlsl's NOISE_TYPE.
float nm_texture_height_field(float2 uv, float2 base_freq, float motion)
{
    [branch] if (MODE == 0) { return nm_texture_height_canvas(uv, base_freq, motion); }
    [branch] if (MODE == 1) { return nm_texture_height_crosshatch(uv, base_freq); }
    [branch] if (MODE == 2) { return nm_texture_height_halftone(uv, base_freq); }
    [branch] if (MODE == 4) { return nm_texture_height_stucco(uv, base_freq, motion); }
    return nm_texture_height_paper(uv, base_freq, motion);  // 3 = paper (default)
}

// ---- Pass: "texture" (progName "texture") -----------------------------------
float4 NMFrag_texture(NMVaryings i) : SV_Target
{
    // WGSL: in.uv is the fullscreen 0..1 UV (used for both sample and domain).
    float2 uv = i.uv;

    float4 base_color = inputTex.Sample(sampler_inputTex, uv);

    uint w, h;
    inputTex.GetDimensions(w, h);
    float2 dims = float2((float)w, (float)h);
    float2 pixel_step = 1.0 / dims;

    float a = clamp(alpha, 0.0, 1.0);
    if (a <= 0.0)
    {
        return base_color;
    }

    // Paper and stucco use different base frequencies
    float freq_scale = 24.0;
    [branch] if (MODE == 4) { freq_scale = 48.0; }
    float2 base_freq = nm_texture_freq_for_shape(freq_scale * (10.01 - scale), dims);
    float motion = time * (float)Z_LOOP;

    // Sample height field at center and 4 neighbors for gradient
    float h_center = nm_texture_height_field(uv, base_freq, motion);
    float h_right  = nm_texture_height_field(uv + float2(pixel_step.x, 0.0), base_freq, motion);
    float h_left   = nm_texture_height_field(uv - float2(pixel_step.x, 0.0), base_freq, motion);
    float h_up     = nm_texture_height_field(uv + float2(0.0, pixel_step.y), base_freq, motion);
    float h_down   = nm_texture_height_field(uv - float2(0.0, pixel_step.y), base_freq, motion);

    float gx = h_right - h_left;
    float gy = h_down - h_up;
    float gradient = sqrt(gx * gx + gy * gy);

    // Stucco uses stronger shading for more pronounced bumps
    float gain = SHADE_GAIN * 0.25;
    [branch] if (MODE == 4) { gain = SHADE_GAIN * 0.5; }
    float shade_base = nm_texture_clamp01(gradient * gain);

    float highlight_mix = nm_texture_clamp01((shade_base * shade_base) * 1.25);
    float base_factor = 0.9 + h_center * 0.35;
    float factor = clamp(base_factor + highlight_mix * 0.35, 0.85, 1.6);

    float3 scaled_rgb = clamp(base_color.xyz * factor, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));

    return float4(lerp(base_color.xyz, scaled_rgb, a), base_color.w);
}

#endif // NM_EFFECT_TEXTURE_INCLUDED
