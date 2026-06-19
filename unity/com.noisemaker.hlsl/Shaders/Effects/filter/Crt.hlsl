#ifndef NM_EFFECT_CRT_INCLUDED
#define NM_EFFECT_CRT_INCLUDED

// =============================================================================
// Crt.hlsl — filter/crt (func: "crt")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/filter/crt/wgsl/crt.wgsl
//
// CRT monitor simulation: scanlines, lens warp, chromatic aberration, hue
// shift, saturation boost, vignette, and contrast normalization.
// Single render pass. RGB is affected; alpha is passed through unchanged.
//
// PORTING-GUIDE notes / hazards handled:
//  * WGSL is a compute shader that works in INTEGER pixel-space (gid.x/gid.y).
//    HLSL fullscreen pass uses NM_FragCoord(i) for the same pixel coords.
//  * The WGSL `params.motion.z` is the seed float; GLSL uses `float(seed)`.
//    We declare `int seed` uniform and cast to float where needed.
//  * `params.size.z >= 2.5` (channels check) is ALWAYS true for RGBA (4).
//    The chromatic-aberration / hue / saturation / vignette block always runs.
//  * WGSL textureLoad (nearest, integer coord) -> HLSL Load(int3(ix,iy,0)).
//  * WGSL `lerp` helper -> HLSL `lerp` (built-in, no conflict).
//    Local `lerp` helper renamed `crt_lerp` to avoid clash with HLSL intrinsic.
//  * GLSL reveals tileOffset/renderScale for aberration sample-X remapping;
//    WGSL omits this (tile-unaware compute). We follow the GLSL's aberration
//    coordinate transform for tiled-render correctness, as it is the same
//    logical operation. TODO(verify): parity-test with tileOffset != 0.
//  * `mix` -> `lerp`, `fract` -> `frac`, float mod -> nm_mod (not used here).
//  * All helpers copied verbatim from WGSL; no shared NMCore helpers used
//    except the include of NMFullscreen.hlsl for engine globals.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler ------------------------------------------------
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
float alpha;   // [0,1]  default 0.5
float speed;   // [0,5]  default 1.0
int   seed;    // [1,100] default 1

// ---- Constants (verbatim from WGSL) ----------------------------------------
static const float CRT_PI        = 3.14159265358979323846;
static const float CRT_TAU       = 6.28318530717958647692;
static const float CRT_INV_THREE = 0.3333333333333333;

// ---- Local helpers ----------------------------------------------------------

float crt_clamp01(float v)          { return clamp(v, 0.0, 1.0); }

float crt_random_scalar(float s)
{
    return frac(sin(s) * 43758.5453123);
}

float crt_normalized_sine(float v)  { return sin(v) * 0.5 + 0.5; }

float crt_periodic_value(float t, float v)
{
    return crt_normalized_sine((t - v) * CRT_TAU);
}

// ---- mod289 / permute / taylor_inv_sqrt / simplex_noise (verbatim WGSL) ----

float3 crt_mod289_vec3(float3 x)
{
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

float4 crt_mod289_vec4(float4 x)
{
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

float4 crt_permute(float4 x)
{
    return crt_mod289_vec4(((x * 34.0) + 1.0) * x);
}

float4 crt_taylor_inv_sqrt(float4 r)
{
    return 1.79284291400159 - 0.85373472095314 * r;
}

float crt_simplex_noise(float3 v)
{
    float2 C = float2(1.0 / 6.0, 1.0 / 3.0);
    float4 D = float4(0.0, 0.5, 1.0, 2.0);

    float3 i0 = floor(v + dot(v, (float3)C.y));
    float3 x0 = v - i0 + dot(i0, (float3)C.x);

    float3 step1 = step(float3(x0.y, x0.z, x0.x), x0);
    float3 l      = (float3)1.0 - step1;
    float3 i1     = min(step1, float3(l.z, l.x, l.y));
    float3 i2     = max(step1, float3(l.z, l.x, l.y));

    float3 x1 = x0 - i1 + (float3)C.x;
    float3 x2 = x0 - i2 + (float3)C.y;
    float3 x3 = x0 - (float3)D.y;

    float3 ii = crt_mod289_vec3(i0);
    float4 p = crt_permute(
        crt_permute(
            crt_permute(ii.z + float4(0.0, i1.z, i2.z, 1.0))
            + ii.y + float4(0.0, i1.y, i2.y, 1.0)
        )
        + ii.x + float4(0.0, i1.x, i2.x, 1.0)
    );

    float  n_  = 0.14285714285714285;
    float3 ns  = n_ * float3(D.w, D.y, D.z) - float3(D.x, D.z, D.x);

    float4 j  = p - 49.0 * floor(p * ns.z * ns.z);
    float4 x_ = floor(j * ns.z);
    float4 y_ = floor(j - 7.0 * x_);

    float4 gx = x_ * ns.x + ns.y;
    float4 gy = y_ * ns.x + ns.y;
    float4 h  = 1.0 - abs(gx) - abs(gy);

    float4 b0 = float4(gx.x, gx.y, gy.x, gy.y);
    float4 b1 = float4(gx.z, gx.w, gy.z, gy.w);

    float4 s0 = floor(b0) * 2.0 + 1.0;
    float4 s1 = floor(b1) * 2.0 + 1.0;
    float4 sh = -step(h, (float4)0.0);

    float4 a0 = float4(b0.x, b0.z, b0.y, b0.w)
        + float4(s0.x, s0.z, s0.y, s0.w) * float4(sh.x, sh.x, sh.y, sh.y);
    float4 a1 = float4(b1.x, b1.z, b1.y, b1.w)
        + float4(s1.x, s1.z, s1.y, s1.w) * float4(sh.z, sh.z, sh.w, sh.w);

    float3 g0 = float3(a0.x, a0.y, h.x);
    float3 g1 = float3(a0.z, a0.w, h.y);
    float3 g2 = float3(a1.x, a1.y, h.z);
    float3 g3 = float3(a1.z, a1.w, h.w);

    float4 norm = crt_taylor_inv_sqrt(float4(
        dot(g0, g0),
        dot(g1, g1),
        dot(g2, g2),
        dot(g3, g3)
    ));

    float3 g0n = g0 * norm.x;
    float3 g1n = g1 * norm.y;
    float3 g2n = g2 * norm.z;
    float3 g3n = g3 * norm.w;

    float m0 = max(0.6 - dot(x0, x0), 0.0);
    float m1 = max(0.6 - dot(x1, x1), 0.0);
    float m2 = max(0.6 - dot(x2, x2), 0.0);
    float m3 = max(0.6 - dot(x3, x3), 0.0);

    float m0sq = m0 * m0;
    float m1sq = m1 * m1;
    float m2sq = m2 * m2;
    float m3sq = m3 * m3;

    return 42.0 * (
        m0sq * m0sq * dot(g0n, x0)
        + m1sq * m1sq * dot(g1n, x1)
        + m2sq * m2sq * dot(g2n, x2)
        + m3sq * m3sq * dot(g3n, x3)
    );
}

// ---- wrap_float (verbatim WGSL) --------------------------------------------
float crt_wrap_float(float value, float limit)
{
    if (limit <= 0.0)
        return 0.0;
    float result = value - floor(value / limit) * limit;
    if (result < 0.0)
        result = result + limit;
    return result;
}

// ---- singularity_mask (verbatim WGSL) --------------------------------------
float crt_singularity_mask(float2 uv, float width, float height)
{
    if (width <= 0.0 || height <= 0.0)
        return 0.0;

    float2 delta   = abs(uv - float2(0.5, 0.5));
    float  aspect  = width / height;
    float2 scaled  = float2(delta.x * aspect, delta.y);
    float  max_radius = length(float2(aspect * 0.5, 0.5));
    if (max_radius <= 0.0)
        return 0.0;

    float normalized = clamp(length(scaled) / max_radius, 0.0, 1.0);
    float masked     = sqrt(normalized);
    return pow(masked, 5.0);
}

// ---- animated_simplex_value (verbatim WGSL; seed passed explicitly) --------
float crt_animated_simplex_value(float2 uv, float t, float spd, float seed_f)
{
    float angle  = t * CRT_TAU;
    float z_base = cos(angle) * spd;
    float s      = seed_f * 73.0;
    float3 base_seed = float3(17.0 + s, 29.0 + s * 1.1, 47.0 + s * 0.7);
    float base_noise = crt_simplex_noise(float3(
        uv.x + base_seed.x,
        uv.y + base_seed.y,
        z_base + base_seed.z
    ));
    float value = clamp(base_noise * 0.5 + 0.5, 0.0, 1.0);

    [branch]
    if (spd != 0.0 && t != 0.0)
    {
        float3 time_seed = float3(
            base_seed.x + 54.0,
            base_seed.y + 82.0,
            base_seed.z + 124.0
        );
        float time_noise = crt_simplex_noise(float3(
            uv.x + time_seed.x,
            uv.y + time_seed.y,
            time_seed.z
        ));
        float time_value  = clamp(time_noise * 0.5 + 0.5, 0.0, 1.0);
        float scaled_time = crt_periodic_value(t, time_value) * spd;
        value = crt_clamp01(crt_periodic_value(scaled_time, value));
    }

    return crt_clamp01(value);
}

// ---- compute_lens_offsets (verbatim WGSL) ----------------------------------
float2 crt_compute_lens_offsets(
    float2 sample_pos,
    float  width,
    float  height,
    float2 freq,
    float  t,
    float  spd,
    float  displacement,
    float  seed_f)
{
    float width_safe  = max(width, 1.0);
    float height_safe = max(height, 1.0);
    float freq_x      = max(freq.y, 1.0);
    float freq_y      = max(freq.x, 1.0);

    float2 wrapped_pos = float2(
        crt_wrap_float(sample_pos.x, width_safe),
        crt_wrap_float(sample_pos.y, height_safe)
    );
    float2 uv = float2(
        (wrapped_pos.x / width_safe) * freq_x,
        (wrapped_pos.y / height_safe) * freq_y
    );

    float noise_value = crt_animated_simplex_value(uv, t, spd, seed_f);

    float2 uv_centered = (wrapped_pos + float2(0.5, 0.5)) / float2(width_safe, height_safe);
    float  mask        = crt_singularity_mask(uv_centered, width_safe, height_safe);
    float  distortion  = (noise_value * 2.0 - 1.0) * mask;
    float  angle       = distortion * CRT_TAU;

    float2 offsets = float2(cos(angle), sin(angle))
        * displacement * float2(width_safe, height_safe);
    return offsets;
}

// ---- Value noise helpers (verbatim WGSL) -----------------------------------

float crt_fade(float v)              { return v * v * (3.0 - 2.0 * v); }
float3 crt_fade_vec3(float3 v)       { return float3(crt_fade(v.x), crt_fade(v.y), crt_fade(v.z)); }
// Local lerp renamed to avoid conflict with HLSL built-in
float crt_lerp(float a, float b, float t) { return a + (b - a) * t; }

float crt_hash3(int3 coord, float sd)
{
    float3 base      = (float3)coord;
    float  dot_value = dot(base, float3(12.9898, 78.233, 37.719)) + sd * 0.001;
    return frac(sin(dot_value) * 43758.5453);
}

float crt_value_noise_3d(float3 coord, float sd)
{
    int3   cell     = (int3)floor(coord);
    float3 local_f  = frac(coord);
    float3 smooth_t = crt_fade_vec3(local_f);

    float c000 = crt_hash3(cell,                     sd);
    float c100 = crt_hash3(cell + int3(1, 0, 0),     sd);
    float c010 = crt_hash3(cell + int3(0, 1, 0),     sd);
    float c110 = crt_hash3(cell + int3(1, 1, 0),     sd);
    float c001 = crt_hash3(cell + int3(0, 0, 1),     sd);
    float c101 = crt_hash3(cell + int3(1, 0, 1),     sd);
    float c011 = crt_hash3(cell + int3(0, 1, 1),     sd);
    float c111 = crt_hash3(cell + int3(1, 1, 1),     sd);

    float x00 = crt_lerp(c000, c100, smooth_t.x);
    float x10 = crt_lerp(c010, c110, smooth_t.x);
    float x01 = crt_lerp(c001, c101, smooth_t.x);
    float x11 = crt_lerp(c011, c111, smooth_t.x);
    float y0   = crt_lerp(x00, x10, smooth_t.y);
    float y1   = crt_lerp(x01, x11, smooth_t.y);
    return crt_lerp(y0, y1, smooth_t.z);
}

// ---- compute_singularity (verbatim WGSL) -----------------------------------
float crt_compute_singularity(float x, float y, float width, float height)
{
    float center_x = width  * 0.5;
    float center_y = height * 0.5;
    float dx       = (x - center_x) / width;
    float dy       = (y - center_y) / height;
    return length(float2(dx, dy));
}

// ---- Color helpers (verbatim WGSL) -----------------------------------------

float crt_wrap_unit(float value)
{
    float wrapped = value - floor(value);
    if (wrapped < 0.0)
        wrapped = wrapped + 1.0;
    return wrapped;
}

float crt_blend_linear(float a, float b, float t)
{
    return lerp(a, b, clamp(t, 0.0, 1.0));
}

float crt_blend_cosine(float a, float b, float value)
{
    float clamped = clamp(value, 0.0, 1.0);
    float weight  = (1.0 - cos(clamped * CRT_PI)) * 0.5;
    return lerp(a, b, weight);
}

float3 crt_rgb_to_hsv(float3 rgb)
{
    float c_max  = max(max(rgb.x, rgb.y), rgb.z);
    float c_min  = min(min(rgb.x, rgb.y), rgb.z);
    float delta  = c_max - c_min;

    float hue = 0.0;
    if (delta > 0.0)
    {
        if (c_max == rgb.x)
        {
            float segment = (rgb.y - rgb.z) / delta;
            if (segment < 0.0)
                segment = segment + 6.0;
            hue = segment;
        }
        else if (c_max == rgb.y)
        {
            hue = ((rgb.z - rgb.x) / delta) + 2.0;
        }
        else
        {
            hue = ((rgb.x - rgb.y) / delta) + 4.0;
        }
        hue = crt_wrap_unit(hue / 6.0);
    }

    // WGSL: select(0.0, delta/c_max, c_max != 0.0)  — select(false_val,true_val,cond)
    float saturation = (c_max != 0.0) ? (delta / c_max) : 0.0;
    return float3(hue, saturation, c_max);
}

float3 crt_hsv_to_rgb(float3 hsv)
{
    float h = hsv.x;
    float s = hsv.y;
    float v = hsv.z;

    float dh     = h * 6.0;
    float r_comp = crt_clamp01(abs(dh - 3.0) - 1.0);
    float g_comp = crt_clamp01(-abs(dh - 2.0) + 2.0);
    float b_comp = crt_clamp01(-abs(dh - 4.0) + 2.0);

    float one_minus_s = 1.0 - s;
    float sr = s * r_comp;
    float sg = s * g_comp;
    float sb = s * b_comp;

    float r = crt_clamp01((one_minus_s + sr) * v);
    float g = crt_clamp01((one_minus_s + sg) * v);
    float b = crt_clamp01((one_minus_s + sb) * v);

    return float3(r, g, b);
}

float3 crt_adjust_hue(float3 color, float amount)
{
    float3 hsv = crt_rgb_to_hsv(color);
    hsv.x = crt_wrap_unit(hsv.x + amount);
    hsv.y = crt_clamp01(hsv.y);
    hsv.z = crt_clamp01(hsv.z);
    return clamp(crt_hsv_to_rgb(hsv), (float3)0.0, (float3)1.0);
}

float3 crt_adjust_saturation(float3 color, float amount)
{
    float3 hsv = crt_rgb_to_hsv(color);
    hsv.y = crt_clamp01(hsv.y * amount);
    hsv.z = crt_clamp01(hsv.z);
    return clamp(crt_hsv_to_rgb(hsv), (float3)0.0, (float3)1.0);
}

float crt_apply_vignette(float value, float brightness, float mask, float a)
{
    float edge_mix = lerp(value, brightness, mask);
    return lerp(value, edge_mix, clamp(a, 0.0, 1.0));
}

// ---- Scanline helpers (verbatim WGSL) --------------------------------------

float2 crt_get_scanline_base_values(float t, float spd, float seed_f)
{
    float time_scaled = t * spd * 0.1;
    float noise_seed  = 19.37 + seed_f * 31.0;
    float noise0 = crt_value_noise_3d(float3(0.0, 0.0, time_scaled), noise_seed);
    float noise1 = crt_value_noise_3d(float3(1.0, 0.0, time_scaled), noise_seed);
    return float2(noise0, noise1);
}

float crt_get_scanline_value_interpolated(float y, float height, float2 base_values)
{
    float pixels_per_bar  = 2.5;
    float y_scaled        = y / pixels_per_bar;
    int   scanline_index  = (int)floor(y_scaled) % 2;
    // WGSL: select(base_values.y, base_values.x, scanline_index == 0)
    //        = select(false_val, true_val, cond) -> (cond ? true_val : false_val)
    return (scanline_index == 0) ? base_values.x : base_values.y;
}

float crt_sample_scanline_bilinear(
    float sample_x, float sample_y,
    float width, float height,
    float2 base_values)
{
    float wrapped_x = sample_x - floor(sample_x / width)  * width;
    float wrapped_y = sample_y - floor(sample_y / height) * height;

    if (wrapped_x < 0.0) wrapped_x = wrapped_x + width;
    if (wrapped_y < 0.0) wrapped_y = wrapped_y + height;

    wrapped_x = clamp(wrapped_x, 0.0, width  - 1.0);
    wrapped_y = clamp(wrapped_y, 0.0, height - 1.0);

    float x0     = floor(wrapped_x);
    float y0     = floor(wrapped_y);
    float x1     = min(x0 + 1.0, width  - 1.0);
    float y1     = min(y0 + 1.0, height - 1.0);

    float x_fract = clamp(wrapped_x - x0, 0.0, 1.0);
    float y_fract = clamp(wrapped_y - y0, 0.0, 1.0);

    float val_x0_y0 = crt_get_scanline_value_interpolated(y0, height, base_values);
    float val_x1_y0 = crt_get_scanline_value_interpolated(y0, height, base_values);
    float val_x0_y1 = crt_get_scanline_value_interpolated(y1, height, base_values);
    float val_x1_y1 = crt_get_scanline_value_interpolated(y1, height, base_values);

    float val_y0 = lerp(val_x0_y0, val_x1_y0, x_fract);
    float val_y1 = lerp(val_x0_y1, val_x1_y1, x_fract);

    return lerp(val_y0, val_y1, y_fract);
}

// =============================================================================
// NMFrag_crt — main fragment program.
//
// WGSL worked in plain integer pixel-space (gid.x/gid.y).
// Here x,y are derived from NM_FragCoord(i) which gives the same +0.5 centered
// pixel coords. We truncate to integer for texLoad ops via (int) cast.
//
// The GLSL introduces tileOffset/renderScale so chromatic aberration lookups
// map correctly across tiles. We replicate that transform:
//   red_sample_local_x  = red_sample_x * renderScale - tileOffset.x
//   blue_sample_local_x = blue_sample_x * renderScale - tileOffset.x
// TODO(verify): parity-test tiled renders (tileOffset != 0).
// =============================================================================
float4 NMFrag_crt(NMVaryings i) : SV_Target
{
    uint texW, texH;
    inputTex.GetDimensions(texW, texH);

    float alphaVal = clamp(alpha, 0.0, 1.0);

    // Pixel coords. The canonical WGSL is a COMPUTE shader using integer pixel
    // indices: `let x = f32(gid.x); let y = f32(gid.y);` — i.e. 0.0, 1.0, 2.0 …
    // with NO +0.5 pixel-center bias. The render-path GLSL mirrors this by
    // truncating gl_FragCoord first: `global_id = uvec3(uint(gl_FragCoord.x),
    // uint(gl_FragCoord.y), 0u)` and then using float(global_id.x). NM_FragCoord
    // here is pixel-CENTERED (+0.5), so we must truncate to integer before
    // deriving x/y (and the texel index) to match the reference exactly.
    float2 fragCoord = NM_FragCoord(i);
    int    ix        = (int)fragCoord.x;
    int    iy        = (int)fragCoord.y;

    float4 passthrough = inputTex.Load(int3(ix, iy, 0));

    [branch]
    if (alphaVal == 0.0)
        return passthrough;

    // GLSL: width_f/height_f from fullResolution / renderScale
    float rs       = max(renderScale, 1.0);
    float2 fullRes = (fullResolution.x > 0.0) ? fullResolution : resolution;
    float width_f  = max(fullRes.x / rs, 1.0);
    float height_f = max(fullRes.y / rs, 1.0);

    float seed_f = (float)seed;

    // GLSL: x/y = (float(global_id) + tileOffset) / renderScale, where
    // global_id = uvec3(uint(gl_FragCoord.xy)) — the TRUNCATED integer coord.
    // Use ix/iy (the truncated coords), NOT the +0.5-centered fragCoord, so the
    // scanline parity (floor(y/2.5)%2), lens warp, singularity, gradient and
    // aberration sample positions match the WGSL/GLSL integer-pixel reference.
    float x = ((float)ix + tileOffset.x) / rs;
    float y = ((float)iy + tileOffset.y) / rs;

    float  displacement = 0.0625;
    float2 freq         = (float2)0.0;
    {
        // freq_for_shape(2.0, width_f, height_f) — verbatim WGSL
        float base_freq   = max(2.0, 1.0);
        float width_safe  = max(width_f, 1.0);
        float height_safe = max(height_f, 1.0);
        if (abs(width_safe - height_safe) < 1e-5)
        {
            freq = float2(base_freq, base_freq);
        }
        else if (height_safe < width_safe)
        {
            float scaled = floor(base_freq * width_safe / height_safe);
            freq = float2(base_freq, max(scaled, 1.0));
        }
        else
        {
            float scaled = floor(base_freq * height_safe / width_safe);
            freq = float2(max(scaled, 1.0), base_freq);
        }
    }

    float2 base_offsets = crt_compute_lens_offsets(
        float2(x, y), width_f, height_f, freq, time, speed, displacement, seed_f);

    float2 scanline_base = crt_get_scanline_base_values(time, speed, seed_f);
    float  scan_value    = crt_sample_scanline_bilinear(
        x + base_offsets.x, y + base_offsets.y,
        width_f, height_f, scanline_base);

    // Sample input at original (unwarped) pixel
    float4 base_sample = inputTex.Load(int3(ix, iy, 0));
    float3 base_color  = base_sample.xyz;

    // Step 4: scanline blend
    float3 color = lerp(
        base_color,
        (base_color + scan_value) * scan_value,
        0.5
    );
    color = clamp(color, (float3)0.0, (float3)1.0);

    // Step 5: Chromatic aberration, hue shift, saturation, vignette
    // (channels >= 2.5 always true for RGBA; condition kept verbatim)
    // if (params.size.z >= 2.5) — always true; run unconditionally
    {
        float seed_base         = 17.0 + seed_f * 73.0;
        float displacement_base = 0.0125 + crt_random_scalar(seed_base + 0.37) * 0.00625;
        float simplex_val       = crt_random_scalar(seed_base + 0.73);
        float displacement_pixels = displacement_base * width_f * simplex_val;

        float singularity = crt_compute_singularity(x, y, width_f, height_f);
        float aber_mask   = pow(singularity, 3.0);
        float gradient    = clamp(x / (width_f - 1.0), 0.0, 1.0);

        float hue_shift = crt_random_scalar(seed_base + 1.91) * 0.25 - 0.125;

        // Red channel aberration (shift right)
        float red_x        = min(x + displacement_pixels, width_f - 1.0);
        red_x              = crt_blend_linear(red_x, x, gradient);
        float red_sample_x = crt_blend_cosine(x, red_x, aber_mask);

        // GLSL tileOffset/renderScale remapping for local texture coord
        float red_sample_global_x = red_sample_x * rs;
        float red_sample_local_x  = red_sample_global_x - tileOffset.x;
        float3 red_base_col = inputTex.Load(int3((int)red_sample_local_x, iy, 0)).xyz;

        float2 red_offsets = crt_compute_lens_offsets(
            float2(red_sample_x, y), width_f, height_f, freq, time, speed, displacement, seed_f);
        float red_scan_val = crt_sample_scanline_bilinear(
            red_sample_x + red_offsets.x, y + red_offsets.y,
            width_f, height_f, scanline_base);
        float3 red_blended = lerp(red_base_col, (red_base_col + red_scan_val) * red_scan_val, 0.5);

        // Green channel = current pixel color (no extra sample)
        float3 green_blended = color;

        // Blue channel aberration (shift left)
        float blue_x        = max(x - displacement_pixels, 0.0);
        blue_x              = crt_blend_linear(x, blue_x, gradient);
        float blue_sample_x = crt_blend_cosine(x, blue_x, aber_mask);

        float blue_sample_global_x = blue_sample_x * rs;
        float blue_sample_local_x  = blue_sample_global_x - tileOffset.x;
        float3 blue_base_col = inputTex.Load(int3((int)blue_sample_local_x, iy, 0)).xyz;

        float2 blue_offsets = crt_compute_lens_offsets(
            float2(blue_sample_x, y), width_f, height_f, freq, time, speed, displacement, seed_f);
        float blue_scan_val = crt_sample_scanline_bilinear(
            blue_sample_x + blue_offsets.x, y + blue_offsets.y,
            width_f, height_f, scanline_base);
        float3 blue_blended = lerp(blue_base_col, (blue_base_col + blue_scan_val) * blue_scan_val, 0.5);

        // Combine channels with per-channel hue shift then restore
        color = float3(
            crt_adjust_hue(red_blended,   hue_shift).r,
            crt_adjust_hue(green_blended, hue_shift).g,
            crt_adjust_hue(blue_blended,  hue_shift).b
        );
        color = crt_adjust_hue(color, -hue_shift);

        // Step 6: Saturation boost
        color = crt_adjust_saturation(color, 1.125);

        // Step 7: Vignette
        float vignette_alpha = crt_random_scalar(seed_base + 3.17) * 0.175;
        float vignette_mask  = singularity;
        color.x = crt_apply_vignette(color.x, 0.0, vignette_mask, vignette_alpha);
        color.y = crt_apply_vignette(color.y, 0.0, vignette_mask, vignette_alpha);
        color.z = crt_apply_vignette(color.z, 0.0, vignette_mask, vignette_alpha);
    }

    // Step 8: Contrast normalization around local mean
    float local_mean = (color.x + color.y + color.z) * CRT_INV_THREE;
    color = clamp((color - local_mean) * 1.25 + local_mean, (float3)0.0, (float3)1.0);

    // Final alpha-blend with original
    color = lerp(base_color, color, alphaVal);
    return float4(color, base_sample.w);
}

#endif // NM_EFFECT_CRT_INCLUDED
