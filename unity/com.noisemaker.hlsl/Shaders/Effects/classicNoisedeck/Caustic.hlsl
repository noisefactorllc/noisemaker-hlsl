#ifndef NM_CAUSTIC_INCLUDED
#define NM_CAUSTIC_INCLUDED

// =============================================================================
// Caustic.hlsl — classicNoisedeck/caustic, ported PIXEL-IDENTICALLY from the
// canonical WGSL source:
//   shaders/effects/classicNoisedeck/caustic/wgsl/caustic.wgsl
//
// Dual-noise caustic pattern with "reflect" mode blend. Generator (no inputs).
//
// PORTING NOTES (per PORTING-GUIDE):
//  * Helpers ported VERBATIM inline. Only pcg/prng come from NMCore (this WGSL
//    inlines its own copies, identical to NMCore.nm_pcg/nm_prng — fold variant,
//    divisor 4294967295.0, (uint3)q is float->uint truncation NOT asuint).
//  * `periodicFunction` here is the SINE form: map(sin(p*TAU),-1,1,0,1). This is
//    DIFFERENT from NMCore.nm_periodicFunction (which uses cos), so it is ported
//    inline. Do NOT substitute the NMCore version.
//  * `modulo`/`map` ported inline matching the WGSL (nm_mod/nm_map are identical
//    but we keep the effect-local names for a literal transcription of hsv2rgb).
//  * NOISE_TYPE is a compile-time define in the reference (perf-only, not
//    correctness). Here it is a runtime int uniform branched with [branch],
//    exactly as the WGSL keeps all variants. Default 10 (simplex).
//  * randomFromLatticeWithOffset: asuint(seedFrac) is a BIT REINTERPRET
//    (bitcast<u32>); (uint)xi / (uint)yi / (uint)seed are two's-complement
//    int->uint reinterprets (WGSL bitcast<u32>(i32)) which HLSL (uint) matches.
//  * st = (globalCoord) / fullResolution.y  — DIVIDES BY HEIGHT (.y) only.
//  * select(false,true,cond) reversed in WGSL -> HLSL ternary cond ? true:false.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
float noiseScale;   // global "noiseScale" [1,200] default 85
float speed;        // global "speed" [0,100] default 25
int   wrap;         // global "wrap" boolean default true (1)
int   seed;         // global "seed" [0,100] default 44
float hueRotation;  // global "hueRotation" [0,360] default 180
float hueRange;     // global "hueRange" [0,100] default 25
float intensity;    // global "intensity" [-100,100] default 0

// Compile-time define in the reference; runtime int uniform here. Default 10.
#ifndef NM_CAUSTIC_NOISE_TYPE_DEFAULT
#define NM_CAUSTIC_NOISE_TYPE_DEFAULT 10
#endif
int NOISE_TYPE;     // was globals.interp.define = "NOISE_TYPE"

// Local PI/TAU exactly as the WGSL declares them.
static const float NMC_PI  = 3.14159265359;
static const float NMC_TAU = 6.28318530718;

// ---- modulo (effect-local; matches WGSL `a - b*floor(a/b)`) -----------------
float nmc_modulo(float a, float b)
{
    return a - b * floor(a / b);
}

// ---- map (affine remap, no clamp) -------------------------------------------
float nmc_map(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

// ---- pcg / prng (verbatim; identical to NMCore but the WGSL inlines them) ---
uint3 nmc_pcg(uint3 v)
{
    uint3 r = v;
    r = r * 1664525u + 1013904223u;
    r.x += r.y * r.z;
    r.y += r.z * r.x;
    r.z += r.x * r.y;
    r = r ^ (r >> 16u);
    r.x += r.y * r.z;
    r.y += r.z * r.x;
    r.z += r.x * r.y;
    return r;
}

float3 nmc_prng(float3 p)
{
    float3 q = p;
    // WGSL select(-q*2+1, q*2, q>=0) -> HLSL ternary q>=0 ? q*2 : -q*2+1
    q.x = (q.x >= 0.0) ? q.x * 2.0 : -q.x * 2.0 + 1.0;
    q.y = (q.y >= 0.0) ? q.y * 2.0 : -q.y * 2.0 + 1.0;
    q.z = (q.z >= 0.0) ? q.z * 2.0 : -q.z * 2.0 + 1.0;
    return float3(nmc_pcg((uint3)q)) / 4294967295.0;
}

// ---- brightnessContrast -----------------------------------------------------
float3 nmc_brightnessContrast(float3 color)
{
    float bright = nmc_map(intensity, -100.0, 100.0, -0.4, 0.4);
    float cont = 1.0;
    if (intensity < 0.0)
    {
        cont = nmc_map(intensity, -100.0, 0.0, 0.5, 1.0);
    }
    else
    {
        cont = nmc_map(intensity, 0.0, 100.0, 1.0, 1.5);
    }

    return (color - 0.5) * cont + 0.5 + bright;
}

// ---- hsv2rgb (effect's own variant; ternary chain, modulo-based) ------------
float3 nmc_hsv2rgb(float3 hsv)
{
    float h = frac(hsv.x);
    float s = hsv.y;
    float v = hsv.z;

    float c = v * s;
    float x = c * (1.0 - abs(nmc_modulo(h * 6.0, 2.0) - 1.0));
    float m = v - c;

    float3 rgb;

    if (0.0 <= h && h < 1.0 / 6.0)
    {
        rgb = float3(c, x, 0.0);
    }
    else if (1.0 / 6.0 <= h && h < 2.0 / 6.0)
    {
        rgb = float3(x, c, 0.0);
    }
    else if (2.0 / 6.0 <= h && h < 3.0 / 6.0)
    {
        rgb = float3(0.0, c, x);
    }
    else if (3.0 / 6.0 <= h && h < 4.0 / 6.0)
    {
        rgb = float3(0.0, x, c);
    }
    else if (4.0 / 6.0 <= h && h < 5.0 / 6.0)
    {
        rgb = float3(x, 0.0, c);
    }
    else if (5.0 / 6.0 <= h && h < 1.0)
    {
        rgb = float3(c, 0.0, x);
    }
    else
    {
        rgb = float3(0.0, 0.0, 0.0);
    }

    return rgb + float3(m, m, m);
}

// ---- periodicFunction (SINE form; NOT the NMCore cos form) ------------------
float nmc_periodicFunction(float p)
{
    return nmc_map(sin(p * NMC_TAU), -1.0, 1.0, 0.0, 1.0);
}

// ---- Simplex 2D -------------------------------------------------------------
float3 nmc_mod289_3(float3 x)
{
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

float2 nmc_mod289_2(float2 x)
{
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

float3 nmc_permute(float3 x)
{
    return nmc_mod289_3(((x * 34.0) + 1.0) * x);
}

float nmc_simplexValue(float2 st, float xFreq, float yFreq, float s, float blend)
{
    const float4 C = float4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);

    float2 uv = float2(st.x * xFreq, st.y * yFreq);
    uv.x += s;

    float2 i  = floor(uv + dot(uv, C.yy));
    float2 x0 = uv - i + dot(i, C.xx);

    // WGSL select(vec2(0,1), vec2(1,0), x0.x > x0.y) -> ternary x0.x>x0.y ? (1,0):(0,1)
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float2 x1 = x0 - i1 + float2(C.x, C.x);
    float2 x2 = x0 - float2(1.0, 1.0) + float2(2.0 * C.x, 2.0 * C.x);
    float2 x12xz = float2(x1.x, x2.x);
    float2 x12yw = float2(x1.y, x2.y);

    i = nmc_mod289_2(i);
    float3 p = nmc_permute(nmc_permute(i.y + float3(0.0, i1.y, 1.0))
             + i.x + float3(0.0, i1.x, 1.0));

    float3 m = max(float3(0.5, 0.5, 0.5) - float3(dot(x0, x0), dot(x1, x1), dot(x2, x2)), float3(0.0, 0.0, 0.0));
    m = m * m;
    m = m * m;

    float3 x = 2.0 * frac(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;

    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);

    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    float2 gyz = a0.yz * x12xz + h.yz * x12yw;
    g.y = gyz.x;
    g.z = gyz.y;

    float v = 130.0 * dot(m, g);

    return nmc_periodicFunction(nmc_map(v, -1.0, 1.0, 0.0, 1.0) - blend);
}

// ---- Sine noise -------------------------------------------------------------
float nmc_sineNoise(float2 st, float xFreq, float yFreq, float s, float blend)
{
    float2 uv = float2(st.x * xFreq, st.y * yFreq);
    uv.x += s;

    float a = blend;
    float b = blend;
    float c = 1.0 - blend;

    float3 r1 = nmc_prng(float3(s, 0.0, 0.0)) * 0.75 + 0.125;
    float3 r2 = nmc_prng(float3(s + 10.0, 0.0, 0.0)) * 0.75 + 0.125;
    float x = sin(r1.x * uv.y + sin(r1.y * uv.x + a) + sin(r1.z * uv.x + b) + c);
    float y = sin(r2.x * uv.x + sin(r2.y * uv.y + b) + sin(r2.z * uv.y + c) + a);

    return (x + y) * 0.5 + 0.5;
}

// ---- Value noise lattice ----------------------------------------------------
int nmc_positiveModulo(int value, int modulus)
{
    if (modulus == 0)
    {
        return 0;
    }

    int r = value % modulus;
    if (r < 0)
    {
        r += modulus;
    }
    return r;
}

float3 nmc_randomFromLatticeWithOffset(float2 st, float xFreq, float yFreq, float s, int2 offset)
{
    float2 lattice = float2(st.x * xFreq, st.y * yFreq);
    float2 baseFloor = floor(lattice);
    int2 base = int2((int)baseFloor.x, (int)baseFloor.y) + offset;
    float2 fracv = lattice - baseFloor;

    int seedInt = (int)floor(s);
    float seedFrac = frac(s);

    int xi = base.x + seedInt + (int)floor(fracv.x + seedFrac);
    int yi = base.y;

    if (wrap > 0)
    {
        int freqXInt = (int)(xFreq + 0.5);
        int freqYInt = (int)(yFreq + 0.5);

        if (freqXInt > 0)
        {
            xi = nmc_positiveModulo(xi, freqXInt);
        }
        if (freqYInt > 0)
        {
            yi = nmc_positiveModulo(yi, freqYInt);
        }
    }

    // (uint)xi / (uint)yi / (uint)seed: two's-complement int->uint reinterpret
    // (WGSL bitcast<u32>(i32)). asuint(seedFrac): float-bits reinterpret.
    uint xBits = (uint)xi;
    uint yBits = (uint)yi;
    uint seedBits = (uint)seed;
    uint fracBits = asuint(seedFrac);

    uint3 jitter = uint3(
        (fracBits * 374761393u) ^ 0x9E3779B9u,
        (fracBits * 668265263u) ^ 0x7F4A7C15u,
        (fracBits * 2246822519u) ^ 0x94D049B4u
    );

    uint3 state = uint3(xBits, yBits, seedBits) ^ jitter;
    uint3 prngState = nmc_pcg(state);
    float denom = 4294967295.0; // = float(0xffffffffu)
    return float3(
        (float)prngState.x / denom,
        (float)prngState.y / denom,
        (float)prngState.z / denom
    );
}

float nmc_constant(float2 st, float xFreq, float yFreq, float s)
{
    float3 rand = nmc_randomFromLatticeWithOffset(st, xFreq, yFreq, s, int2(0, 0));
    float scaledTime = nmc_periodicFunction(rand.x - time) * nmc_map(abs(speed), 0.0, 100.0, 0.0, 0.25);
    return nmc_periodicFunction(rand.y - scaledTime);
}

float nmc_constantOffset(float2 st, float xFreq, float yFreq, float s, int2 offset)
{
    float3 rand = nmc_randomFromLatticeWithOffset(st, xFreq, yFreq, s, offset);
    float scaledTime = nmc_periodicFunction(rand.x - time) * nmc_map(abs(speed), 0.0, 100.0, 0.0, 0.25);
    return nmc_periodicFunction(rand.y - scaledTime);
}

float nmc_quadratic3(float p0, float p1, float p2, float t)
{
    float t2 = t * t;
    return p0 * 0.5 * (1.0 - t) * (1.0 - t) +
           p1 * 0.5 * (-2.0 * t2 + 2.0 * t + 1.0) +
           p2 * 0.5 * t2;
}

float nmc_catmullRom3(float p0, float p1, float p2, float t)
{
    float t2 = t * t;
    float t3 = t2 * t;

    // Deliberately redundant (2.0*p0 - ... - p0) / (-p0 + ... + p0) terms — keep literal.
    return p1 + 0.5 * t * (p2 - p0) +
           0.5 * t2 * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p0) +
           0.5 * t3 * (-p0 + 3.0 * p1 - 3.0 * p2 + p0);
}

float nmc_quadratic3x3Value(float2 st, float xFreq, float yFreq, float s)
{
    float2 lattice = float2(st.x * xFreq, st.y * yFreq);
    float2 f = frac(lattice);

    float v00 = nmc_constantOffset(st, xFreq, yFreq, s, int2(-1, -1));
    float v10 = nmc_constantOffset(st, xFreq, yFreq, s, int2(0, -1));
    float v20 = nmc_constantOffset(st, xFreq, yFreq, s, int2(1, -1));

    float v01 = nmc_constantOffset(st, xFreq, yFreq, s, int2(-1, 0));
    float v11 = nmc_constantOffset(st, xFreq, yFreq, s, int2(0, 0));
    float v21 = nmc_constantOffset(st, xFreq, yFreq, s, int2(1, 0));

    float v02 = nmc_constantOffset(st, xFreq, yFreq, s, int2(-1, 1));
    float v12 = nmc_constantOffset(st, xFreq, yFreq, s, int2(0, 1));
    float v22 = nmc_constantOffset(st, xFreq, yFreq, s, int2(1, 1));

    float y0 = nmc_quadratic3(v00, v10, v20, f.x);
    float y1 = nmc_quadratic3(v01, v11, v21, f.x);
    float y2 = nmc_quadratic3(v02, v12, v22, f.x);

    return nmc_quadratic3(y0, y1, y2, f.y);
}

float nmc_catmullRom3x3Value(float2 st, float xFreq, float yFreq, float s)
{
    float2 lattice = float2(st.x * xFreq, st.y * yFreq);
    float2 f = frac(lattice);

    float v00 = nmc_constantOffset(st, xFreq, yFreq, s, int2(-1, -1));
    float v10 = nmc_constantOffset(st, xFreq, yFreq, s, int2(0, -1));
    float v20 = nmc_constantOffset(st, xFreq, yFreq, s, int2(1, -1));

    float v01 = nmc_constantOffset(st, xFreq, yFreq, s, int2(-1, 0));
    float v11 = nmc_constantOffset(st, xFreq, yFreq, s, int2(0, 0));
    float v21 = nmc_constantOffset(st, xFreq, yFreq, s, int2(1, 0));

    float v02 = nmc_constantOffset(st, xFreq, yFreq, s, int2(-1, 1));
    float v12 = nmc_constantOffset(st, xFreq, yFreq, s, int2(0, 1));
    float v22 = nmc_constantOffset(st, xFreq, yFreq, s, int2(1, 1));

    float y0 = nmc_catmullRom3(v00, v10, v20, f.x);
    float y1 = nmc_catmullRom3(v01, v11, v21, f.x);
    float y2 = nmc_catmullRom3(v02, v12, v22, f.x);

    return nmc_catmullRom3(y0, y1, y2, f.y);
}

float nmc_blendBicubic(float p0, float p1, float p2, float p3, float t)
{
    float t2 = t * t;
    float t3 = t2 * t;

    float b0 = (1.0 - t) * (1.0 - t) * (1.0 - t) / 6.0;
    float b1 = (3.0 * t3 - 6.0 * t2 + 4.0) / 6.0;
    float b2 = (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) / 6.0;
    float b3 = t3 / 6.0;

    return p0 * b0 + p1 * b1 + p2 * b2 + p3 * b3;
}

float nmc_catmullRom4(float p0, float p1, float p2, float p3, float t)
{
    return p1 + 0.5 * t * (p2 - p0 + t * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 +
           t * (3.0 * (p1 - p2) + p3 - p0)));
}

float nmc_blendLinearOrCosine(float a, float b, float amount, int nType)
{
    if (nType == 1)
    {
        return lerp(a, b, amount);
    }
    return lerp(a, b, smoothstep(0.0, 1.0, amount));
}

float nmc_bicubicValue(float2 st, float xFreq, float yFreq, float s)
{
    float x0y0 = nmc_constantOffset(st, xFreq, yFreq, s, int2(-1, -1));
    float x0y1 = nmc_constantOffset(st, xFreq, yFreq, s, int2(-1, 0));
    float x0y2 = nmc_constantOffset(st, xFreq, yFreq, s, int2(-1, 1));
    float x0y3 = nmc_constantOffset(st, xFreq, yFreq, s, int2(-1, 2));

    float x1y0 = nmc_constantOffset(st, xFreq, yFreq, s, int2(0, -1));
    float x1y1 = nmc_constantOffset(st, xFreq, yFreq, s, int2(0, 0));
    float x1y2 = nmc_constantOffset(st, xFreq, yFreq, s, int2(0, 1));
    float x1y3 = nmc_constantOffset(st, xFreq, yFreq, s, int2(0, 2));

    float x2y0 = nmc_constantOffset(st, xFreq, yFreq, s, int2(1, -1));
    float x2y1 = nmc_constantOffset(st, xFreq, yFreq, s, int2(1, 0));
    float x2y2 = nmc_constantOffset(st, xFreq, yFreq, s, int2(1, 1));
    float x2y3 = nmc_constantOffset(st, xFreq, yFreq, s, int2(1, 2));

    float x3y0 = nmc_constantOffset(st, xFreq, yFreq, s, int2(2, -1));
    float x3y1 = nmc_constantOffset(st, xFreq, yFreq, s, int2(2, 0));
    float x3y2 = nmc_constantOffset(st, xFreq, yFreq, s, int2(2, 1));
    float x3y3 = nmc_constantOffset(st, xFreq, yFreq, s, int2(2, 2));

    float2 uv = float2(st.x * xFreq, st.y * yFreq);

    float y0 = nmc_blendBicubic(x0y0, x1y0, x2y0, x3y0, frac(uv.x));
    float y1 = nmc_blendBicubic(x0y1, x1y1, x2y1, x3y1, frac(uv.x));
    float y2 = nmc_blendBicubic(x0y2, x1y2, x2y2, x3y2, frac(uv.x));
    float y3 = nmc_blendBicubic(x0y3, x1y3, x2y3, x3y3, frac(uv.x));

    return clamp(nmc_blendBicubic(y0, y1, y2, y3, frac(uv.y)), 0.0, 1.0);
}

float nmc_catmullRom4x4Value(float2 st, float xFreq, float yFreq, float s)
{
    float x0y0 = nmc_constantOffset(st, xFreq, yFreq, s, int2(-1, -1));
    float x0y1 = nmc_constantOffset(st, xFreq, yFreq, s, int2(-1, 0));
    float x0y2 = nmc_constantOffset(st, xFreq, yFreq, s, int2(-1, 1));
    float x0y3 = nmc_constantOffset(st, xFreq, yFreq, s, int2(-1, 2));

    float x1y0 = nmc_constantOffset(st, xFreq, yFreq, s, int2(0, -1));
    float x1y1 = nmc_constantOffset(st, xFreq, yFreq, s, int2(0, 0));
    float x1y2 = nmc_constantOffset(st, xFreq, yFreq, s, int2(0, 1));
    float x1y3 = nmc_constantOffset(st, xFreq, yFreq, s, int2(0, 2));

    float x2y0 = nmc_constantOffset(st, xFreq, yFreq, s, int2(1, -1));
    float x2y1 = nmc_constantOffset(st, xFreq, yFreq, s, int2(1, 0));
    float x2y2 = nmc_constantOffset(st, xFreq, yFreq, s, int2(1, 1));
    float x2y3 = nmc_constantOffset(st, xFreq, yFreq, s, int2(1, 2));

    float x3y0 = nmc_constantOffset(st, xFreq, yFreq, s, int2(2, -1));
    float x3y1 = nmc_constantOffset(st, xFreq, yFreq, s, int2(2, 0));
    float x3y2 = nmc_constantOffset(st, xFreq, yFreq, s, int2(2, 1));
    float x3y3 = nmc_constantOffset(st, xFreq, yFreq, s, int2(2, 2));

    float2 uv = float2(st.x * xFreq, st.y * yFreq);

    float y0 = nmc_catmullRom4(x0y0, x1y0, x2y0, x3y0, frac(uv.x));
    float y1 = nmc_catmullRom4(x0y1, x1y1, x2y1, x3y1, frac(uv.x));
    float y2 = nmc_catmullRom4(x0y2, x1y2, x2y2, x3y2, frac(uv.x));
    float y3 = nmc_catmullRom4(x0y3, x1y3, x2y3, x3y3, frac(uv.x));

    return clamp(nmc_catmullRom4(y0, y1, y2, y3, frac(uv.y)), 0.0, 1.0);
}

float nmc_value(float2 st, float xFreq, float yFreq, float s)
{
    [branch] if (NOISE_TYPE == 0)
    {
        return nmc_constant(st, xFreq, yFreq, s);
    }

    [branch] if (NOISE_TYPE == 3)
    {
        return nmc_catmullRom3x3Value(st, xFreq, yFreq, s);
    }

    [branch] if (NOISE_TYPE == 4)
    {
        return nmc_catmullRom4x4Value(st, xFreq, yFreq, s);
    }

    [branch] if (NOISE_TYPE == 5)
    {
        return nmc_quadratic3x3Value(st, xFreq, yFreq, s);
    }

    [branch] if (NOISE_TYPE == 6)
    {
        return nmc_bicubicValue(st, xFreq, yFreq, s);
    }

    [branch] if (NOISE_TYPE == 10)
    {
        float simplexLoopSample = nmc_simplexValue(st, xFreq, yFreq, s + 50.0, time) * speed * 0.0025;
        return nmc_simplexValue(st, xFreq, yFreq, s, simplexLoopSample);
    }

    [branch] if (NOISE_TYPE == 11)
    {
        float sineLoopSample = nmc_sineNoise(st, xFreq, yFreq, s + 50.0, time) * speed * 0.0025;
        return nmc_sineNoise(st, xFreq, yFreq, s, sineLoopSample);
    }

    // 1 = linear, 2 = hermite
    float x1y1 = nmc_constantOffset(st, xFreq, yFreq, s, int2(0, 0));
    float x1y2 = nmc_constantOffset(st, xFreq, yFreq, s, int2(0, 1));
    float x2y1 = nmc_constantOffset(st, xFreq, yFreq, s, int2(1, 0));
    float x2y2 = nmc_constantOffset(st, xFreq, yFreq, s, int2(1, 1));

    float2 uv = float2(st.x * xFreq, st.y * yFreq);

    float a = nmc_blendLinearOrCosine(x1y1, x2y1, frac(uv.x), NOISE_TYPE);
    float b = nmc_blendLinearOrCosine(x1y2, x2y2, frac(uv.x), NOISE_TYPE);

    return clamp(nmc_blendLinearOrCosine(a, b, frac(uv.y), NOISE_TYPE), 0.0, 1.0);
}

float3 nmc_noise(float2 st, float s)
{
    float freq = 1.0;
    if (NOISE_TYPE != 10 && wrap > 0)
    {
        freq = floor(nmc_map(noiseScale, 1.0, 100.0, 6.0, 2.0));
    }
    else
    {
        if (NOISE_TYPE == 10)
        {
            freq = nmc_map(noiseScale, 1.0, 100.0, 1.0, 0.5);
        }
        else
        {
            freq = nmc_map(noiseScale, 1.0, 100.0, 6.0, 1.0);
        }
    }

    float3 color = float3(
        nmc_value(st, freq, freq, 0.0 + s),
        nmc_value(st, freq, freq, 10.0 + s),
        nmc_value(st, freq, freq, 20.0 + s));

    // hue
    color.r = color.r * hueRange * 0.01;
    color.r += 1.0 - (hueRotation / 360.0);

    // saturation
    color.g *= 0.333;

    // brightness - ridges
    color.b = 1.0 - abs(color.b * 2.0 - 1.0);

    color = nmc_hsv2rgb(color);

    return color;
}

// =============================================================================
// nm_caustic — core per-pixel evaluation. `globalCoord` is the fragment pixel
// coordinate plus tileOffset (NM_GlobalCoord(i)). Mirrors WGSL main() exactly.
// st = (pos.xy + tileOffset) / fullResolution.y  (divides by HEIGHT only).
// =============================================================================
float4 nm_caustic(float2 globalCoord, float2 fullRes)
{
    float2 st = globalCoord / fullRes.y;
    st -= float2(fullRes.x / fullRes.y * 0.5, 0.5);

    float3 leftColor = nmc_noise(st, (float)seed);
    float3 rightColor = nmc_noise(st, (float)seed + 10.0);

    // "reflect" mode blend from coalesce
    float3 left = min(leftColor * rightColor / (1.0 - rightColor * leftColor), float3(1.0, 1.0, 1.0));
    float3 right = min(rightColor * leftColor / (1.0 - leftColor * rightColor), float3(1.0, 1.0, 1.0));

    return float4(nmc_brightnessContrast(lerp(left, right, 0.5)), 1.0);
}

#endif // NM_CAUSTIC_INCLUDED
