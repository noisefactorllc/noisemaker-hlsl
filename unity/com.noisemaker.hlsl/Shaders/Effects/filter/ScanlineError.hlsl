#ifndef NM_EFFECT_SCANLINEERROR_INCLUDED
#define NM_EFFECT_SCANLINEERROR_INCLUDED

// =============================================================================
// ScanlineError.hlsl — filter/scanlineError (func: "scanlineError")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/filter/scanlineError/wgsl/scanlineError.wgsl
//
// Scanline glitch with two modes (mode uniform, int):
//   mode == 0  scanlineError: simplex-noise bands, horizontal pixel displacement,
//              additive white noise.
//   mode == 1  vhs: PCG hash value-noise, gradient-gated displacement + blend.
//
// PORTING-GUIDE notes / hazards handled:
//  * INTEGER PIXEL FETCH: the WGSL uses textureLoad(inputTex, vec2<i32>(...), 0)
//    (point fetch by integer texel coords), NOT textureSample. We mirror with
//    Texture2D.Load(int3(x, y, 0)). No bilinear filtering, no UV normalization
//    for the fetch. The "coord" is vec2<i32>(in.position.xy) = trunc(fragCoord);
//    we use (int2)NM_FragCoord(i). NMFullscreen gives top-left, +0.5-centered
//    fragCoord matching @builtin(position) (H8). ROW-ANCHORED NOISE EXCEPTION:
//    this effect derives a per-row noise band from the integer row. Under the
//    Metal RT path the integer row addressed for a row-based effect is mirrored
//    vs the WGSL position.y, so the noise row is flipped to (height-1-coord.y)
//    (see `noiseRow`). The .Load() texel fetch keeps coord.y (already correct).
//  * DIMS: the WGSL derives all width_f/height_f from textureDimensions(inputTex)
//    (the INPUT texture's own size), NOT fullResolution. We follow the WGSL: dims
//    = input GetDimensions. (The GLSL splits into tile-aware fullResolution math;
//    the WGSL is canonical and single-tile.) tileOffset does NOT enter here.
//  * PCG: nm_pcg from NMCore is the shared, bit-identical primitive. hashNoise
//    uses asuint(p) (bitcast<u32>, a BIT reinterpret — NOT (uint) truncation) to
//    seed; the lattice floor coords feed valueNoise as floats. (H, float-bits.)
//  * PCG divisor is 4294967295.0 = float(0xffffffffu), NOT 2^32 (H11).
//  * select(a, b, cond) -> WGSL select(falseVal, trueVal, cond): scanFreq uses
//    select(A, B, height_f < width_f) => result is B when height_f<width_f.
//    Reproduced with HLSL ternary (cond ? B : A) keeping that exact mapping.
//  * nm_mod NOT used here; the WGSL uses integer % via wrap_coord — reproduced
//    literally (the manual +limit fix, == nm_positiveModulo but kept inline to
//    mirror the WGSL function shape exactly, incl. the limit<=0 -> 0 guard).
//  * sin/cos/floor/fract/abs/step/min/max/clamp/mix/pow map 1:1 (mix -> lerp,
//    fract -> frac). All math is full 32-bit float (no half) — parity requirement.
//  * Simplex / value-noise helpers are this effect's OWN copies, ported verbatim;
//    do NOT substitute any generic noise. periodic_value is local (matches WGSL).
//  * Single render pass; Blend Off (the additive white noise is composited in the
//    shader body, the pass itself is opaque overwrite).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture (reference binding: inputTex@0). Fetched via .Load. --------
// SamplerState declared for completeness / SG parity but the body uses .Load
// (point fetch), matching the WGSL textureLoad — no filtering is applied.
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
float speed;        // globals.speed.uniform        default 1   [0,5]
float timeOffset;   // globals.timeOffset.uniform    default 0   [-10,10]
float distortion;   // globals.distortion.uniform    default 1   [0,3]
float noise;        // globals.noise.uniform         default 1   [0,3]
int   mode;         // globals.mode.uniform          default 1   {scanline:0, vhs:1}

static const float SE_TAU = 6.283185307179586;

float se_clamp01(float value)
{
    return clamp(value, 0.0, 1.0);
}

// =====================================================================
// Simplex noise (scanlineError mode) — verbatim from WGSL
// =====================================================================

float3 se_mod289_vec3(float3 x)
{
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

float4 se_mod289_vec4(float4 x)
{
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

float4 se_permute(float4 x)
{
    return se_mod289_vec4(((x * 34.0) + 1.0) * x);
}

float4 se_taylor_inv_sqrt(float4 r)
{
    return 1.79284291400159 - 0.85373472095314 * r;
}

float se_simplex_noise(float3 v)
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

    float3 i = se_mod289_vec3(i0);
    float4 p = se_permute(se_permute(se_permute(
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

    float4 norm = se_taylor_inv_sqrt(float4(dot(g0, g0), dot(g1, g1), dot(g2, g2), dot(g3, g3)));

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

float se_periodic_value(float t, float value)
{
    return sin((t - value) * SE_TAU) * 0.5 + 0.5;
}

float se_compute_simplex_value(float2 coord, float2 freq, float t, float speed_value, float3 offset)
{
    float freq_x = max(freq.x, 1.0);
    float freq_y = max(freq.y, 1.0);
    float angle = cos(t * SE_TAU) * speed_value;
    float3 sampleVec = float3(coord.x * freq_x + offset.x, coord.y * freq_y + offset.y, angle + offset.z);
    return se_simplex_noise(sampleVec);
}

float se_compute_value_noise(float2 coord, float2 freq, float t, float speed_value, float3 base_seed, float3 time_seed)
{
    float base_noise = se_compute_simplex_value(coord, freq, t, speed_value, base_seed);
    float value = se_clamp01(base_noise * 0.5 + 0.5);

    if (speed_value != 0.0 && t != 0.0)
    {
        float time_noise_raw = se_compute_simplex_value(coord, freq, 0.0, 1.0, time_seed);
        float time_value = se_clamp01(time_noise_raw * 0.5 + 0.5);
        float scaled_time = se_periodic_value(t, time_value) * speed_value;
        value = se_periodic_value(scaled_time, value);
    }

    return se_clamp01(value);
}

float se_compute_exponential_noise(float2 coord, float2 freq, float t, float speed_value, float3 base_seed, float3 time_seed)
{
    float base = se_compute_value_noise(coord, freq, t, speed_value, base_seed, time_seed);
    return pow(base, 4.0);
}

int se_wrap_coord(int coord, int limit)
{
    if (limit <= 0)
    {
        return 0;
    }
    int wrapped = coord % limit;
    if (wrapped < 0)
    {
        wrapped = wrapped + limit;
    }
    return wrapped;
}

static const float3 SE_BASE_SEED_LINE   = float3(37.0, 91.0, 53.0);
static const float3 SE_TIME_SEED_LINE   = float3(134.0, 150.0, 184.0);
static const float3 SE_BASE_SEED_SWERVE = float3(11.0, 73.0, 29.0);
static const float3 SE_TIME_SEED_SWERVE = float3(100.0, 114.0, 178.0);
static const float3 SE_BASE_SEED_WHITE  = float3(67.0, 29.0, 149.0);
static const float3 SE_TIME_SEED_WHITE  = float3(180.0, 82.0, 322.0);

// =====================================================================
// Hash-based value noise (vhs mode) — verbatim from WGSL
// =====================================================================

// PCG: nm_pcg (NMCore) == this effect's pcg() exactly.
float se_hashNoise(float3 p)
{
    uint3 seed = uint3(asuint(p.x), asuint(p.y), asuint(p.z));
    return float(nm_pcg(seed).x) / float(0xffffffffu);
}

float se_valueNoise(float3 p)
{
    float3 i = floor(p);
    float3 f = frac(p);
    float3 u = f * f * (3.0 - 2.0 * f);

    float c000 = se_hashNoise(i);
    float c100 = se_hashNoise(i + float3(1.0, 0.0, 0.0));
    float c010 = se_hashNoise(i + float3(0.0, 1.0, 0.0));
    float c110 = se_hashNoise(i + float3(1.0, 1.0, 0.0));
    float c001 = se_hashNoise(i + float3(0.0, 0.0, 1.0));
    float c101 = se_hashNoise(i + float3(1.0, 0.0, 1.0));
    float c011 = se_hashNoise(i + float3(0.0, 1.0, 1.0));
    float c111 = se_hashNoise(i + float3(1.0, 1.0, 1.0));

    return lerp(
        lerp(lerp(c000, c100, u.x), lerp(c010, c110, u.x), u.y),
        lerp(lerp(c001, c101, u.x), lerp(c011, c111, u.x), u.y),
        u.z
    );
}

// Accurate cos via quadrant range-reduction. Unity's Metal `cos` intrinsic is
// fast-math (~1e-3 absolute error near pi/2; `precise` does NOT override it). In
// se_vhs_computeNoise the cos is multiplied by `spd` (= speed*100 for scanNoise)
// and feeds a `floor`ed value-noise z-seed, so the ~-0.004 error at t=0.25 (pi/2)
// becomes a ~-0.4 z-shift that crosses a lattice boundary -> wrong noise layer
// (this is the whole scanlineError VHS divergence). Reducing the argument to
// [-pi/4, pi/4], where sin/cos are accurate even under fast-math, yields exact
// zeros at the quarter-turns and matches the reference WebGL `cos`.
float se_cos(float x)
{
    const float HALF_PI = 1.5707963267948966;
    float q = round(x / HALF_PI);
    float r = x - q * HALF_PI;          // [-pi/4, pi/4]
    int qi = ((int)q) & 3;              // quadrant 0..3 (bitwise & on int wraps negatives)
    float sr = sin(r);
    float cr = cos(r);
    if (qi == 0) return cr;
    if (qi == 1) return -sr;
    if (qi == 2) return -cr;
    return sr;                          // qi == 3
}

float se_vhs_computeNoise(float2 coord, float2 freq, float t, float spd, float3 baseOff, float3 timeOff)
{
    float3 p = float3(
        coord.x * freq.x + baseOff.x,
        coord.y * freq.y + baseOff.y,
        se_cos(t * SE_TAU) * spd + baseOff.z
    );

    float val = se_valueNoise(p);

    if (spd != 0.0 && t != 0.0)
    {
        float3 tp = float3(
            coord.x * freq.x + timeOff.x,
            coord.y * freq.y + timeOff.y,
            timeOff.z
        );
        float timeVal = se_valueNoise(tp);
        float scaledTime = se_periodic_value(t, timeVal) * spd;
        val = se_periodic_value(scaledTime, val);
    }

    return clamp(val, 0.0, 1.0);
}

float se_vhs_gradValue(float yNorm, float freqY, float t, float spd)
{
    float base = se_vhs_computeNoise(
        float2(0.0, yNorm),
        float2(1.0, freqY),
        t, spd,
        float3(17.0, 29.0, 47.0),
        float3(71.0, 113.0, 191.0)
    );
    float g = max(base - 0.5, 0.0);
    g = min(g * 2.0, 1.0);
    return g;
}

float se_vhs_scanNoise(float2 coord, float2 freq, float t, float spd)
{
    return se_vhs_computeNoise(coord, freq, t, spd,
        float3(37.0, 59.0, 83.0),
        float3(131.0, 173.0, 211.0)
    );
}

// =====================================================================
// Pass: "scanlineError" (progName "scanlineError")
// =====================================================================
float4 NMFrag_scanlineError(NMVaryings i) : SV_Target
{
    // WGSL: dims = vec2<f32>(textureDimensions(inputTex)); coord = vec2<i32>(in.position.xy);
    uint texW, texH;
    inputTex.GetDimensions(texW, texH);
    float2 dims = float2((float)texW, (float)texH);
    int2 coord = (int2)NM_FragCoord(i);

    int width = (int)dims.x;
    int height = (int)dims.y;

    if (width == 0 || height == 0)
    {
        return float4(0.0, 0.0, 0.0, 0.0);
    }

    float width_f = dims.x;
    float height_f = dims.y;
    float time_value = time + timeOffset;
    float speed_value = max(speed, 0.0);
    int m = (int)mode;

    // Row index that drives the per-row noise pattern. The reference anchors the
    // row-based noise AND the texel fetch to the SAME integer row (gl_FragCoord.y
    // / gid.y), so the noise gate and the displaced content stay consistent. A
    // previous port flipped this to (height-1-coord.y) for the noise while the
    // .Load() fetch kept coord.y — desynchronizing gate vs content. That flip was
    // calibrated against a stale golden; the no-flip form matches bitEffects'
    // verified NM_FragCoord convention (no per-effect Y flip) and the fresh
    // golden. Use coord.y for both the noise anchor and the fetch.
    int noiseRow = coord.y;

    if (m == 1)
    {
        // VHS mode
        float yNorm = (float(noiseRow) + 0.5) / height_f;
        float xNorm = (float(coord.x) + 0.5) / width_f;
        float2 destCoord = float2(xNorm, yNorm);

        float gradDest = se_vhs_gradValue(yNorm, 5.0, time_value, speed_value);

        float scanBase = floor(height_f * 0.5) + 1.0;
        // WGSL: select(A, B, height_f < width_f) => B when (height_f < width_f).
        float2 scanFreq = (height_f < width_f)
            ? float2(scanBase, scanBase * (width_f / height_f))
            : float2(scanBase * (height_f / width_f), scanBase);

        float scanDest = se_vhs_scanNoise(destCoord, scanFreq, time_value, speed_value * 100.0);

        int shiftAmount = (int)floor(scanDest * width_f * gradDest * gradDest * distortion);
        int srcX = se_wrap_coord(coord.x - shiftAmount, width);

        float4 srcTexel = inputTex.Load(int3(srcX, coord.y, 0));

        float srcXNorm = (float(srcX) + 0.5) / width_f;
        float scanSource = se_vhs_scanNoise(float2(srcXNorm, yNorm), scanFreq, time_value, speed_value * 100.0);
        float gradSource = se_vhs_gradValue(yNorm, 5.0, time_value, speed_value);

        float3 noiseColor = float3(scanSource, scanSource, scanSource);
        float3 blended = lerp(srcTexel.rgb, noiseColor, gradSource * noise);

        return float4(blended, srcTexel.a);
    }
    else
    {
        // Scanline error mode (default)
        float4 input_texel = inputTex.Load(int3(coord.x, coord.y, 0));

        // Noise is anchored to the mirrored row (see noiseRow note above); the
        // x coordinate is unchanged. The .Load() below still uses coord.y.
        float2 coord_norm = (float2(coord.x, noiseRow) + 0.5) / dims;
        float2 freq_line = float2(max(floor(width_f * 0.5), 1.0), max(floor(height_f * 0.5), 1.0));
        float swerve_height = max(floor(height_f * 0.01), 1.0);
        float2 freq_swerve = float2(1.0, swerve_height);
        float2 swerve_coord = float2(0.0, coord_norm.y);

        float line_noise = se_compute_exponential_noise(coord_norm, freq_line, time_value, speed_value * 10.0, SE_BASE_SEED_LINE, SE_TIME_SEED_LINE);
        line_noise = max(line_noise - 0.25, 0.0) * 2.0;

        float swerve_noise = se_compute_exponential_noise(swerve_coord, freq_swerve, time_value, speed_value, SE_BASE_SEED_SWERVE, SE_TIME_SEED_SWERVE);
        swerve_noise = max(swerve_noise - 0.25, 0.0) * 2.0;

        float line_weighted = line_noise * swerve_noise;
        float swerve_weight = swerve_noise * 2.0;

        float white_base = se_compute_value_noise(coord_norm, freq_line, time_value, speed_value * 100.0, SE_BASE_SEED_WHITE, SE_TIME_SEED_WHITE);
        float white_weighted = white_base * swerve_weight;

        float combined_error = se_clamp01(line_weighted + white_weighted);
        float shift_amount = combined_error * width_f * 0.025 * distortion;
        int shift_pixels = (int)floor(shift_amount);
        int sample_x = se_wrap_coord(coord.x - shift_pixels, width);

        float4 texel = inputTex.Load(int3(sample_x, coord.y, 0));

        float additive = clamp(line_weighted * white_weighted * 4.0 * noise, 0.0, 4.0);
        float3 boosted = clamp(texel.rgb + float3(additive, additive, additive), float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));

        return float4(boosted, texel.a);
    }
}

#endif // NM_EFFECT_SCANLINEERROR_INCLUDED
