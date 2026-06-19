#ifndef NM_DEGAUSS_INCLUDED
#define NM_DEGAUSS_INCLUDED

// =============================================================================
// Degauss.hlsl — filter/degauss, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/degauss/wgsl/degauss.wgsl
//
// CRT degauss effect: per-channel lens-warp driven by simplex noise, with a
// singularity mask (strongest at edges, zero at center) and directional rotation.
//
// PORTING NOTES:
//  * Source is a WGSL COMPUTE shader (no sampler, textureLoad only). Ported to a
//    fragment shader: gid.xy maps to floor(NM_FragCoord(i)), i.e. integer pixel
//    coords. sample_bilinear uses Texture2D.Load (integer texel fetch), not Sample.
//  * Named uniforms match definition.js globals[*].uniform exactly:
//      float displacement, float direction, int seed, float speed
//  * time comes from NMFullscreen's `time` alias.
//  * width/height come from the actual input texture dimensions (inputTex.GetDimensions),
//    matching WGSL's use of params.dims0.x/y — NOT fullResolution.
//  * WGSL seed: f32(i32(params.dims1.y)) * 73.0 — seed is declared int, cast to
//    float with (float)seed, matching the i32→f32 path.
//  * All helpers ported verbatim (simplex_noise, freq_for_shape, etc. are effect-
//    specific — not from NMCore).
//  * No nm_mod used here (no float modulo in the effect logic).
//  * TAU is a compile-time constant matching the WGSL literal.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// Per-effect named uniforms (definition.js globals[*].uniform)
float displacement;
float direction;
int   seed;
float speed;

// Input texture (integer texel-load only; no sampler needed for the effect math)
Texture2D inputTex;

// =============================================================================
// Constants
// =============================================================================


// =============================================================================
// Verbatim helpers from the WGSL
// =============================================================================

float nm_clamp01(float value)
{
    return clamp(value, 0.0, 1.0);
}

int nm_wrap_index(int value, int limit)
{
    if (limit <= 0) return 0;
    int wrapped = value % limit;
    if (wrapped < 0) wrapped = wrapped + limit;
    return wrapped;
}

float nm_wrap_float(float value, float limit)
{
    if (limit <= 0.0) return 0.0;
    float result = value - floor(value / limit) * limit;
    if (result < 0.0) result = result + limit;
    return result;
}

float2 nm_freq_for_shape(float base_freq, float width, float height)
{
    if (base_freq <= 0.0) return float2(1.0, 1.0);
    if (abs(width - height) < 1e-5) return float2(base_freq, base_freq);
    if (height < width && height > 0.0)
        return float2(base_freq, base_freq * width / height);
    if (width > 0.0)
        return float2(base_freq * height / width, base_freq);
    return float2(base_freq, base_freq);
}

float nm_normalized_sine(float value)
{
    return sin(value) * 0.5 + 0.5;
}

float nm_periodic_value(float t, float value)
{
    return nm_normalized_sine((t - value) * NM_TAU);
}

// --- Simplex noise helpers ---

float3 nm_mod289_vec3(float3 x)
{
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

float4 nm_mod289_vec4(float4 x)
{
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

float4 nm_permute(float4 x)
{
    return nm_mod289_vec4(((x * 34.0) + 1.0) * x);
}

float4 nm_taylor_inv_sqrt(float4 r)
{
    return 1.79284291400159 - 0.85373472095314 * r;
}

float nm_simplex_noise(float3 v)
{
    float2 C = float2(1.0 / 6.0, 1.0 / 3.0);
    float4 D = float4(0.0, 0.5, 1.0, 2.0);

    float3 i0 = floor(v + dot(v, (float3)C.y));
    float3 x0 = v - i0 + dot(i0, (float3)C.x);

    float3 step1 = step(float3(x0.y, x0.z, x0.x), x0);
    float3 l = (float3)1.0 - step1;
    float3 i1 = min(step1, float3(l.z, l.x, l.y));
    float3 i2 = max(step1, float3(l.z, l.x, l.y));

    float3 x1 = x0 - i1 + (float3)C.x;
    float3 x2 = x0 - i2 + (float3)C.y;
    float3 x3 = x0 - (float3)D.y;

    float3 i = nm_mod289_vec3(i0);
    float4 p = nm_permute(nm_permute(nm_permute(
        i.z + float4(0.0, i1.z, i2.z, 1.0))
        + i.y + float4(0.0, i1.y, i2.y, 1.0))
        + i.x + float4(0.0, i1.x, i2.x, 1.0));

    float  n_  = 0.14285714285714285;
    float3 ns  = n_ * float3(D.w, D.y, D.z) - float3(D.x, D.z, D.x);

    float4 j  = p - 49.0 * floor(p * ns.z * ns.z);
    float4 x_ = floor(j * ns.z);
    float4 y_ = floor(j - 7.0 * x_);

    float4 x = x_ * ns.x + ns.y;
    float4 y = y_ * ns.x + ns.y;
    float4 h = 1.0 - abs(x) - abs(y);

    float4 b0 = float4(x.x, x.y, y.x, y.y);
    float4 b1 = float4(x.z, x.w, y.z, y.w);

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

    float4 norm = nm_taylor_inv_sqrt(float4(
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

// --- Noise value for a single channel ---
// WGSL: seed_offset = f32(i32(params.dims1.y)) * 73.0  — int uniform cast to float.

float nm_compute_noise_value(
    uint2 coord,
    float width,
    float height,
    float2 freq,
    float t,
    float spd,
    uint channel)
{
    float width_safe  = max(width,  1.0);
    float height_safe = max(height, 1.0);
    float freq_x = max(freq.y, 1.0);
    float freq_y = max(freq.x, 1.0);

    float2 uv = float2(
        ((float)coord.x / width_safe)  * freq_x,
        ((float)coord.y / height_safe) * freq_y
    );

    float angle = t * NM_TAU;
    float z_base = cos(angle) * spd;
    float channel_offset = (float)channel * 37.0;
    float seed_offset    = (float)(int)seed * 73.0;  // WGSL: f32(i32(params.dims1.y))
    float3 base_seed = float3(
        17.0 + channel_offset + seed_offset,
        29.0 + channel_offset * 1.3 + seed_offset * 1.1,
        47.0 + channel_offset * 1.7 + seed_offset * 0.7
    );

    float base_noise = nm_simplex_noise(float3(
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
        float time_noise = nm_simplex_noise(float3(
            uv.x + time_seed.x,
            uv.y + time_seed.y,
            time_seed.z
        ));
        float time_value  = clamp(time_noise * 0.5 + 0.5, 0.0, 1.0);
        float scaled_time = nm_periodic_value(t, time_value) * spd;
        value = nm_clamp01(nm_periodic_value(scaled_time, value));
    }

    return nm_clamp01(value);
}

// --- Singularity mask (strongest at corners, zero at centre) ---

float nm_singularity_mask(float2 uv, float width, float height)
{
    if (width <= 0.0 || height <= 0.0) return 0.0;

    float2 delta  = abs(uv - float2(0.5, 0.5));
    float  aspect = width / height;
    float2 scaled = float2(delta.x * aspect, delta.y);
    float  max_radius = length(float2(aspect * 0.5, 0.5));
    if (max_radius <= 0.0) return 0.0;

    float normalized = clamp(length(scaled) / max_radius, 0.0, 1.0);
    float masked = sqrt(normalized);
    return pow(masked, 5.0);
}

// --- Manual bilinear sample using integer texel loads (mirrors WGSL textureLoad) ---
// TODO(verify): inputTex.Load(int3(x,y,0)) is the HLSL exact analog of WGSL
// textureLoad(inputTex, vec2<i32>(x,y), 0). Confirm sampler is not involved.

float4 nm_sample_bilinear(float2 pos, float width, float height)
{
    float width_f  = max(width,  1.0);
    float height_f = max(height, 1.0);

    float wrapped_x = nm_wrap_float(pos.x, width_f);
    float wrapped_y = nm_wrap_float(pos.y, height_f);

    int x0 = (int)floor(wrapped_x);
    int y0 = (int)floor(wrapped_y);

    int width_i  = (int)max(width,  1.0);
    int height_i = (int)max(height, 1.0);

    if (x0 < 0) x0 = 0;
    else if (x0 >= width_i) x0 = width_i - 1;

    if (y0 < 0) y0 = 0;
    else if (y0 >= height_i) y0 = height_i - 1;

    int x1 = nm_wrap_index(x0 + 1, width_i);
    int y1 = nm_wrap_index(y0 + 1, height_i);

    float fx = clamp(wrapped_x - (float)x0, 0.0, 1.0);
    float fy = clamp(wrapped_y - (float)y0, 0.0, 1.0);

    float4 tex00 = inputTex.Load(int3(x0, y0, 0));
    float4 tex10 = inputTex.Load(int3(x1, y0, 0));
    float4 tex01 = inputTex.Load(int3(x0, y1, 0));
    float4 tex11 = inputTex.Load(int3(x1, y1, 0));

    float4 mix_x0 = lerp(tex00, tex10, (float4)fx);
    float4 mix_x1 = lerp(tex01, tex11, (float4)fx);
    return lerp(mix_x0, mix_x1, (float4)fy);
}

// --- Per-channel warp ---

float nm_warped_channel_value(
    uint   channel,
    uint2  coord,
    float2 base_pos,
    float  width,
    float  height,
    float2 freq,
    float  disp,
    float  mask,
    float  t,
    float  spd)
{
    float noise_value = nm_compute_noise_value(coord, width, height, freq, t, spd, channel);
    float centered    = (noise_value * 2.0 - 1.0) * mask;
    float angle       = centered * NM_TAU;
    float2 offset     = float2(cos(angle), sin(angle)) * disp * float2(width, height);

    // Rotate offset by direction (WGSL: dirRad = params.dims1.z * TAU / 360.0)
    float dirRad = direction * NM_TAU / 360.0;
    float dc = cos(dirRad);
    float ds = sin(dirRad);
    offset = float2(offset.x * dc - offset.y * ds, offset.x * ds + offset.y * dc);

    float4 s = nm_sample_bilinear(base_pos + offset, width, height);

    if (channel == 0u) return nm_clamp01(s.x);
    if (channel == 1u) return nm_clamp01(s.y);
    return nm_clamp01(s.z);
}

// =============================================================================
// nm_degauss — full per-pixel evaluation.
// pixel: integer pixel coordinate (floor of fragCoord), matching WGSL gid.xy.
// width/height: input texture dimensions.
// =============================================================================

float4 nm_degauss(uint2 pixel, float width, float height)
{
    int3   icoord   = int3((int)pixel.x, (int)pixel.y, 0);
    float4 original = inputTex.Load(icoord);

    if (displacement == 0.0)
        return original;

    float width_f  = width;
    float height_f = height;
    float2 uv = (float2((float)pixel.x, (float)pixel.y) + float2(0.5, 0.5))
                / float2(max(width_f, 1.0), max(height_f, 1.0));

    float mask = nm_singularity_mask(uv, width_f, height_f);
    if (mask <= 0.0)
        return original;

    float2 freq     = nm_freq_for_shape(2.0, width_f, height_f);
    float2 base_pos = float2((float)pixel.x, (float)pixel.y);
    uint2  coord    = pixel;

    float red   = nm_warped_channel_value(0u, coord, base_pos, width_f, height_f, freq, displacement, mask, time, speed);
    float green = nm_warped_channel_value(1u, coord, base_pos, width_f, height_f, freq, displacement, mask, time, speed);
    float blue  = nm_warped_channel_value(2u, coord, base_pos, width_f, height_f, freq, displacement, mask, time, speed);
    float alpha = nm_clamp01(original.w);

    return float4(red, green, blue, alpha);
}

#endif // NM_DEGAUSS_INCLUDED
