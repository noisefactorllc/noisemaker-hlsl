#ifndef NM_NOISE_INCLUDED
#define NM_NOISE_INCLUDED

// =============================================================================
// Noise.hlsl — classicNoisedeck/noise, ported PIXEL-IDENTICALLY from the
// canonical WGSL source:
//   shaders/effects/classicNoisedeck/noise/wgsl/noise.wgsl
//
// Animated multi-resolution noise synthesizer. Single render pass (program
// "noise"). Generator (no texture inputs).
//
// PORTING NOTES (per PORTING-GUIDE):
//  * All helpers are this effect's OWN versions, ported VERBATIM inline. Only
//    pcg/prng (nm_pcg/nm_prng), nm_mod, nm_positiveModulo, nm_map and
//    nm_periodicFunction come from NMCore. This effect's `modulo`, `map`,
//    `periodicFunction`, `prng`, `random`, `positiveModulo` are byte-identical
//    to the NMCore versions, so we reuse those primitives; `hsv2rgb`,
//    `rgb2hsv`, `rotate2D`, `getMetric`, `shape`, etc. are effect-specific and
//    copied inline here.
//  * st = (globalCoord) / fullResolution.y — DIVIDE BY HEIGHT (.y) only (H13).
//  * mat2x2<f32>(c,-s,s,c) is COLUMN-MAJOR -> M*v = (c*x + s*y, -s*x + c*y).
//    Written by hand to avoid HLSL row-major mul() transpose.
//  * atan2 arg order copied LITERALLY from WGSL.
//  * select(b,a,cond) -> cond ? a : b (WGSL select is reversed).
//  * bitcast<u32>(i) (jitter) -> asuint(i); vec3<u32>(p) (lattice) -> (uint3)p.
//  * Compile-time WGSL consts NOISE_TYPE/COLOR_MODE/REFRACT_MODE/LOOP_OFFSET/
//    METRIC become int uniforms branched with [branch] (defaults: NOISE_TYPE=10,
//    COLOR_MODE=6, REFRACT_MODE=2, LOOP_OFFSET=300, METRIC=0).
//  * Full 32-bit float; PCG and asuint(frac(s)) are bit-sensitive.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Compile-time WGSL consts, exposed as runtime int uniforms + [branch] ----
int NOISE_TYPE;     // global "type",        default 10 (simplex)
int COLOR_MODE;     // global "colorMode",   default 6  (hsv)
int REFRACT_MODE;   // global "refractMode", default 2  (colorTopology)
int LOOP_OFFSET;    // global "loopOffset",  default 300 (noise)
int METRIC;         // global "metric",      default 0  (circle)

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
float  xScale;         // default 75
float  yScale;         // default 75
float  seed;           // default 1  (i32 value, carried as float like WGSL)
float  loopScale;      // default 75
float  speed;          // default 25
int    octaves;        // default 2
float  ridges;         // boolean: >0.5 == true (default 0 == false)
float  wrap;           // boolean: >0.5 == true (default 1 == true)
float  refractAmt;     // default 0
float  kaleido;        // default 1
int    paletteMode;    // default 3
int    cyclePalette;   // default 1
float  rotatePalette;  // default 0
float  repeatPalette;  // default 1
float  hueRange;       // default 25
float  hueRotation;    // default 179
float3 paletteOffset;  // default (0.5,0.5,0.5)
float3 paletteAmp;     // default (0.5,0.5,0.5)
float3 paletteFreq;    // default (1,1,1)
float3 palettePhase;   // default (0.3,0.2,0.2)

// Local PI/TAU exactly as the WGSL declares them.
static const float NMN_PI  = 3.14159265359;
static const float NMN_TAU = 6.28318530718;

// ---- blendBicubic (cubic B-spline basis, uniform knots) ---------------------
float nmn_blendBicubic(float p0, float p1, float p2, float p3, float t)
{
    float t2 = t * t;
    float t3 = t2 * t;

    float b0 = (1.0 - t) * (1.0 - t) * (1.0 - t) / 6.0;
    float b1 = (3.0 * t3 - 6.0 * t2 + 4.0) / 6.0;
    float b2 = (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) / 6.0;
    float b3 = t3 / 6.0;

    return p0 * b0 + p1 * b1 + p2 * b2 + p3 * b3;
}

// ---- catmullRom3 (3-point, degree 3 — redundant terms reproduced literally) --
float nmn_catmullRom3(float p0, float p1, float p2, float t)
{
    float t2 = t * t;
    float t3 = t2 * t;

    return p1 + 0.5 * t * (p2 - p0) +
           0.5 * t2 * (2.0*p0 - 5.0*p1 + 4.0*p2 - p0) +
           0.5 * t3 * (-p0 + 3.0*p1 - 3.0*p2 + p0);
}

// ---- catmullRom4 (4-point, tension 0.5) -------------------------------------
float nmn_catmullRom4(float p0, float p1, float p2, float p3, float t)
{
    return p1 + 0.5 * t * (p2 - p0 + t * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 +
           t * (3.0 * (p1 - p2) + p3 - p0)));
}

// ---- blendLinearOrCosine ----------------------------------------------------
float nmn_blendLinearOrCosine(float a, float b, float amount, int interp)
{
    if (interp == 1) {
        return lerp(a, b, amount);
    }
    return lerp(a, b, smoothstep(0.0, 1.0, amount));
}

// ---- constantFromLatticeWithOffset ------------------------------------------
// `wrap` is the named uniform (bool via >0.5). bitcast<u32> -> asuint;
// vec3<u32>(...) of lattice coords -> (uint3) numeric truncation. The jitter
// hash uses asuint on the int cell coords / seed / sFrac (bit reinterpret).
float nmn_constantFromLatticeWithOffset(float2 lattice_in, float2 freq, float s, float blend, int2 offset)
{
    float2 baseFloor = floor(lattice_in);
    int2 cell = int2((int)baseFloor.x, (int)baseFloor.y) + offset;
    float2 fracv = lattice_in - baseFloor;

    int seedInt = (int)floor(s);
    float sFrac = frac(s);

    float xCombined = fracv.x + sFrac;
    int xi = cell.x + (int)floor(xCombined);
    int yi = cell.y;

    if (wrap > 0.5) {
        int freqX = (int)(freq.x + 0.5);
        int freqY = (int)(freq.y + 0.5);

        if (freqX > 0) {
            xi = nm_positiveModulo(xi, freqX);
        }
        if (freqY > 0) {
            yi = nm_positiveModulo(yi, freqY);
        }
    }

    uint xBits = asuint(xi);
    uint yBits = asuint(yi);
    uint seedBits = asuint(seedInt);
    uint fracBits = asuint(sFrac);

    uint3 jitter = uint3(
        (fracBits * 374761393u) ^ 0x9E3779B9u,
        (fracBits * 668265263u) ^ 0x7F4A7C15u,
        (fracBits * 2246822519u) ^ 0x94D049B4u
    );

    uint3 prngState = nm_pcg(uint3(xBits, yBits, seedBits) ^ jitter);
    float noiseValue = (float)prngState.x / 4294967295.0;

    return nm_periodicFunction(noiseValue - blend);
}

float nmn_constant(float2 st_in, float2 freq, float s, float blend)
{
    float2 lattice = st_in * freq;
    return nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2(0, 0));
}

float nmn_constantOffset(float2 lattice, float2 freq, float s, float blend, int2 offset)
{
    return nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, offset);
}

float3 nmn_mod289_3(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float2 nmn_mod289_2(float2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float3 nmn_permute3(float3 x) { return nmn_mod289_3(((x * 34.0) + 1.0) * x); }

// ---- quadratic3 (degree-2 B-spline) -----------------------------------------
float nmn_quadratic3(float p0, float p1, float p2, float t)
{
    float t2 = t * t;
    return p0 * 0.5 * (1.0 - t) * (1.0 - t) +
           p1 * 0.5 * (-2.0 * t2 + 2.0 * t + 1.0) +
           p2 * 0.5 * t2;
}

float nmn_cubic3x3ValueNoise(float2 st, float2 freq, float s, float blend)
{
    float2 lattice = st * freq;
    float2 f = frac(lattice);

    float v00 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2(-1, -1));
    float v10 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2( 0, -1));
    float v20 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2( 1, -1));

    float v01 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2(-1,  0));
    float v11 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2( 0,  0));
    float v21 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2( 1,  0));

    float v02 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2(-1,  1));
    float v12 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2( 0,  1));
    float v22 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2( 1,  1));

    float y0 = nmn_quadratic3(v00, v10, v20, f.x);
    float y1 = nmn_quadratic3(v01, v11, v21, f.x);
    float y2 = nmn_quadratic3(v02, v12, v22, f.x);

    return nmn_quadratic3(y0, y1, y2, f.y);
}

float nmn_bicubicValue(float2 st, float2 freq, float s, float blend)
{
    float2 lattice = st * freq;

    float x0y0 = nmn_constantOffset(lattice, freq, s, blend, int2(-1, -1));
    float x0y1 = nmn_constantOffset(lattice, freq, s, blend, int2(-1, 0));
    float x0y2 = nmn_constantOffset(lattice, freq, s, blend, int2(-1, 1));
    float x0y3 = nmn_constantOffset(lattice, freq, s, blend, int2(-1, 2));

    float x1y0 = nmn_constantOffset(lattice, freq, s, blend, int2(0, -1));
    float x1y1 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2(0, 0));
    float x1y2 = nmn_constantOffset(lattice, freq, s, blend, int2(0, 1));
    float x1y3 = nmn_constantOffset(lattice, freq, s, blend, int2(0, 2));

    float x2y0 = nmn_constantOffset(lattice, freq, s, blend, int2(1, -1));
    float x2y1 = nmn_constantOffset(lattice, freq, s, blend, int2(1, 0));
    float x2y2 = nmn_constantOffset(lattice, freq, s, blend, int2(1, 1));
    float x2y3 = nmn_constantOffset(lattice, freq, s, blend, int2(1, 2));

    float x3y0 = nmn_constantOffset(lattice, freq, s, blend, int2(2, -1));
    float x3y1 = nmn_constantOffset(lattice, freq, s, blend, int2(2, 0));
    float x3y2 = nmn_constantOffset(lattice, freq, s, blend, int2(2, 1));
    float x3y3 = nmn_constantOffset(lattice, freq, s, blend, int2(2, 2));

    float2 fracv = frac(lattice);

    float y0 = nmn_blendBicubic(x0y0, x1y0, x2y0, x3y0, fracv.x);
    float y1 = nmn_blendBicubic(x0y1, x1y1, x2y1, x3y1, fracv.x);
    float y2 = nmn_blendBicubic(x0y2, x1y2, x2y2, x3y2, fracv.x);
    float y3 = nmn_blendBicubic(x0y3, x1y3, x2y3, x3y3, fracv.x);

    return nmn_blendBicubic(y0, y1, y2, y3, fracv.y);
}

// 3×3 Catmull-Rom value noise
float nmn_catmullRom3x3ValueNoise(float2 st, float2 freq, float s, float blend)
{
    float2 lattice = float2(st.x * freq.x + s, st.y * freq.y);

    float x0y0 = nmn_constantOffset(lattice, freq, s, blend, int2(-1, -1));
    float x0y1 = nmn_constantOffset(lattice, freq, s, blend, int2(-1, 0));
    float x0y2 = nmn_constantOffset(lattice, freq, s, blend, int2(-1, 1));

    float x1y0 = nmn_constantOffset(lattice, freq, s, blend, int2(0, -1));
    float x1y1 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2(0, 0));
    float x1y2 = nmn_constantOffset(lattice, freq, s, blend, int2(0, 1));

    float x2y0 = nmn_constantOffset(lattice, freq, s, blend, int2(1, -1));
    float x2y1 = nmn_constantOffset(lattice, freq, s, blend, int2(1, 0));
    float x2y2 = nmn_constantOffset(lattice, freq, s, blend, int2(1, 1));

    float2 fracv = frac(lattice);

    float y0 = nmn_catmullRom3(x0y0, x1y0, x2y0, fracv.x);
    float y1 = nmn_catmullRom3(x0y1, x1y1, x2y1, fracv.x);
    float y2 = nmn_catmullRom3(x0y2, x1y2, x2y2, fracv.x);

    return nmn_catmullRom3(y0, y1, y2, fracv.y);
}

// 4×4 Catmull-Rom value noise
float nmn_catmullRom4x4ValueNoise(float2 st, float2 freq, float s, float blend)
{
    float2 lattice = float2(st.x * freq.x + s, st.y * freq.y);

    float x0y0 = nmn_constantOffset(lattice, freq, s, blend, int2(-1, -1));
    float x0y1 = nmn_constantOffset(lattice, freq, s, blend, int2(-1, 0));
    float x0y2 = nmn_constantOffset(lattice, freq, s, blend, int2(-1, 1));
    float x0y3 = nmn_constantOffset(lattice, freq, s, blend, int2(-1, 2));

    float x1y0 = nmn_constantOffset(lattice, freq, s, blend, int2(0, -1));
    float x1y1 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2(0, 0));
    float x1y2 = nmn_constantOffset(lattice, freq, s, blend, int2(0, 1));
    float x1y3 = nmn_constantOffset(lattice, freq, s, blend, int2(0, 2));

    float x2y0 = nmn_constantOffset(lattice, freq, s, blend, int2(1, -1));
    float x2y1 = nmn_constantOffset(lattice, freq, s, blend, int2(1, 0));
    float x2y2 = nmn_constantOffset(lattice, freq, s, blend, int2(1, 1));
    float x2y3 = nmn_constantOffset(lattice, freq, s, blend, int2(1, 2));

    float x3y0 = nmn_constantOffset(lattice, freq, s, blend, int2(2, -1));
    float x3y1 = nmn_constantOffset(lattice, freq, s, blend, int2(2, 0));
    float x3y2 = nmn_constantOffset(lattice, freq, s, blend, int2(2, 1));
    float x3y3 = nmn_constantOffset(lattice, freq, s, blend, int2(2, 2));

    float2 fracv = frac(lattice);

    float y0 = nmn_catmullRom4(x0y0, x1y0, x2y0, x3y0, fracv.x);
    float y1 = nmn_catmullRom4(x0y1, x1y1, x2y1, x3y1, fracv.x);
    float y2 = nmn_catmullRom4(x0y2, x1y2, x2y2, x3y2, fracv.x);
    float y3 = nmn_catmullRom4(x0y3, x1y3, x2y3, x3y3, fracv.x);

    return nmn_catmullRom4(y0, y1, y2, y3, fracv.y);
}

float nmn_simplexValue(float2 st_in, float2 freq, float s, float blend)
{
    const float4 C = float4(
        0.211324865405187,
        0.366025403784439,
        -0.577350269189626,
        0.024390243902439
    );

    float2 uv = float2(st_in.x * freq.x, st_in.y * freq.y);
    uv.x = uv.x + s;

    float2 i = floor(uv + dot(uv, C.yy));
    float2 x0 = uv - i + dot(i, C.xx);

    // WGSL: select(vec2(0,1), vec2(1,0), x0.x > x0.y) -> cond ? (1,0) : (0,1)
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float2 x1 = x0 - i1 + float2(C.x, C.x);
    float2 x2 = x0 - float2(1.0, 1.0) + float2(2.0 * C.x, 2.0 * C.x);

    i = nmn_mod289_2(i);
    float3 p = nmn_permute3(nmn_permute3(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));

    float3 m = max(float3(0.5, 0.5, 0.5) - float3(dot(x0, x0), dot(x1, x1), dot(x2, x2)), float3(0.0, 0.0, 0.0));
    m = m * m;
    m = m * m;

    float3 x = 2.0 * frac(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;

    m = m * (1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h));

    float3 g = float3(0.0, 0.0, 0.0);
    g.x = a0.x * x0.x + h.x * x0.y;
    float2 gyz = a0.yz * float2(x1.x, x2.x) + h.yz * float2(x1.y, x2.y);
    g.y = gyz.x;
    g.z = gyz.y;

    float v = 130.0 * dot(m, g);
    return nm_periodicFunction(nm_map(v, -1.0, 1.0, 0.0, 1.0) - blend);
}

float nmn_sineNoise(float2 st_in, float2 freq, float s, float blend)
{
    float2 st = st_in * freq;
    st.x = st.x + s;

    float a = blend;
    float b = blend;
    float c = 1.0 - blend;

    float3 r1 = nm_prng(float3(s, s, s)) * 0.75 + float3(0.125, 0.125, 0.125);
    float3 r2 = nm_prng(float3(s + 10.0, s + 10.0, s + 10.0)) * 0.75 + float3(0.125, 0.125, 0.125);
    float x = sin(r1.x * st.y + sin(r1.y * st.x + a) + sin(r1.z * st.x + b) + c);
    float y = sin(r2.x * st.x + sin(r2.y * st.y + b) + sin(r2.z * st.y + c) + a);
    return (x + y) * 0.5 + 0.5;
}

float nmn_value(float2 st, float2 freq, float s, float blend)
{
    if (NOISE_TYPE == 3) {
        return nmn_catmullRom3x3ValueNoise(st, freq, s, blend);
    } else if (NOISE_TYPE == 4) {
        return nmn_catmullRom4x4ValueNoise(st, freq, s, blend);
    } else if (NOISE_TYPE == 5) {
        return nmn_cubic3x3ValueNoise(st, freq, s, blend);
    } else if (NOISE_TYPE == 6) {
        return nmn_bicubicValue(st, freq, s, blend);
    } else if (NOISE_TYPE == 10) {
        return nmn_simplexValue(st, freq, s, blend);
    } else if (NOISE_TYPE == 11) {
        return nmn_sineNoise(st, freq, s, blend);
    }

    float2 lattice = st * freq;
    float x1y1 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2(0, 0));
    if (NOISE_TYPE == 0) {
        return x1y1;
    }

    float x2y1 = nmn_constantOffset(lattice, freq, s, blend, int2(1, 0));
    float x1y2 = nmn_constantOffset(lattice, freq, s, blend, int2(0, 1));
    float x2y2 = nmn_constantOffset(lattice, freq, s, blend, int2(1, 1));

    float2 fracv = frac(lattice);
    float a = nmn_blendLinearOrCosine(x1y1, x2y1, fracv.x, NOISE_TYPE);
    float b = nmn_blendLinearOrCosine(x1y2, x2y2, fracv.x, NOISE_TYPE);
    return nmn_blendLinearOrCosine(a, b, fracv.y, NOISE_TYPE);
}

float nmn_circles(float2 st, float freq)
{
    float dist = length(st - float2(0.5 * aspectRatio, 0.5));
    return dist * freq;
}

float nmn_rings(float2 st, float freq)
{
    float dist = length(st - float2(0.5 * aspectRatio, 0.5));
    return cos(dist * NMN_PI * freq);
}

float nmn_diamonds(float2 st_in, float freq)
{
    float2 st = st_in - float2(0.5 * aspectRatio, 0.5);
    st = st * freq;
    return cos(st.x * NMN_PI) + cos(st.y * NMN_PI);
}

// WGSL atan2(st.x, st.y) — arg order copied LITERALLY.
float nmn_shape(float2 st_in, int sides, float blend)
{
    float2 st = st_in * 2.0 - float2(aspectRatio, 1.0);
    float a = atan2(st.x, st.y) + NMN_PI;
    float r = NMN_TAU / (float)sides;
    return cos(floor(0.5 + a / r) * r - a) * length(st) * blend;
}

float nmn_getMetric(float2 st_in)
{
    float2 st = st_in;
    float2 diff = float2(0.5 * aspectRatio, 0.5) - st;
    float r = 1.0;
    if (METRIC == 0) {
        r = length(st - float2(0.5 * aspectRatio, 0.5));
    } else if (METRIC == 1) {
        r = abs(diff.x) + abs(diff.y);
    } else if (METRIC == 2) {
        r = max(max(abs(diff.x) - diff.y * -0.5, -1.0 * diff.y), max(abs(diff.x) - diff.y * 0.5, diff.y));
    } else if (METRIC == 3) {
        r = max((abs(diff.x) + abs(diff.y)) / sqrt(2.0), max(abs(diff.x), abs(diff.y)));
    } else if (METRIC == 4) {
        r = max(abs(diff.x), abs(diff.y));
    } else if (METRIC == 5) {
        r = max(abs(diff.x) - diff.y * -0.5, -1.0 * diff.y);
    }
    return r;
}

// WGSL mat2x2<f32>(c,-s,s,c) column-major -> M*v = (c*x + s*y, -s*x + c*y).
float2 nmn_rotate2D(float2 st, float rot)
{
    float angle = rot * NMN_PI;
    float c = cos(angle);
    float s = sin(angle);
    return float2(c * st.x + s * st.y, -s * st.x + c * st.y);
}

// WGSL atan2(st.y, st.x) — arg order copied LITERALLY.
float2 nmn_kaleidoscope(float2 st_in, float sides, float blendy)
{
    if (sides == 1.0) {
        return st_in;
    }
    float r = nmn_getMetric(st_in) + blendy;
    float2 st = st_in - float2(0.5 * aspectRatio, 0.5);
    st = nmn_rotate2D(st, 0.5);
    float a = atan2(st.y, st.x);
    float ma = abs(nm_mod(a - radians(360.0 / sides), NMN_TAU / sides) - NMN_PI / sides);
    return r * float2(cos(ma), sin(ma));
}

float3 nmn_hsv2rgb(float3 hsv)
{
    float h = frac(hsv.x);
    float s = hsv.y;
    float v = hsv.z;

    float c = v * s;
    float h6 = h * 6.0;
    float k = h6 - 2.0 * floor(h6 / 2.0);
    float x = c * (1.0 - abs(k - 1.0));
    float m = v - c;

    float3 rgb = float3(0.0, 0.0, 0.0);
    if (h6 < 1.0) {
        rgb = float3(c, x, 0.0);
    } else if (h6 < 2.0) {
        rgb = float3(x, c, 0.0);
    } else if (h6 < 3.0) {
        rgb = float3(0.0, c, x);
    } else if (h6 < 4.0) {
        rgb = float3(0.0, x, c);
    } else if (h6 < 5.0) {
        rgb = float3(x, 0.0, c);
    } else {
        rgb = float3(c, 0.0, x);
    }
    return rgb + float3(m, m, m);
}

float3 nmn_rgb2hsv(float3 rgb)
{
    float r = rgb.x;
    float g = rgb.y;
    float b = rgb.z;
    float maxc = max(r, max(g, b));
    float minc = min(r, min(g, b));
    float delta = maxc - minc;

    float h = 0.0;
    if (delta != 0.0) {
        if (maxc == r) {
            h = nm_mod((g - b) / delta, 6.0) / 6.0;
        } else if (maxc == g) {
            h = ((b - r) / delta + 2.0) / 6.0;
        } else {
            h = ((r - g) / delta + 4.0) / 6.0;
        }
    }

    // WGSL: select(delta/maxc, 0.0, maxc == 0.0) -> (maxc == 0.0) ? 0.0 : delta/maxc
    float s = (maxc == 0.0) ? 0.0 : delta / maxc;
    float v = maxc;
    return float3(h, s, v);
}

float3 nmn_linearToSrgb(float3 linearC)
{
    float3 srgb = float3(0.0, 0.0, 0.0);
    [unroll]
    for (int i = 0; i < 3; i = i + 1) {
        if (linearC[i] <= 0.0031308) {
            srgb[i] = linearC[i] * 12.92;
        } else {
            srgb[i] = 1.055 * pow(linearC[i], 1.0 / 2.4) - 0.055;
        }
    }
    return srgb;
}

float3 nmn_srgbToLinear(float3 srgb)
{
    float3 linearC = float3(0.0, 0.0, 0.0);
    [unroll]
    for (int i = 0; i < 3; i = i + 1) {
        if (srgb[i] <= 0.04045) {
            linearC[i] = srgb[i] / 12.92;
        } else {
            linearC[i] = pow((srgb[i] + 0.055) / 1.055, 2.4);
        }
    }
    return linearC;
}

// WGSL mat3x3<f32> ctor takes COLUMNS. fwdA columns:
//   col0=(1,1,1) col1=(0.3963377774,-0.1055613458,-0.0894841775)
//   col2=(0.2158037573,-0.0638541728,-1.2914855480)
// M*c = col0*c.x + col1*c.y + col2*c.z. Written by hand to avoid HLSL mul()
// row-major transpose.
float3 nmn_linear_srgb_from_oklab(float3 c)
{
    // lms = fwdA * c
    float3 col0 = float3(1.0, 1.0, 1.0);
    float3 col1 = float3(0.3963377774, -0.1055613458, -0.0894841775);
    float3 col2 = float3(0.2158037573, -0.0638541728, -1.2914855480);
    float3 lms = col0 * c.x + col1 * c.y + col2 * c.z;
    lms = lms * lms * lms;
    // fwdB * lms
    float3 b0 = float3(4.0767245293, -1.2681437731, -0.0041119885);
    float3 b1 = float3(-3.3072168827, 2.6093323231, -0.7034763098);
    float3 b2 = float3(0.2307590544, -0.3411344290, 1.7068625689);
    return b0 * lms.x + b1 * lms.y + b2 * lms.z;
}

float3 nmn_oklab_from_linear_srgb(float3 c)
{
    // invB * c
    float3 ib0 = float3(0.4121656120, 0.2118591070, 0.0883097947);
    float3 ib1 = float3(0.5362752080, 0.6807189584, 0.2818474174);
    float3 ib2 = float3(0.0514575653, 0.1074065790, 0.6302613616);
    float3 lms = ib0 * c.x + ib1 * c.y + ib2 * c.z;
    float3 t = sign(lms) * pow(abs(lms), float3(0.3333333333333, 0.3333333333333, 0.3333333333333));
    // invA * t
    float3 ia0 = float3(0.2104542553, 1.9779984951, 0.0259040371);
    float3 ia1 = float3(0.7936177850, -2.4285922050, 0.7827717662);
    float3 ia2 = float3(-0.0040720468, 0.4505937099, -0.8086757660);
    return ia0 * t.x + ia1 * t.y + ia2 * t.z;
}

float3 nmn_pal(float t_in)
{
    float t = t_in * repeatPalette + rotatePalette * 0.01;
    float3 color = paletteOffset + paletteAmp * cos(6.28318 * (paletteFreq * t + palettePhase));

    if (paletteMode == 1) {
        color = nmn_hsv2rgb(color);
    } else if (paletteMode == 2) {
        color.y = color.y * -0.509 + 0.276;
        color.z = color.z * -0.509 + 0.198;
        color = nmn_linear_srgb_from_oklab(color);
        color = nmn_linearToSrgb(color);
    }

    return color;
}

float3 nmn_generate_octave(float2 st, float2 freq, float s, float blend, float octave)
{
    float3 layer = float3(
        nmn_value(st, freq, seed + 10.0 * octave, blend),
        nmn_value(st, freq, seed + 20.0 * octave, blend),
        nmn_value(st, freq, seed + 30.0 * octave, blend)
    );
    if (ridges > 0.5 && COLOR_MODE == 6) {
        layer.z = 1.0 - abs(layer.z * 2.0 - 1.0);
    }
    return layer;
}

float3 nmn_multires(float2 st_in, float2 freq, int oct, float s, float blend)
{
    float2 st = st_in;
    float3 color = float3(0.0, 0.0, 0.0);
    float multiplicand = 0.0;
    float2 nominalFreq = float2(0.0, 0.0);
    if (NOISE_TYPE == 11) {
        float base = nm_map(75.0, 1.0, 100.0, 40.0, 1.0);
        nominalFreq = float2(base, base);
    } else if (NOISE_TYPE == 10) {
        float base = nm_map(75.0, 1.0, 100.0, 6.0, 0.5);
        nominalFreq = float2(base, base);
    } else {
        float base = nm_map(75.0, 1.0, 100.0, 20.0, 3.0);
        nominalFreq = float2(base, base);
    }

    int total = max(oct, 1);
    [loop]
    for (int i = 1; i <= total; i = i + 1) {
        float multiplier = pow(2.0, (float)i);
        float2 baseFreq = freq * 0.5 * multiplier;
        float nominalBase = nominalFreq.x * 0.5 * multiplier;
        multiplicand = multiplicand + 1.0 / multiplier;

        if (REFRACT_MODE == 1 || REFRACT_MODE == 2) {
            float2 xRefractFreq = float2(baseFreq.x, nominalBase);
            float2 yRefractFreq = float2(nominalBase, baseFreq.y);
            float xRef = nmn_value(st, xRefractFreq, s + 10.0 * (float)i, blend) - 0.5;
            float yRef = nmn_value(st, yRefractFreq, s + 20.0 * (float)i, blend) - 0.5;
            float refraction = nm_map(refractAmt, 0.0, 100.0, 0.0, 1.0) / multiplier;
            st = float2(st.x + xRef * refraction, st.y + yRef * refraction);
        }

        float3 layer = nmn_generate_octave(st, baseFreq, s + 10.0 * (float)i, blend, (float)i);

        if (REFRACT_MODE == 0 || REFRACT_MODE == 2) {
            float xOff = cos(layer.z) * 0.5 + 0.5;
            float yOff = sin(layer.z) * 0.5 + 0.5;
            float3 refLayer = nmn_generate_octave(float2(st.x + xOff, st.y + yOff), baseFreq, s + 15.0 * (float)i, blend, (float)i);
            float amt = nm_map(refractAmt, 0.0, 100.0, 0.0, 1.0);
            layer = lerp(layer, refLayer, float3(amt, amt, amt));
        }

        color = color + layer / multiplier;
    }

    color = color / multiplicand;

    float3 result = color;
    if (COLOR_MODE == 0) {
        if (ridges > 0.5) {
            result.z = 1.0 - abs(result.z * 2.0 - 1.0);
        }
        result = float3(result.z, result.z, result.z);
    } else if (COLOR_MODE == 1) {
        result = nmn_srgbToLinear(result);
    } else if (COLOR_MODE == 2) {
        // srgb, no change
    } else if (COLOR_MODE == 3) {
        result.y = result.y * -0.509 + 0.276;
        result.z = result.z * -0.509 + 0.198;
        result = nmn_linear_srgb_from_oklab(result);
        result = nmn_linearToSrgb(result);
    } else if (COLOR_MODE == 4) {
        if (ridges > 0.5) {
            result.z = 1.0 - abs(result.z * 2.0 - 1.0);
        }
        float d = result.z;
        if (cyclePalette == -1) {
            d = d + time;
        } else if (cyclePalette == 1) {
            d = d - time;
        }
        result = nmn_pal(d);
    } else {
        float3 hsv = result;
        hsv.x = hsv.x * hueRange * 0.01;
        hsv.x = hsv.x + 1.0 - (hueRotation / 360.0);
        result = nmn_hsv2rgb(hsv);
    }

    if (COLOR_MODE != 4 && COLOR_MODE != 6) {
        float3 hsv = nmn_rgb2hsv(result);
        hsv.x = hsv.x + 1.0 - (hueRotation / 360.0);
        hsv.x = frac(hsv.x);
        if (ridges > 0.5 && (COLOR_MODE == 1 || COLOR_MODE == 2 || COLOR_MODE == 3)) {
            hsv.z = 1.0 - abs(hsv.z * 2.0 - 1.0);
        }
        result = nmn_hsv2rgb(hsv);
    }

    return result;
}

float nmn_offset(float2 st_in, float2 freq)
{
    if (LOOP_OFFSET == 10) {
        return nmn_circles(st_in, freq.x);
    } else if (LOOP_OFFSET == 20) {
        return nmn_shape(st_in, 3, freq.x * 0.5);
    } else if (LOOP_OFFSET == 30) {
        return (abs(st_in.x - 0.5 * aspectRatio) + abs(st_in.y - 0.5)) * freq.x * 0.5;
    } else if (LOOP_OFFSET == 40) {
        return nmn_shape(st_in, 4, freq.x * 0.5);
    } else if (LOOP_OFFSET == 50) {
        return nmn_shape(st_in, 5, freq.x * 0.5);
    } else if (LOOP_OFFSET == 60) {
        return nmn_shape(st_in, 6, freq.x * 0.5);
    } else if (LOOP_OFFSET == 70) {
        return nmn_shape(st_in, 7, freq.x * 0.5);
    } else if (LOOP_OFFSET == 80) {
        return nmn_shape(st_in, 8, freq.x * 0.5);
    } else if (LOOP_OFFSET == 90) {
        return nmn_shape(st_in, 9, freq.x * 0.5);
    } else if (LOOP_OFFSET == 100) {
        return nmn_shape(st_in, 10, freq.x * 0.5);
    } else if (LOOP_OFFSET == 110) {
        return nmn_shape(st_in, 11, freq.x * 0.5);
    } else if (LOOP_OFFSET == 120) {
        return nmn_shape(st_in, 12, freq.x * 0.5);
    } else if (LOOP_OFFSET == 200) {
        return st_in.x * freq.x * 0.5;
    } else if (LOOP_OFFSET == 210) {
        return st_in.y * freq.x * 0.5;
    } else if (LOOP_OFFSET == 300) {
        float2 st = st_in - float2(aspectRatio * 0.5, 0.5);
        return nmn_value(st, freq, seed + 50.0, 0.0);
    } else if (LOOP_OFFSET == 400) {
        return 1.0 - nmn_rings(st_in, freq.x);
    } else if (LOOP_OFFSET == 410) {
        return 1.0 - nmn_diamonds(st_in, freq.x);
    }
    return 0.0;
}

// =============================================================================
// nm_noise — core per-pixel evaluation. Mirrors WGSL main() exactly.
// globalCoord = NM_GlobalCoord(i) = pos.xy + tileOffset. Returns RGBA.
// =============================================================================
float4 nm_noise(float2 globalCoord)
{
    float2 st = globalCoord / fullResolution.y;   // DIVIDE BY HEIGHT (.y) only
    st = nmn_kaleidoscope(st, kaleido, 0.5);
    float2 centered = st - float2(aspectRatio * 0.5, 0.5);

    float2 freq = float2(1.0, 1.0);
    float2 lf = float2(1.0, 1.0);

    if (NOISE_TYPE == 11) {
        freq.x = nm_map(xScale, 1.0, 100.0, 40.0, 1.0);
        freq.y = nm_map(yScale, 1.0, 100.0, 40.0, 1.0);
        float val = nm_map(loopScale, 1.0, 100.0, 10.0, 1.0);
        lf = float2(val, val);
    } else if (NOISE_TYPE == 10) {
        freq.x = nm_map(xScale, 1.0, 100.0, 6.0, 0.5);
        freq.y = nm_map(yScale, 1.0, 100.0, 6.0, 0.5);
        float val = nm_map(loopScale, 1.0, 100.0, 6.0, 0.5);
        lf = float2(val, val);
    } else {
        freq.x = nm_map(xScale, 1.0, 100.0, 20.0, 3.0);
        freq.y = nm_map(yScale, 1.0, 100.0, 20.0, 3.0);
        float val = nm_map(loopScale, 1.0, 100.0, 12.0, 3.0);
        lf = float2(val, val);
    }

    if (LOOP_OFFSET == 300) {
        float2 nominalFreq = float2(1.0, 1.0);
        if (NOISE_TYPE == 11) {
            float base = nm_map(75.0, 1.0, 100.0, 40.0, 1.0);
            nominalFreq = float2(base, base);
        } else if (NOISE_TYPE == 10) {
            float base = nm_map(75.0, 1.0, 100.0, 6.0, 0.5);
            nominalFreq = float2(base, base);
        } else {
            float base = nm_map(75.0, 1.0, 100.0, 20.0, 3.0);
            nominalFreq = float2(base, base);
        }
        lf = lf * (freq / nominalFreq);
    }

    if (NOISE_TYPE != 4 && NOISE_TYPE != 10 && wrap > 0.5) {
        freq = floor(freq);
        if (LOOP_OFFSET == 300) {
            lf = floor(lf);
        }
    }

    float t = 1.0;
    if (speed < 0.0) {
        t = time + nmn_offset(st, lf);
    } else {
        t = time - nmn_offset(st, lf);
    }
    float blend = nm_periodicFunction(t) * abs(speed) * 0.01;

    float3 colorRgb = nmn_multires(centered, freq, octaves, seed, blend);
    return float4(colorRgb, 1.0);
}

#endif // NM_NOISE_INCLUDED
