#ifndef NM_GABOR_INCLUDED
#define NM_GABOR_INCLUDED

// =============================================================================
// Gabor.hlsl — synth/gabor, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/synth/gabor/wgsl/gabor.wgsl
//
// Anisotropic bandlimited noise via sparse Gabor convolution. Each grid cell
// scatters random impulse points; the final value is the sum of Gabor kernel
// contributions from the 3x3 cell neighborhood, optionally fractal-summed over
// octaves, then squashed through a logistic curve.
//
// Helpers (pcg, prng, map) are ported VERBATIM and INLINE per PORTING-GUIDE.
// This WGSL inlines its OWN pcg/prng (fold variant, /0xffffffff) and its own
// map(); reproduced here exactly rather than substituting NMCore variants.
//
// NUMERIC HAZARDS handled:
//  * st = (pos.xy + tileOffset) / fullResolution.y  — DIVIDES BY HEIGHT (.y)
//    ONLY (not width, not both). X spans [0, aspect]. (matches WGSL main())
//  * prng fold variant; divisor 4294967295.0 (= f32(0xffffffffu), NOT 2^32).
//  * (uint3)p is float->uint TRUNCATION toward zero (NOT asuint bit-reinterpret).
//  * prng arg order copied literally:
//      r1 = prng(vec3(cellId, sd + k*7.0))    -> (cellId.x, cellId.y, sd+...)
//      r2 = prng(vec3(sd + k*13.0, cellId))   -> (sd+..., cellId.x, cellId.y)
//  * `floor(speed)` then t = time*TAU*spd. spd kept as float.
//  * i32(density)/i32(octaves) -> (int) truncation.
//  * weight ternary: WGSL `if (r1.z < 0.5) { weight = -1.0; }` (default 1.0).
//  * logistic n = 1/(1+exp(-value*3.0)).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
// Bound by the runtime via MaterialPropertyBlock.
float scale;        // [1,100]    (global "scale")
float orientation;  // [-180,180] degrees (global "orientation")
float bandwidth;    // [1,100]    (global "bandwidth")
float isotropy;     // [0,100]    (global "isotropy")
int   density;      // [1,8]      (global "density") — i32(density)
int   octaves;      // [1,5]      (global "octaves") — i32(octaves)
int   speed;        // [0,5]      (global "speed")   — floor(speed)
float seed;         // [1,100]    (global "seed")    — used as float

// Local PI/TAU literals exactly as the WGSL declares them.
static const float NMGB_PI  = 3.14159265359;
static const float NMGB_TAU = 6.28318530718;

// ---- pcg PRNG (verbatim; this WGSL inlines its own copy) --------------------
uint3 nmgb_pcg(uint3 seed_in)
{
    uint3 v = seed_in * 1664525u + 1013904223u;
    v.x = v.x + v.y * v.z;
    v.y = v.y + v.z * v.x;
    v.z = v.z + v.x * v.y;
    v = v ^ (v >> 16u);
    v.x = v.x + v.y * v.z;
    v.y = v.y + v.z * v.x;
    v.z = v.z + v.x * v.y;
    return v;
}

// ---- prng (fold variant; divisor 4294967295.0 = f32(0xffffffffu)) -----------
// (uint3)p is float->uint truncation toward zero (NOT asuint).
float3 nmgb_prng(float3 p0)
{
    float3 p = p0;
    if (p.x >= 0.0) { p.x = p.x * 2.0; } else { p.x = -p.x * 2.0 + 1.0; }
    if (p.y >= 0.0) { p.y = p.y * 2.0; } else { p.y = -p.y * 2.0 + 1.0; }
    if (p.z >= 0.0) { p.z = p.z * 2.0; } else { p.z = -p.z * 2.0 + 1.0; }
    uint3 u = nmgb_pcg((uint3)p);
    return float3(u) / 4294967295.0;
}

// ---- map(v,inMin,inMax,outMin,outMax) — affine remap, verbatim --------------
float nmgb_map(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

// ---- gaborNoise: sum Gabor kernels from the 3x3 cell neighborhood -----------
float nmgb_gaborNoise(float2 st, float freq, float sigma, float baseAngle,
                      float iso, int impulses, float t, float sd)
{
    float2 cell = floor(st);
    float2 fr = frac(st);
    float sum = 0.0;

    [loop]
    for (int dy = -1; dy <= 1; dy = dy + 1)
    {
        [loop]
        for (int dx = -1; dx <= 1; dx = dx + 1)
        {
            float2 neighbor = float2((float)dx, (float)dy);
            float2 cellId = cell + neighbor;

            [loop]
            for (int k = 0; k < 8; k = k + 1)
            {
                if (k >= impulses) { break; }

                float3 r1 = nmgb_prng(float3(cellId, sd + (float)k * 7.0));
                float3 r2 = nmgb_prng(float3(sd + (float)k * 13.0, cellId));

                float2 impulsePos = r1.xy;
                impulsePos = impulsePos + float2(sin(t + r2.x * NMGB_TAU),
                                                 cos(t + r2.y * NMGB_TAU)) * 0.15;

                float2 delta = neighbor + impulsePos - fr;

                float angle = lerp(baseAngle, r2.z * NMGB_TAU, iso);
                float2 dir = float2(cos(angle), sin(angle));

                float weight = 1.0;
                if (r1.z < 0.5) { weight = -1.0; }

                float envelope = exp(-dot(delta, delta) / (2.0 * sigma * sigma));
                float phase = NMGB_TAU * freq * dot(dir, delta);
                sum = sum + weight * envelope * cos(phase);
            }
        }
    }
    return sum;
}

// =============================================================================
// nm_gabor — core per-pixel evaluation. `globalCoord` is the fragment's pixel
// coordinate plus tileOffset (i.e. NM_GlobalCoord(i)). Returns RGBA.
// Mirrors WGSL main() exactly. `fullRes`/`timeVal` are passed explicitly so the
// Shader Graph wrapper can supply its own values.
// =============================================================================
float4 nm_gabor(float2 globalCoord, float2 fullRes, float timeVal)
{
    // WGSL: st = (pos.xy + tileOffset) / fullResolution.y — divide by HEIGHT only.
    float2 st = globalCoord / fullRes.y;

    float freq = nmgb_map(scale, 1.0, 100.0, 20.0, 1.0);
    float sigma = nmgb_map(bandwidth, 1.0, 100.0, 0.05, 0.35);
    float baseAngle = orientation * NMGB_PI / 180.0;
    float iso = isotropy / 100.0;
    int impulses = (int)density;
    int oct = (int)octaves;
    float spd = floor((float)speed);
    float t = timeVal * NMGB_TAU * spd;

    float2 p = st * freq;

    // Fractal octave summation
    float value = 0.0;
    float amplitude = 1.0;
    float totalAmp = 0.0;
    float2 pOct = p;

    [loop]
    for (int i = 0; i < 5; i = i + 1)
    {
        if (i >= oct) { break; }
        float octFreq = 1.0 + (float)i * 0.5;
        float octSigma = sigma / (1.0 + (float)i * 0.5);
        float fi = (float)i;
        value = value + amplitude * nmgb_gaborNoise(pOct, octFreq, octSigma,
                                                    baseAngle, iso, impulses,
                                                    t + fi * 3.7, seed + fi * 17.0);
        totalAmp = totalAmp + amplitude;
        amplitude = amplitude * 0.5;
        pOct = pOct * 2.0;
    }
    value = value / totalAmp;

    float n = 1.0 / (1.0 + exp(-value * 3.0));
    return float4(float3(n, n, n), 1.0);
}

#endif // NM_GABOR_INCLUDED
