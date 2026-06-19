#ifndef NM_EFFECT_PERLIN_INCLUDED
#define NM_EFFECT_PERLIN_INCLUDED

// =============================================================================
// Perlin.hlsl — synth/perlin (Perlin-like gradient noise with optional warp).
//
// Ported VERBATIM from shaders/effects/synth/perlin/wgsl/perlin.wgsl (canonical).
// WGSL is top-left / D3D-oriented like Unity HLSL: NO per-effect Y flip.
//
// Helpers ported inline per PORTING-GUIDE. Only pcg/prng/nm_mod come from NMCore:
//   - WGSL pcg()  -> nm_pcg()  (identical mixing).
//   - WGSL prng() -> nm_prng() — the FOLD variant (perlin is Variant A,
//     ref 08 §1.2). Divisor 4294967295.0 (= f32(0xffffffff); ref 08 L136-140).
//   - WGSL wrapZ() float `%` -> nm_mod (ref 08 §"mod vs %", L502). See TODO below.
// hash3/grad3/quintic/smoothlerp/noise2D/noise3D/fbm*/domainWarp* are
// per-effect and ported inline (NOT hoisted). TAU/Z_PERIOD are local consts
// matching the WGSL literals exactly.
//
// PARITY HAZARDS handled here:
//   H6/mod-vs-% — WGSL wrapZ uses float `%` (sign-of-dividend); GLSL uses
//     `mod` (sign-of-divisor). In this effect `z` is always >= 0 (time>=0,
//     speed>=0, channelOffset>=0), so the two agree. We use nm_mod (the
//     always-positive form mandated by the guide). TODO(verify): negative z
//     is unreachable in the active param ranges; if a future caller feeds
//     z<0, WGSL `%` would differ — revisit then.
//   §1.1/§1.2 — prng FOLD + truncating uint cast: nm_prng matches.
//     WGSL writes select(-p*2+1, p*2, p>=0) == p>=0 ? p*2 : -p*2+1 == nm_prng.
//   hash3 cast — `(uint3)((int3)(ps*1000.0) + 65536)`: float->int truncation
//     THEN int->uint reinterpret (two's complement). Match exactly; NOT asuint.
//   DIMENSIONS — compile-time define in the reference; here an int uniform
//     declared with the DEFINE name `DIMENSIONS` (the binder writes defines by
//     their define key, not the lowercase uniform name) + [branch] (default 2;
//     GLSL `#ifndef DIMENSIONS #define DIMENSIONS 2`).
//   H13 — st divides by fullResolution (see .shader). NOTE: perlin's main()
//     divides by fullResolution (BOTH axes via the res vector), NOT height
//     only — it then multiplies st.x by aspect. Reproduced literally.
//   Full 32-bit float throughout (PCG / hash3 bit-sensitive).
// =============================================================================

#include "../../Include/NMCore.hlsl"

// ---- per-effect named uniforms (definition.js globals[*].uniform) -----------
float scale;          // noise scale (0..100), default 25
int   octaves;        // fbm octaves (1..6), default 1
int   colorMode;      // 0 mono, 1 rgb; default 1
int   DIMENSIONS;     // globals.dimensions.define = "DIMENSIONS"; bound by name; default 2 (2D), 3=3D
int   ridges;         // boolean (0/1); default 0
int   warpIterations; // 0..4; default 0
float warpScale;      // 0..100; default 50
float warpIntensity;  // 0..100; default 50
int   seed;           // 0..100; default 0
float speed;          // animation speed (int 0..5 in UI; float uniform), default 1

// TAU/Z_PERIOD: local consts matching the WGSL literals exactly.
static const float NM_PERLIN_TAU      = 6.283185307179586;
static const float NM_PERLIN_Z_PERIOD = 4.0;  // Period length in z-axis lattice units

// 3D hash using multiple rounds of mixing (verbatim from perlin.wgsl L62-82).
// Per-effect hash (NOT NMCore's). seed read from the `seed` uniform.
float nm_perlin_hash3(float3 p)
{
    // Add seed to input to vary the noise pattern
    float3 ps = p + (float)seed * 0.1;

    // Convert to unsigned integer values via large multipliers.
    // float->int truncation, +65536, then int->uint reinterpret (two's comp).
    uint3 q = (uint3)((int3)(ps * 1000.0) + 65536);

    // Multiple rounds of mixing for thorough decorrelation
    q = q * 1664525u + 1013904223u;  // LCG constants
    q.x = q.x + q.y * q.z;
    q.y = q.y + q.z * q.x;
    q.z = q.z + q.x * q.y;

    q = q ^ (q >> 16u);

    q.x = q.x + q.y * q.z;
    q.y = q.y + q.z * q.x;
    q.z = q.z + q.x * q.y;

    return (float)(q.x ^ q.y ^ q.z) / 4294967295.0;
}

// Gradient from hash - returns normalized 3D vector (verbatim L85-98).
float3 nm_perlin_grad3(float3 p)
{
    float h1 = nm_perlin_hash3(p);
    float h2 = nm_perlin_hash3(p + 127.1);
    float h3 = nm_perlin_hash3(p + 269.5);

    float3 g = float3(
        h1 * 2.0 - 1.0,
        h2 * 2.0 - 1.0,
        h3 * 2.0 - 1.0
    );

    return normalize(g);
}

// Quintic interpolation for smooth transitions (verbatim L101-103).
float nm_perlin_quintic(float t)
{
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

float nm_perlin_smoothlerp(float x, float a, float b)
{
    return a + nm_perlin_quintic(x) * (b - a);
}

// Wrap z index for periodicity at lattice level (verbatim L110-112).
// WGSL: z % Z_PERIOD. Active domain z>=0 so == nm_mod. See header TODO(verify).
float nm_perlin_wrapZ(float z)
{
    return nm_mod(z, NM_PERLIN_Z_PERIOD);
}

// 2D periodic grid function - gradient angle animates with time (verbatim L115-121).
float nm_perlin_grid2D(float2 st, float2 cell, float timeAngle, float channelOffset)
{
    float angle = nm_prng(float3(cell + (float)seed, 1.0)).r * NM_PERLIN_TAU;
    angle = angle + timeAngle + channelOffset * NM_PERLIN_TAU;  // Animate gradient rotation
    float2 gradient = float2(cos(angle), sin(angle));
    float2 dist = st - cell;
    return dot(gradient, dist);
}

// 2D periodic Perlin noise (verbatim L124-138).
float nm_perlin_noise2D(float2 st, float timeAngle, float channelOffset)
{
    float2 cell = floor(st);
    float2 f = frac(st);

    float tl = nm_perlin_grid2D(st, cell, timeAngle, channelOffset);
    float tr = nm_perlin_grid2D(st, float2(cell.x + 1.0, cell.y), timeAngle, channelOffset);
    float bl = nm_perlin_grid2D(st, float2(cell.x, cell.y + 1.0), timeAngle, channelOffset);
    float br = nm_perlin_grid2D(st, cell + 1.0, timeAngle, channelOffset);

    float upper = nm_perlin_smoothlerp(f.x, tl, tr);
    float lower = nm_perlin_smoothlerp(f.x, bl, br);
    float val = nm_perlin_smoothlerp(f.y, upper, lower);

    return val;  // Returns -1..1
}

// 3D gradient noise - Perlin-style, z-axis periodic with Z_PERIOD (verbatim L142-171).
float nm_perlin_noise3D(float3 p)
{
    float3 i = floor(p);
    float3 f = frac(p);

    float3 u = float3(nm_perlin_quintic(f.x), nm_perlin_quintic(f.y), nm_perlin_quintic(f.z));

    float iz0 = nm_perlin_wrapZ(i.z);
    float iz1 = nm_perlin_wrapZ(i.z + 1.0);

    float n000 = dot(nm_perlin_grad3(float3(i.xy, iz0) + float3(0.0, 0.0, 0.0)), f - float3(0.0, 0.0, 0.0));
    float n100 = dot(nm_perlin_grad3(float3(i.xy, iz0) + float3(1.0, 0.0, 0.0)), f - float3(1.0, 0.0, 0.0));
    float n010 = dot(nm_perlin_grad3(float3(i.xy, iz0) + float3(0.0, 1.0, 0.0)), f - float3(0.0, 1.0, 0.0));
    float n110 = dot(nm_perlin_grad3(float3(i.xy, iz0) + float3(1.0, 1.0, 0.0)), f - float3(1.0, 1.0, 0.0));
    float n001 = dot(nm_perlin_grad3(float3(i.xy, iz1) + float3(0.0, 0.0, 0.0)), f - float3(0.0, 0.0, 1.0));
    float n101 = dot(nm_perlin_grad3(float3(i.xy, iz1) + float3(1.0, 0.0, 0.0)), f - float3(1.0, 0.0, 1.0));
    float n011 = dot(nm_perlin_grad3(float3(i.xy, iz1) + float3(0.0, 1.0, 0.0)), f - float3(0.0, 1.0, 1.0));
    float n111 = dot(nm_perlin_grad3(float3(i.xy, iz1) + float3(1.0, 1.0, 0.0)), f - float3(1.0, 1.0, 1.0));

    float nx00 = lerp(n000, n100, u.x);
    float nx10 = lerp(n010, n110, u.x);
    float nx01 = lerp(n001, n101, u.x);
    float nx11 = lerp(n011, n111, u.x);

    float nxy0 = lerp(nx00, nx10, u.y);
    float nxy1 = lerp(nx01, nx11, u.y);

    return lerp(nxy0, nxy1, u.z);
}

// FBM for 2D periodic noise (verbatim L174-198).
float nm_perlin_fbm2D(float2 st, float timeAngle, float channelOffset, int ridgedMode)
{
    int MAX_OCT = 8;
    float amplitude = 0.5;
    float frequency = 1.0;
    float sum = 0.0;
    float maxVal = 0.0;
    int oct = octaves;
    if (oct < 1) { oct = 1; }

    for (int i = 0; i < MAX_OCT; i = i + 1) {
        if (i >= oct) { break; }
        float n = nm_perlin_noise2D(st * frequency, timeAngle, channelOffset);  // -1..1
        n = clamp(n * 1.5, -1.0, 1.0);
        if (ridgedMode == 1) {
            n = 1.0 - abs(n);
        } else {
            n = (n + 1.0) * 0.5;
        }
        sum = sum + n * amplitude;
        maxVal = maxVal + amplitude;
        frequency = frequency * 2.0;
        amplitude = amplitude * 0.5;
    }
    return sum / maxVal;
}

// FBM using 3D noise with circular time for seamless looping (verbatim L202-233).
float nm_perlin_fbm3D(float2 st, float timeAngle, float channelOffset, int ridgedMode)
{
    int MAX_OCT = 8;
    float amplitude = 0.5;
    float frequency = 1.0;
    float sum = 0.0;
    float maxVal = 0.0;
    int oct = octaves;
    if (oct < 1) { oct = 1; }

    // Linear time traversal with periodic z-axis
    float z = timeAngle / NM_PERLIN_TAU * NM_PERLIN_Z_PERIOD + channelOffset;

    for (int i = 0; i < MAX_OCT; i = i + 1) {
        if (i >= oct) { break; }
        float3 p = float3(st * frequency, z);
        float n = nm_perlin_noise3D(p);  // -1..1
        n = clamp(n * 1.5, -1.0, 1.0);
        if (ridgedMode == 1) {
            n = 1.0 - abs(n);  // fold at zero, gives 0..1 with ridges at zero-crossings
        } else {
            n = (n + 1.0) * 0.5;  // normalize to 0..1
        }
        sum = sum + n * amplitude;
        maxVal = maxVal + amplitude;
        frequency = frequency * 2.0;
        amplitude = amplitude * 0.5;
    }
    return sum / maxVal;
}

// Single-octave warp noise helpers (verbatim L236-242).
float nm_perlin_warpNoise2D(float2 p, float timeAngle)
{
    return nm_perlin_noise2D(p, timeAngle, 0.0);
}

float nm_perlin_warpNoise3D(float2 p, float z)
{
    return nm_perlin_noise3D(float3(p, z));
}

// Domain warp 2D (verbatim L245-257).
float2 nm_perlin_domainWarp2D(float2 st, float timeAngle, int iterations, float wScale, float wIntensity)
{
    float wFreq = max(0.1, 100.0 / max(wScale, 0.01));
    float disp = wIntensity * 0.02;
    float2 p = st;
    for (int i = 0; i < 4; i = i + 1) {
        if (i >= iterations) { break; }
        float fi = (float)i;
        float nx = nm_perlin_warpNoise2D(p * wFreq + float2(fi * 5.2 + 1.7, fi * 1.3 + 13.7), timeAngle);
        float ny = nm_perlin_warpNoise2D(p * wFreq + float2(fi * 2.8 + 7.3, fi * 4.1 + 3.9), timeAngle);
        p = p + float2(nx, ny) * disp;
    }
    return p;
}

// Domain warp 3D (verbatim L259-271).
float2 nm_perlin_domainWarp3D(float2 st, float z, int iterations, float wScale, float wIntensity)
{
    float wFreq = max(0.1, 100.0 / max(wScale, 0.01));
    float disp = wIntensity * 0.02;
    float2 p = st;
    for (int i = 0; i < 4; i = i + 1) {
        if (i >= iterations) { break; }
        float fi = (float)i;
        float nx = nm_perlin_warpNoise3D(p * wFreq + float2(fi * 5.2 + 1.7, fi * 1.3 + 13.7), z);
        float ny = nm_perlin_warpNoise3D(p * wFreq + float2(fi * 2.8 + 7.3, fi * 4.1 + 3.9), z);
        p = p + float2(nx, ny) * disp;
    }
    return p;
}

// nm_perlin: top-level generator (verbatim from perlin.wgsl main() L273-327).
// `globalCoord` = position.xy + tileOffset; `fullRes` = params.fullResolution;
// `aspect` = params.aspect (= fullResolution.x / fullResolution.y); `t` = time.
// DIMENSIONS is the `dimensions` int uniform (2 or 3); branched at runtime.
float4 nm_perlin(float2 globalCoord, float2 fullRes, float aspect, float t)
{
    // res guard from WGSL main(): if fullResolution.x < 1 use 1024x1024.
    // The WGSL divides st by params.fullResolution (the uniform), not `res`;
    // `res` is computed but unused for st. Reproduced literally.
    float2 st = globalCoord / fullRes;
    // Center UVs so zoom scales from center, not corner
    st = st - 0.5;
    st.x = st.x * aspect;
    // Invert scale to match vnoise convention: higher scale = fewer cells (zoomed in)
    float freq = max(0.1, 100.0 / max(scale, 0.01));
    st = st * freq;
    // Offset to keep noise coords positive (avoids hash artifacts at boundaries)
    st = st + 1000.0;

    // time is 0-1 representing position around circle for seamless looping
    float timeAngle = t * speed * NM_PERLIN_TAU;

    // Apply domain warp if enabled
    [branch]
    if (warpIterations > 0) {
        [branch]
        if (DIMENSIONS == 2) {
            st = nm_perlin_domainWarp2D(st, timeAngle, warpIterations, warpScale, warpIntensity);
        } else {
            float zw = timeAngle / NM_PERLIN_TAU * NM_PERLIN_Z_PERIOD;
            st = nm_perlin_domainWarp3D(st, zw, warpIterations, warpScale, warpIntensity);
        }
    }

    float r;
    float g;
    float b;

    [branch]
    if (DIMENSIONS == 2) {
        // 2D periodic noise (faster)
        r = nm_perlin_fbm2D(st, timeAngle, 0.0, ridges);
        g = nm_perlin_fbm2D(st, timeAngle, 0.333, ridges);
        b = nm_perlin_fbm2D(st, timeAngle, 0.667, ridges);
    } else {
        // 3D cross-section noise (original)
        r = nm_perlin_fbm3D(st, timeAngle, 0.0, ridges);
        g = nm_perlin_fbm3D(st, timeAngle, 1.33, ridges);
        b = nm_perlin_fbm3D(st, timeAngle, 2.67, ridges);
    }

    float3 col;
    [branch]
    if (colorMode == 0) {
        // Mono mode
        col = float3(r, r, r);
    } else {
        // RGB mode
        col = float3(r, g, b);
    }

    return float4(col, 1.0);
}

#endif // NM_EFFECT_PERLIN_INCLUDED
