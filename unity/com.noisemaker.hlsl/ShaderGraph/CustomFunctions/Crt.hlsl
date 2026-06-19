#ifndef NM_SG_CRT_INCLUDED
#define NM_SG_CRT_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for filter/crt.
//
// Exposes the CRT effect as a Shader Graph Custom Function node.
// Inputs map directly from definition.js globals:
//   Alpha (float, [0,1], default 0.5)
//   Speed (float, [0,5], default 1.0)
//   Seed  (float from int, [1,100], default 1)
//   InputTex / SS / UV — source surface
//   Resolution — render target size in pixels (float2)
//   FullResolution — full (untiled) size in pixels (float2)
//   TileOffset — per-tile pixel offset (float2, 0 if untiled)
//   RenderScale — tile render scale (float, 1.0 if untiled)
//   Time — normalized animation time (float)
//
// NOTE: This effect uses pixel-space integer texel loads (not UV sampling) and
// relies on tileOffset/renderScale for chromatic aberration coordinate mapping.
// In a Shader Graph context the caller MUST supply these engine values explicitly
// as node inputs. TODO(verify): validate tileOffset != 0 in SG context.
//
// Self-contained — does NOT include NMFullscreen.hlsl / NMCore.hlsl.
// All helpers prefixed `nmsg_crt_` to avoid symbol clashes.
// =============================================================================

static const float NMSG_CRT_PI        = 3.14159265358979323846;
static const float NMSG_CRT_TAU       = 6.28318530717958647692;
static const float NMSG_CRT_INV_THREE = 0.3333333333333333;

float nmsg_crt_clamp01(float v) { return clamp(v, 0.0, 1.0); }

float nmsg_crt_random_scalar(float s)
{
    return frac(sin(s) * 43758.5453123);
}

float nmsg_crt_normalized_sine(float v) { return sin(v) * 0.5 + 0.5; }

float nmsg_crt_periodic_value(float t, float v)
{
    return nmsg_crt_normalized_sine((t - v) * NMSG_CRT_TAU);
}

float3 nmsg_crt_mod289_vec3(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float4 nmsg_crt_mod289_vec4(float4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float4 nmsg_crt_permute(float4 x)     { return nmsg_crt_mod289_vec4(((x * 34.0) + 1.0) * x); }
float4 nmsg_crt_taylor_inv_sqrt(float4 r) { return 1.79284291400159 - 0.85373472095314 * r; }

float nmsg_crt_simplex_noise(float3 v)
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
    float3 ii = nmsg_crt_mod289_vec3(i0);
    float4 p = nmsg_crt_permute(
        nmsg_crt_permute(
            nmsg_crt_permute(ii.z + float4(0.0, i1.z, i2.z, 1.0))
            + ii.y + float4(0.0, i1.y, i2.y, 1.0)
        ) + ii.x + float4(0.0, i1.x, i2.x, 1.0));
    float n_ = 0.14285714285714285;
    float3 ns = n_ * float3(D.w, D.y, D.z) - float3(D.x, D.z, D.x);
    float4 j = p - 49.0 * floor(p * ns.z * ns.z);
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
    float4 a0 = float4(b0.x, b0.z, b0.y, b0.w) + float4(s0.x, s0.z, s0.y, s0.w) * float4(sh.x, sh.x, sh.y, sh.y);
    float4 a1 = float4(b1.x, b1.z, b1.y, b1.w) + float4(s1.x, s1.z, s1.y, s1.w) * float4(sh.z, sh.z, sh.w, sh.w);
    float3 g0 = float3(a0.x, a0.y, h.x);
    float3 g1 = float3(a0.z, a0.w, h.y);
    float3 g2 = float3(a1.x, a1.y, h.z);
    float3 g3 = float3(a1.z, a1.w, h.w);
    float4 norm = nmsg_crt_taylor_inv_sqrt(float4(dot(g0,g0),dot(g1,g1),dot(g2,g2),dot(g3,g3)));
    float3 g0n = g0*norm.x; float3 g1n = g1*norm.y;
    float3 g2n = g2*norm.z; float3 g3n = g3*norm.w;
    float m0 = max(0.6 - dot(x0,x0), 0.0); float m1 = max(0.6 - dot(x1,x1), 0.0);
    float m2 = max(0.6 - dot(x2,x2), 0.0); float m3 = max(0.6 - dot(x3,x3), 0.0);
    float m0sq = m0*m0; float m1sq = m1*m1; float m2sq = m2*m2; float m3sq = m3*m3;
    return 42.0*(m0sq*m0sq*dot(g0n,x0)+m1sq*m1sq*dot(g1n,x1)+m2sq*m2sq*dot(g2n,x2)+m3sq*m3sq*dot(g3n,x3));
}

float nmsg_crt_wrap_float(float value, float limit)
{
    if (limit <= 0.0) return 0.0;
    float result = value - floor(value / limit) * limit;
    if (result < 0.0) result = result + limit;
    return result;
}

float nmsg_crt_singularity_mask(float2 uv, float width, float height)
{
    if (width <= 0.0 || height <= 0.0) return 0.0;
    float2 delta = abs(uv - float2(0.5, 0.5));
    float aspect = width / height;
    float2 scaled = float2(delta.x * aspect, delta.y);
    float max_radius = length(float2(aspect * 0.5, 0.5));
    if (max_radius <= 0.0) return 0.0;
    float normalized = clamp(length(scaled) / max_radius, 0.0, 1.0);
    return pow(sqrt(normalized), 5.0);
}

float nmsg_crt_animated_simplex_value(float2 uv, float t, float spd, float seed_f)
{
    float angle = t * NMSG_CRT_TAU;
    float z_base = cos(angle) * spd;
    float s = seed_f * 73.0;
    float3 base_seed = float3(17.0 + s, 29.0 + s * 1.1, 47.0 + s * 0.7);
    float base_noise = nmsg_crt_simplex_noise(float3(uv.x + base_seed.x, uv.y + base_seed.y, z_base + base_seed.z));
    float value = clamp(base_noise * 0.5 + 0.5, 0.0, 1.0);
    [branch]
    if (spd != 0.0 && t != 0.0)
    {
        float3 time_seed = float3(base_seed.x + 54.0, base_seed.y + 82.0, base_seed.z + 124.0);
        float time_noise = nmsg_crt_simplex_noise(float3(uv.x + time_seed.x, uv.y + time_seed.y, time_seed.z));
        float time_value = clamp(time_noise * 0.5 + 0.5, 0.0, 1.0);
        float scaled_time = nmsg_crt_periodic_value(t, time_value) * spd;
        value = nmsg_crt_clamp01(nmsg_crt_periodic_value(scaled_time, value));
    }
    return nmsg_crt_clamp01(value);
}

float2 nmsg_crt_compute_lens_offsets(float2 sample_pos, float width, float height, float2 freq, float t, float spd, float displacement, float seed_f)
{
    float width_safe = max(width, 1.0); float height_safe = max(height, 1.0);
    float freq_x = max(freq.y, 1.0);   float freq_y = max(freq.x, 1.0);
    float2 wrapped_pos = float2(nmsg_crt_wrap_float(sample_pos.x, width_safe), nmsg_crt_wrap_float(sample_pos.y, height_safe));
    float2 uv = float2((wrapped_pos.x / width_safe) * freq_x, (wrapped_pos.y / height_safe) * freq_y);
    float noise_value = nmsg_crt_animated_simplex_value(uv, t, spd, seed_f);
    float2 uv_centered = (wrapped_pos + float2(0.5, 0.5)) / float2(width_safe, height_safe);
    float mask = nmsg_crt_singularity_mask(uv_centered, width_safe, height_safe);
    float distortion = (noise_value * 2.0 - 1.0) * mask;
    float angle = distortion * NMSG_CRT_TAU;
    return float2(cos(angle), sin(angle)) * displacement * float2(width_safe, height_safe);
}

float nmsg_crt_fade(float v) { return v * v * (3.0 - 2.0 * v); }
float3 nmsg_crt_fade_vec3(float3 v) { return float3(nmsg_crt_fade(v.x), nmsg_crt_fade(v.y), nmsg_crt_fade(v.z)); }
float nmsg_crt_lerp(float a, float b, float t) { return a + (b - a) * t; }

float nmsg_crt_hash3(int3 coord, float sd)
{
    float3 base = (float3)coord;
    float dot_value = dot(base, float3(12.9898, 78.233, 37.719)) + sd * 0.001;
    return frac(sin(dot_value) * 43758.5453);
}

float nmsg_crt_value_noise_3d(float3 coord, float sd)
{
    int3 cell = (int3)floor(coord);
    float3 local_f = frac(coord);
    float3 smooth_t = nmsg_crt_fade_vec3(local_f);
    float c000 = nmsg_crt_hash3(cell, sd);
    float c100 = nmsg_crt_hash3(cell + int3(1,0,0), sd);
    float c010 = nmsg_crt_hash3(cell + int3(0,1,0), sd);
    float c110 = nmsg_crt_hash3(cell + int3(1,1,0), sd);
    float c001 = nmsg_crt_hash3(cell + int3(0,0,1), sd);
    float c101 = nmsg_crt_hash3(cell + int3(1,0,1), sd);
    float c011 = nmsg_crt_hash3(cell + int3(0,1,1), sd);
    float c111 = nmsg_crt_hash3(cell + int3(1,1,1), sd);
    float x00 = nmsg_crt_lerp(c000, c100, smooth_t.x); float x10 = nmsg_crt_lerp(c010, c110, smooth_t.x);
    float x01 = nmsg_crt_lerp(c001, c101, smooth_t.x); float x11 = nmsg_crt_lerp(c011, c111, smooth_t.x);
    float y0 = nmsg_crt_lerp(x00, x10, smooth_t.y);    float y1 = nmsg_crt_lerp(x01, x11, smooth_t.y);
    return nmsg_crt_lerp(y0, y1, smooth_t.z);
}

float nmsg_crt_compute_singularity(float x, float y, float width, float height)
{
    float dx = (x - width  * 0.5) / width;
    float dy = (y - height * 0.5) / height;
    return length(float2(dx, dy));
}

float nmsg_crt_wrap_unit(float value)
{
    float wrapped = value - floor(value);
    if (wrapped < 0.0) wrapped = wrapped + 1.0;
    return wrapped;
}

float nmsg_crt_blend_linear(float a, float b, float t) { return lerp(a, b, clamp(t, 0.0, 1.0)); }
float nmsg_crt_blend_cosine(float a, float b, float value)
{
    float clamped = clamp(value, 0.0, 1.0);
    float weight  = (1.0 - cos(clamped * NMSG_CRT_PI)) * 0.5;
    return lerp(a, b, weight);
}

float3 nmsg_crt_rgb_to_hsv(float3 rgb)
{
    float c_max = max(max(rgb.x, rgb.y), rgb.z);
    float c_min = min(min(rgb.x, rgb.y), rgb.z);
    float delta = c_max - c_min;
    float hue = 0.0;
    if (delta > 0.0)
    {
        if (c_max == rgb.x) { float seg = (rgb.y - rgb.z) / delta; if (seg < 0.0) seg += 6.0; hue = seg; }
        else if (c_max == rgb.y) { hue = ((rgb.z - rgb.x) / delta) + 2.0; }
        else { hue = ((rgb.x - rgb.y) / delta) + 4.0; }
        hue = nmsg_crt_wrap_unit(hue / 6.0);
    }
    float saturation = (c_max != 0.0) ? (delta / c_max) : 0.0;
    return float3(hue, saturation, c_max);
}

float3 nmsg_crt_hsv_to_rgb(float3 hsv)
{
    float h = hsv.x; float s = hsv.y; float v = hsv.z;
    float dh = h * 6.0;
    float r_comp = nmsg_crt_clamp01(abs(dh - 3.0) - 1.0);
    float g_comp = nmsg_crt_clamp01(-abs(dh - 2.0) + 2.0);
    float b_comp = nmsg_crt_clamp01(-abs(dh - 4.0) + 2.0);
    float oms = 1.0 - s;
    return float3(nmsg_crt_clamp01((oms + s*r_comp)*v), nmsg_crt_clamp01((oms + s*g_comp)*v), nmsg_crt_clamp01((oms + s*b_comp)*v));
}

float3 nmsg_crt_adjust_hue(float3 color, float amount)
{
    float3 hsv = nmsg_crt_rgb_to_hsv(color);
    hsv.x = nmsg_crt_wrap_unit(hsv.x + amount);
    hsv.y = nmsg_crt_clamp01(hsv.y); hsv.z = nmsg_crt_clamp01(hsv.z);
    return clamp(nmsg_crt_hsv_to_rgb(hsv), (float3)0.0, (float3)1.0);
}

float3 nmsg_crt_adjust_saturation(float3 color, float amount)
{
    float3 hsv = nmsg_crt_rgb_to_hsv(color);
    hsv.y = nmsg_crt_clamp01(hsv.y * amount); hsv.z = nmsg_crt_clamp01(hsv.z);
    return clamp(nmsg_crt_hsv_to_rgb(hsv), (float3)0.0, (float3)1.0);
}

float nmsg_crt_apply_vignette(float value, float brightness, float mask, float a)
{
    float edge_mix = lerp(value, brightness, mask);
    return lerp(value, edge_mix, clamp(a, 0.0, 1.0));
}

float2 nmsg_crt_get_scanline_base_values(float t, float spd, float seed_f)
{
    float time_scaled = t * spd * 0.1;
    float noise_seed  = 19.37 + seed_f * 31.0;
    float noise0 = nmsg_crt_value_noise_3d(float3(0.0, 0.0, time_scaled), noise_seed);
    float noise1 = nmsg_crt_value_noise_3d(float3(1.0, 0.0, time_scaled), noise_seed);
    return float2(noise0, noise1);
}

float nmsg_crt_get_scanline_value_interpolated(float y, float2 base_values)
{
    float pixels_per_bar = 2.5;
    int   scanline_index = (int)floor(y / pixels_per_bar) % 2;
    return (scanline_index == 0) ? base_values.x : base_values.y;
}

float nmsg_crt_sample_scanline_bilinear(float sample_x, float sample_y, float width, float height, float2 base_values)
{
    float wx = sample_x - floor(sample_x / width)  * width;
    float wy = sample_y - floor(sample_y / height) * height;
    if (wx < 0.0) wx += width; if (wy < 0.0) wy += height;
    wx = clamp(wx, 0.0, width - 1.0); wy = clamp(wy, 0.0, height - 1.0);
    float x0 = floor(wx); float y0 = floor(wy);
    float x1 = min(x0 + 1.0, width - 1.0); float y1 = min(y0 + 1.0, height - 1.0);
    float xf = clamp(wx - x0, 0.0, 1.0);   float yf = clamp(wy - y0, 0.0, 1.0);
    float v00 = nmsg_crt_get_scanline_value_interpolated(y0, base_values);
    float v10 = nmsg_crt_get_scanline_value_interpolated(y0, base_values);
    float v01 = nmsg_crt_get_scanline_value_interpolated(y1, base_values);
    float v11 = nmsg_crt_get_scanline_value_interpolated(y1, base_values);
    return lerp(lerp(v00, v10, xf), lerp(v01, v11, xf), yf);
}

// =============================================================================
// NM_Crt_float — Shader Graph Custom Function entry point.
//
// Parameters:
//   InputTex      — source texture (UnityTexture2D)
//   SS            — sampler state (UnitySamplerState), must be linear/clamp
//   UV            — 0..1 UV for the current pixel
//   Resolution    — render target pixel size (float2)
//   FullResolution — full (untiled) pixel size (float2); pass Resolution if untiled
//   TileOffset    — per-tile pixel offset (float2); pass (0,0) if untiled
//   RenderScale   — tile render scale (float); pass 1.0 if untiled
//   Time          — normalized animation time (float)
//   Alpha         — blend [0,1], default 0.5
//   Speed         — animation speed [0,5], default 1.0
//   Seed          — seed [1,100], default 1 (pass as float)
//   Out           — output RGBA
//
// TODO(verify): This wrapper uses SAMPLE_TEXTURE2D (UV-based) for side-channel
// red/blue aberration samples. The runtime shader uses integer Load() keyed on
// tileOffset/renderScale for correctness across tiled renders. If TileOffset != 0
// the SG path may diverge from the runtime path for aberration lookups.
// =============================================================================
void NM_Crt_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float2            Resolution,
    float2            FullResolution,
    float2            TileOffset,
    float             RenderScale,
    float             Time,
    float             Alpha,
    float             Speed,
    float             Seed,
    out float4        Out)
{
    float alphaVal = clamp(Alpha, 0.0, 1.0);

    float4 base_sample4 = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, UV);
    float3 base_color   = base_sample4.xyz;

    if (alphaVal == 0.0)
    {
        Out = base_sample4;
        return;
    }

    float rs        = max(RenderScale, 1.0);
    float2 fullRes  = (FullResolution.x > 0.0) ? FullResolution : Resolution;
    float width_f   = max(fullRes.x / rs, 1.0);
    float height_f  = max(fullRes.y / rs, 1.0);
    float seed_f    = Seed;

    // Pixel coords from UV (same derivation as NM_FragCoord + TileOffset / rs)
    float2 pixelCoord = UV * Resolution;
    float x = (pixelCoord.x + TileOffset.x) / rs;
    float y = (pixelCoord.y + TileOffset.y) / rs;

    // freq_for_shape(2.0, width_f, height_f)
    float2 freq;
    {
        float base_freq = max(2.0, 1.0);
        float ws = max(width_f, 1.0); float hs = max(height_f, 1.0);
        if (abs(ws - hs) < 1e-5) { freq = float2(base_freq, base_freq); }
        else if (hs < ws) { float sc = floor(base_freq * ws / hs); freq = float2(base_freq, max(sc, 1.0)); }
        else { float sc = floor(base_freq * hs / ws); freq = float2(max(sc, 1.0), base_freq); }
    }

    float displacement = 0.0625;
    float2 base_offsets = nmsg_crt_compute_lens_offsets(float2(x,y), width_f, height_f, freq, Time, Speed, displacement, seed_f);
    float2 scanline_base = nmsg_crt_get_scanline_base_values(Time, Speed, seed_f);
    float  scan_value = nmsg_crt_sample_scanline_bilinear(x + base_offsets.x, y + base_offsets.y, width_f, height_f, scanline_base);

    float3 color = lerp(base_color, (base_color + scan_value) * scan_value, 0.5);
    color = clamp(color, (float3)0.0, (float3)1.0);

    {
        float seed_base = 17.0 + seed_f * 73.0;
        float displacement_base = 0.0125 + nmsg_crt_random_scalar(seed_base + 0.37) * 0.00625;
        float simplex_val = nmsg_crt_random_scalar(seed_base + 0.73);
        float displacement_pixels = displacement_base * width_f * simplex_val;

        float singularity = nmsg_crt_compute_singularity(x, y, width_f, height_f);
        float aber_mask   = pow(singularity, 3.0);
        float gradient    = clamp(x / (width_f - 1.0), 0.0, 1.0);
        float hue_shift   = nmsg_crt_random_scalar(seed_base + 1.91) * 0.25 - 0.125;

        // Red channel
        float red_x = min(x + displacement_pixels, width_f - 1.0);
        red_x = nmsg_crt_blend_linear(red_x, x, gradient);
        float red_sample_x = nmsg_crt_blend_cosine(x, red_x, aber_mask);
        // TODO(verify): SG uses UV-based sample; runtime uses integer Load with tileOffset
        float2 red_uv = float2((red_sample_x * rs - TileOffset.x) / Resolution.x, UV.y);
        float3 red_base_col = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, red_uv).xyz;
        float2 red_offsets = nmsg_crt_compute_lens_offsets(float2(red_sample_x, y), width_f, height_f, freq, Time, Speed, displacement, seed_f);
        float red_scan_val = nmsg_crt_sample_scanline_bilinear(red_sample_x + red_offsets.x, y + red_offsets.y, width_f, height_f, scanline_base);
        float3 red_blended = lerp(red_base_col, (red_base_col + red_scan_val) * red_scan_val, 0.5);

        float3 green_blended = color;

        // Blue channel
        float blue_x = max(x - displacement_pixels, 0.0);
        blue_x = nmsg_crt_blend_linear(x, blue_x, gradient);
        float blue_sample_x = nmsg_crt_blend_cosine(x, blue_x, aber_mask);
        float2 blue_uv = float2((blue_sample_x * rs - TileOffset.x) / Resolution.x, UV.y);
        float3 blue_base_col = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, blue_uv).xyz;
        float2 blue_offsets = nmsg_crt_compute_lens_offsets(float2(blue_sample_x, y), width_f, height_f, freq, Time, Speed, displacement, seed_f);
        float blue_scan_val = nmsg_crt_sample_scanline_bilinear(blue_sample_x + blue_offsets.x, y + blue_offsets.y, width_f, height_f, scanline_base);
        float3 blue_blended = lerp(blue_base_col, (blue_base_col + blue_scan_val) * blue_scan_val, 0.5);

        color = float3(
            nmsg_crt_adjust_hue(red_blended,   hue_shift).r,
            nmsg_crt_adjust_hue(green_blended, hue_shift).g,
            nmsg_crt_adjust_hue(blue_blended,  hue_shift).b
        );
        color = nmsg_crt_adjust_hue(color, -hue_shift);
        color = nmsg_crt_adjust_saturation(color, 1.125);

        float vignette_alpha = nmsg_crt_random_scalar(seed_base + 3.17) * 0.175;
        color.x = nmsg_crt_apply_vignette(color.x, 0.0, singularity, vignette_alpha);
        color.y = nmsg_crt_apply_vignette(color.y, 0.0, singularity, vignette_alpha);
        color.z = nmsg_crt_apply_vignette(color.z, 0.0, singularity, vignette_alpha);
    }

    float local_mean = (color.x + color.y + color.z) * NMSG_CRT_INV_THREE;
    color = clamp((color - local_mean) * 1.25 + local_mean, (float3)0.0, (float3)1.0);

    color = lerp(base_color, color, alphaVal);
    Out = float4(color, base_sample4.w);
}

#endif // NM_SG_CRT_INCLUDED
