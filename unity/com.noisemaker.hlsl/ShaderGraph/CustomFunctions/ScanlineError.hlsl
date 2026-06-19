#ifndef NM_SG_SCANLINEERROR_INCLUDED
#define NM_SG_SCANLINEERROR_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for filter/scanlineError.
//
// Single render pass, so a Custom Function node is provided (per PORTING-GUIDE).
// Each global param from definition.js maps to a named input:
//   mode       -> Mode       (float; 0 scanline, 1 vhs)  default 1
//   timeOffset -> TimeOffset (float) [-10,10]            default 0
//   distortion -> Distortion (float) [0,3]               default 1
//   noise      -> Noise      (float) [0,3]               default 1
//   speed      -> Speed      (float) [0,5]               default 1
//   time       -> Time       (float; engine normalized 0..1 anim time)
//
// IMPORTANT: this effect POINT-FETCHES the input at integer texel coords with a
// horizontal displacement (WGSL textureLoad). The node therefore needs the input
// texture's pixel resolution to convert UV->integer coord and to .Load neighbors.
// UV is the input texture's own 0..1 UV; Resolution is float2(texW, texH).
//
// Self-contained (does NOT include NMFullscreen.hlsl / NMCore.hlsl) so it is safe
// to drop into a Shader Graph Custom Function node. Helpers/core are mirrored
// VERBATIM from Shaders/Effects/filter/ScanlineError.hlsl, name-prefixed `sesg_`
// to avoid symbol clashes (incl. a private PCG copy — identical to NMCore nm_pcg).
//
// TODO(verify): InputTex must be a point/clamp, non-sRGB (linear) texture so the
// .Load fetch matches the runtime path; .Load ignores the SamplerState filter,
// so the node's SS input is unused (declared for node-signature consistency).
// TODO(verify): UV*Resolution at a pixel center reproduces the runtime's
// trunc(fragCoord) integer coord. If a half-texel offset appears in the parity
// harness, the conversion below (floor(UV*Resolution)) is the place to adjust.
// =============================================================================

static const float SESG_TAU = 6.283185307179586;

float sesg_clamp01(float value) { return clamp(value, 0.0, 1.0); }

float3 sesg_mod289_vec3(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float4 sesg_mod289_vec4(float4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float4 sesg_permute(float4 x) { return sesg_mod289_vec4(((x * 34.0) + 1.0) * x); }
float4 sesg_taylor_inv_sqrt(float4 r) { return 1.79284291400159 - 0.85373472095314 * r; }

float sesg_simplex_noise(float3 v)
{
    float2 c = float2(1.0 / 6.0, 1.0 / 3.0);
    float4 d = float4(0.0, 0.5, 1.0, 2.0);

    float3 i0 = floor(v + dot(v, float3(c.y, c.y, c.y)));
    float3 x0 = v - i0 + dot(i0, float3(c.x, c.x, c.x));

    float3 step1 = step(float3(x0.y, x0.z, x0.x), x0);
    float3 l = float3(1.0, 1.0, 1.0) - step1;
    float3 i1 = min(step1, float3(l.z, l.x, l.y));
    float3 i2 = max(step1, float3(l.z, l.x, l.y));

    float3 x1 = x0 - i1 + float3(c.x, c.x, c.x);
    float3 x2 = x0 - i2 + float3(c.y, c.y, c.y);
    float3 x3 = x0 - float3(d.y, d.y, d.y);

    float3 i = sesg_mod289_vec3(i0);
    float4 p = sesg_permute(sesg_permute(sesg_permute(
        i.z + float4(0.0, i1.z, i2.z, 1.0))
        + i.y + float4(0.0, i1.y, i2.y, 1.0))
        + i.x + float4(0.0, i1.x, i2.x, 1.0));

    float n_ = 0.14285714285714285;
    float3 ns = n_ * float3(d.w, d.y, d.z) - float3(d.x, d.z, d.x);

    float4 j = p - 49.0 * floor(p * ns.z * ns.z);
    float4 x_ = floor(j * ns.z);
    float4 y_ = floor(j - 7.0 * x_);

    float4 x = x_ * ns.x + ns.y;
    float4 y = y_ * ns.x + ns.y;
    float4 h = 1.0 - abs(x) - abs(y);

    float4 b0 = float4(x.x, x.y, y.x, y.y);
    float4 b1 = float4(x.z, x.w, y.z, y.w);

    float4 s0 = floor(b0) * 2.0 + 1.0;
    float4 s1 = floor(b1) * 2.0 + 1.0;
    float4 sh = -step(h, float4(0.0, 0.0, 0.0, 0.0));

    float4 a0 = float4(b0.x, b0.z, b0.y, b0.w) + float4(s0.x, s0.z, s0.y, s0.w) * float4(sh.x, sh.x, sh.y, sh.y);
    float4 a1 = float4(b1.x, b1.z, b1.y, b1.w) + float4(s1.x, s1.z, s1.y, s1.w) * float4(sh.z, sh.z, sh.w, sh.w);

    float3 g0 = float3(a0.x, a0.y, h.x);
    float3 g1 = float3(a0.z, a0.w, h.y);
    float3 g2 = float3(a1.x, a1.y, h.z);
    float3 g3 = float3(a1.z, a1.w, h.w);

    float4 norm = sesg_taylor_inv_sqrt(float4(dot(g0, g0), dot(g1, g1), dot(g2, g2), dot(g3, g3)));

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
        m0sq * m0sq * dot(g0n, x0) +
        m1sq * m1sq * dot(g1n, x1) +
        m2sq * m2sq * dot(g2n, x2) +
        m3sq * m3sq * dot(g3n, x3)
    );
}

float sesg_periodic_value(float t, float value) { return sin((t - value) * SESG_TAU) * 0.5 + 0.5; }

float sesg_compute_simplex_value(float2 coord, float2 freq, float t, float speed_value, float3 offset)
{
    float freq_x = max(freq.x, 1.0);
    float freq_y = max(freq.y, 1.0);
    float angle = cos(t * SESG_TAU) * speed_value;
    float3 sampleVec = float3(coord.x * freq_x + offset.x, coord.y * freq_y + offset.y, angle + offset.z);
    return sesg_simplex_noise(sampleVec);
}

float sesg_compute_value_noise(float2 coord, float2 freq, float t, float speed_value, float3 base_seed, float3 time_seed)
{
    float base_noise = sesg_compute_simplex_value(coord, freq, t, speed_value, base_seed);
    float value = sesg_clamp01(base_noise * 0.5 + 0.5);

    if (speed_value != 0.0 && t != 0.0)
    {
        float time_noise_raw = sesg_compute_simplex_value(coord, freq, 0.0, 1.0, time_seed);
        float time_value = sesg_clamp01(time_noise_raw * 0.5 + 0.5);
        float scaled_time = sesg_periodic_value(t, time_value) * speed_value;
        value = sesg_periodic_value(scaled_time, value);
    }

    return sesg_clamp01(value);
}

float sesg_compute_exponential_noise(float2 coord, float2 freq, float t, float speed_value, float3 base_seed, float3 time_seed)
{
    float base = sesg_compute_value_noise(coord, freq, t, speed_value, base_seed, time_seed);
    return pow(base, 4.0);
}

int sesg_wrap_coord(int coord, int limit)
{
    if (limit <= 0) { return 0; }
    int wrapped = coord % limit;
    if (wrapped < 0) { wrapped = wrapped + limit; }
    return wrapped;
}

static const float3 SESG_BASE_SEED_LINE   = float3(37.0, 91.0, 53.0);
static const float3 SESG_TIME_SEED_LINE   = float3(134.0, 150.0, 184.0);
static const float3 SESG_BASE_SEED_SWERVE = float3(11.0, 73.0, 29.0);
static const float3 SESG_TIME_SEED_SWERVE = float3(100.0, 114.0, 178.0);
static const float3 SESG_BASE_SEED_WHITE  = float3(67.0, 29.0, 149.0);
static const float3 SESG_TIME_SEED_WHITE  = float3(180.0, 82.0, 322.0);

// PCG 3D (identical to NMCore nm_pcg / this effect's pcg()).
uint3 sesg_pcg(uint3 v)
{
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return v;
}

float sesg_hashNoise(float3 p)
{
    uint3 seed = uint3(asuint(p.x), asuint(p.y), asuint(p.z));
    return float(sesg_pcg(seed).x) / float(0xffffffffu);
}

float sesg_valueNoise(float3 p)
{
    float3 i = floor(p);
    float3 f = frac(p);
    float3 u = f * f * (3.0 - 2.0 * f);

    float c000 = sesg_hashNoise(i);
    float c100 = sesg_hashNoise(i + float3(1.0, 0.0, 0.0));
    float c010 = sesg_hashNoise(i + float3(0.0, 1.0, 0.0));
    float c110 = sesg_hashNoise(i + float3(1.0, 1.0, 0.0));
    float c001 = sesg_hashNoise(i + float3(0.0, 0.0, 1.0));
    float c101 = sesg_hashNoise(i + float3(1.0, 0.0, 1.0));
    float c011 = sesg_hashNoise(i + float3(0.0, 1.0, 1.0));
    float c111 = sesg_hashNoise(i + float3(1.0, 1.0, 1.0));

    return lerp(
        lerp(lerp(c000, c100, u.x), lerp(c010, c110, u.x), u.y),
        lerp(lerp(c001, c101, u.x), lerp(c011, c111, u.x), u.y),
        u.z
    );
}

float sesg_vhs_computeNoise(float2 coord, float2 freq, float t, float spd, float3 baseOff, float3 timeOff)
{
    float3 p = float3(coord.x * freq.x + baseOff.x, coord.y * freq.y + baseOff.y, cos(t * SESG_TAU) * spd + baseOff.z);
    float val = sesg_valueNoise(p);

    if (spd != 0.0 && t != 0.0)
    {
        float3 tp = float3(coord.x * freq.x + timeOff.x, coord.y * freq.y + timeOff.y, timeOff.z);
        float timeVal = sesg_valueNoise(tp);
        float scaledTime = sesg_periodic_value(t, timeVal) * spd;
        val = sesg_periodic_value(scaledTime, val);
    }

    return clamp(val, 0.0, 1.0);
}

float sesg_vhs_gradValue(float yNorm, float freqY, float t, float spd)
{
    float base = sesg_vhs_computeNoise(float2(0.0, yNorm), float2(1.0, freqY), t, spd,
        float3(17.0, 29.0, 47.0), float3(71.0, 113.0, 191.0));
    float g = max(base - 0.5, 0.0);
    g = min(g * 2.0, 1.0);
    return g;
}

float sesg_vhs_scanNoise(float2 coord, float2 freq, float t, float spd)
{
    return sesg_vhs_computeNoise(coord, freq, t, spd, float3(37.0, 59.0, 83.0), float3(131.0, 173.0, 211.0));
}

// Shader Graph Custom Function entry. Derives integer texel coord from UV and the
// input Resolution, then reproduces the WGSL main() (both modes) using .Load.
void NM_ScanlineError_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float2            Resolution,
    float             Mode,
    float             TimeOffset,
    float             Distortion,
    float             Noise,
    float             Speed,
    float             Time,
    out float4        Out)
{
    float2 dims = Resolution;
    int2 coord = (int2)floor(UV * dims);

    int width = (int)dims.x;
    int height = (int)dims.y;

    if (width == 0 || height == 0)
    {
        Out = float4(0.0, 0.0, 0.0, 0.0);
        return;
    }

    float width_f = dims.x;
    float height_f = dims.y;
    float time_value = Time + TimeOffset;
    float speed_value = max(Speed, 0.0);
    int m = (int)Mode;

    if (m == 1)
    {
        float yNorm = (float(coord.y) + 0.5) / height_f;
        float xNorm = (float(coord.x) + 0.5) / width_f;
        float2 destCoord = float2(xNorm, yNorm);

        float gradDest = sesg_vhs_gradValue(yNorm, 5.0, time_value, speed_value);

        float scanBase = floor(height_f * 0.5) + 1.0;
        float2 scanFreq = (height_f < width_f)
            ? float2(scanBase, scanBase * (width_f / height_f))
            : float2(scanBase * (height_f / width_f), scanBase);

        float scanDest = sesg_vhs_scanNoise(destCoord, scanFreq, time_value, speed_value * 100.0);

        int shiftAmount = (int)floor(scanDest * width_f * gradDest * gradDest * Distortion);
        int srcX = sesg_wrap_coord(coord.x - shiftAmount, width);

        float4 srcTexel = InputTex.tex.Load(int3(srcX, coord.y, 0));

        float srcXNorm = (float(srcX) + 0.5) / width_f;
        float scanSource = sesg_vhs_scanNoise(float2(srcXNorm, yNorm), scanFreq, time_value, speed_value * 100.0);
        float gradSource = sesg_vhs_gradValue(yNorm, 5.0, time_value, speed_value);

        float3 noiseColor = float3(scanSource, scanSource, scanSource);
        float3 blended = lerp(srcTexel.rgb, noiseColor, gradSource * Noise);

        Out = float4(blended, srcTexel.a);
    }
    else
    {
        float2 coord_norm = (float2(coord) + 0.5) / dims;
        float2 freq_line = float2(max(floor(width_f * 0.5), 1.0), max(floor(height_f * 0.5), 1.0));
        float swerve_height = max(floor(height_f * 0.01), 1.0);
        float2 freq_swerve = float2(1.0, swerve_height);
        float2 swerve_coord = float2(0.0, coord_norm.y);

        float line_noise = sesg_compute_exponential_noise(coord_norm, freq_line, time_value, speed_value * 10.0, SESG_BASE_SEED_LINE, SESG_TIME_SEED_LINE);
        line_noise = max(line_noise - 0.25, 0.0) * 2.0;

        float swerve_noise = sesg_compute_exponential_noise(swerve_coord, freq_swerve, time_value, speed_value, SESG_BASE_SEED_SWERVE, SESG_TIME_SEED_SWERVE);
        swerve_noise = max(swerve_noise - 0.25, 0.0) * 2.0;

        float line_weighted = line_noise * swerve_noise;
        float swerve_weight = swerve_noise * 2.0;

        float white_base = sesg_compute_value_noise(coord_norm, freq_line, time_value, speed_value * 100.0, SESG_BASE_SEED_WHITE, SESG_TIME_SEED_WHITE);
        float white_weighted = white_base * swerve_weight;

        float combined_error = sesg_clamp01(line_weighted + white_weighted);
        float shift_amount = combined_error * width_f * 0.025 * Distortion;
        int shift_pixels = (int)floor(shift_amount);
        int sample_x = sesg_wrap_coord(coord.x - shift_pixels, width);

        float4 texel = InputTex.tex.Load(int3(sample_x, coord.y, 0));

        float additive = clamp(line_weighted * white_weighted * 4.0 * Noise, 0.0, 4.0);
        float3 boosted = clamp(texel.rgb + float3(additive, additive, additive), float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));

        Out = float4(boosted, texel.a);
    }
}

#endif // NM_SG_SCANLINEERROR_INCLUDED
