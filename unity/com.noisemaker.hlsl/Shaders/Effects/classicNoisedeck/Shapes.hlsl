#ifndef NM_SHAPES_INCLUDED
#define NM_SHAPES_INCLUDED

// =============================================================================
// Shapes.hlsl — classicNoisedeck/shapes, ported PIXEL-IDENTICALLY from the
// canonical WGSL source:
//   shaders/effects/classicNoisedeck/shapes/wgsl/shapes.wgsl
//
// Generator (no input textures). Single render pass "shapes". Produces
// interference patterns from two geometric/noise primitives blended through a
// procedural palette.
//
// PORTING NOTES (PORTING-GUIDE compliance):
//  * Helpers ported VERBATIM and INLINE. This effect's `periodicFunction` uses
//    sin(): map(sin(TAU*p), -1, 1, 0, 1). It DIFFERS from NMCore's
//    nm_periodicFunction (which uses cos), so we reproduce the sin version here
//    and do NOT call the core one.
//  * `modulo`/`map` are this effect's own copies (identical in form to nm_mod /
//    nm_map but kept inline to match the source 1:1).
//  * pcg/prng reproduced inline exactly as the WGSL declares (fold variant,
//    divisor 4294967295.0 = float(0xffffffffu); (uint3)p is float->uint
//    truncation, NOT asuint).
//  * rotate2D is declared by the WGSL but UNUSED by main(); ported anyway for
//    completeness (it reads `aspectRatio`).
//  * `random(vec2)` in the WGSL is also unused by main(); omitted.
//  * LOOP_A_OFFSET / LOOP_B_OFFSET were WGSL compile-time consts. Per
//    PORTING-GUIDE they are NOT correctness-relevant: declared as int uniforms
//    and branched at runtime. The runtime binds them via mpb.SetInt under their
//    `define` macro name (definition.js globals[*].define = "LOOP_A_OFFSET" /
//    "LOOP_B_OFFSET"), so the HLSL uniforms MUST use those exact names (matches
//    synth/Shape.hlsl). Declaring camelCase loopAOffset/loopBOffset leaves them
//    unset (read 0) -> every offset() falls through to 0 -> flat fill.
//  * atan2 arg order copied literally: WGSL atan2(st2.x, st2.y) -> HLSL
//    atan2(st2.x, st2.y).
//  * select() reversed-arg form translated to HLSL ternary literally.
//  * mat2x2<f32>(c,-s,s,c) is column-major: M*v = (c*x + s*y, -s*x + c*y).
//  * st = pos.xy / resolution.y — DIVIDE BY HEIGHT ONLY (matches WGSL main()).
//    Using fullResolution.y here to match the engine's globalCoord convention.
//  * Full 32-bit float throughout (PCG bit-sensitive).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
// Only the compile-time defines (LOOP_A_OFFSET/LOOP_B_OFFSET) are bound via
// SetInt under their `define` macro name (NOT the camelCase global key);
// EVERY other named uniform is bound by the runtime as a FLOAT (UniformBinder
// uses mpb.SetFloat for Number AND Bool). An int-declared HLSL uniform fed by
// SetFloat never receives its value (reads 0/garbage), so all scalar params
// MUST be declared float and cast to int at use sites (matches Noise.hlsl).
int    LOOP_A_OFFSET;   // WGSL compile-time LOOP_A_OFFSET (default 40) — SetInt
int    LOOP_B_OFFSET;   // WGSL compile-time LOOP_B_OFFSET (default 30) — SetInt
float  loopAScale;      // [1,100]
float  loopBScale;      // [1,100]
float  speedA;          // [-100,100]
float  speedB;          // [-100,100]
float  seed;            // [1,100] (i32 value carried as float like WGSL)
float  wrap;            // boolean: tested > 0.5 (1.0/0.0)
float  paletteMode;     // 0 = rgb, 1 = hsv, 2 = oklab
float3 paletteOffset;   // default (0.83, 0.6, 0.63)
float3 paletteAmp;      // default (0.5, 0.5, 0.5)
float3 paletteFreq;     // default (1, 1, 1)
float3 palettePhase;    // default (0.3, 0.1, 0)
float  cyclePalette;    // -1 backward, 0 off, 1 forward
float  rotatePalette;   // [0,100]
float  repeatPalette;   // [1,10] (i32 value carried as float)

// Local PI/TAU literals exactly as the WGSL declares them.
static const float NMS_PI  = 3.14159265359;
static const float NMS_TAU = 6.28318530718;

// modulo(a,b) — this effect's own copy: a - b*floor(a/b)  (== nm_mod).
float nms_modulo(float a, float b)
{
    return a - b * floor(a / b);
}

// map(value,inMin,inMax,outMin,outMax) — affine remap, no clamp.
float nms_map(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

// pcg PRNG (verbatim; this WGSL inlines its own copy).
uint3 nms_pcg(uint3 v_in)
{
    uint3 v = v_in * 1664525u + 1013904223u;
    v.x = v.x + v.y * v.z;
    v.y = v.y + v.z * v.x;
    v.z = v.z + v.x * v.y;
    v = v ^ (v >> 16u);
    v.x = v.x + v.y * v.z;
    v.y = v.y + v.z * v.x;
    v.z = v.z + v.x * v.y;
    return v;
}

// prng (fold variant; divisor 4294967295.0 = float(0xffffffffu)).
// (uint3)p is float->uint truncation toward zero (NOT asuint).
float3 nms_prng(float3 p0)
{
    float3 p = p0;
    p.x = (p.x >= 0.0) ? p.x * 2.0 : -p.x * 2.0 + 1.0;
    p.y = (p.y >= 0.0) ? p.y * 2.0 : -p.y * 2.0 + 1.0;
    p.z = (p.z >= 0.0) ? p.z * 2.0 : -p.z * 2.0 + 1.0;
    uint3 u = nms_pcg((uint3)p);
    return float3(u) / 4294967295.0;
}

// periodicFunction(p) = map(sin(TAU*p), -1, 1, 0, 1)  (sin, NOT cos).
float nms_periodicFunction(float p)
{
    float x = NMS_TAU * p;
    return nms_map(sin(x), -1.0, 1.0, 0.0, 1.0);
}

// constant() — hashed lattice value with looping time. Reads globals wrap/seed/time.
float nms_constant(float2 st_in, float freq, float speed)
{
    float x = st_in.x * freq;
    float y = st_in.y * freq;
    if (wrap > 0.5)
    {
        x = nms_modulo(x, freq);
        y = nms_modulo(y, freq);
    }
    x = x + (float)seed;
    float3 rand = nms_prng(float3(floor(float2(x, y)), (float)seed));
    float scaledTime = nms_periodicFunction(rand.x - time) * nms_map(abs(speed), 0.0, 100.0, 0.0, 0.33);
    return nms_periodicFunction(rand.y - scaledTime);
}

// Quadratic B-spline basis for 3 samples.
float nms_quadratic3(float p0, float p1, float p2, float t)
{
    float t2 = t * t;
    return p0 * 0.5 * (1.0 - t) * (1.0 - t) +
           p1 * 0.5 * (-2.0 * t2 + 2.0 * t + 1.0) +
           p2 * 0.5 * t2;
}

// Catmull-Rom 3-point interpolation. Redundant terms reproduced literally.
float nms_catmullRom3(float p0, float p1, float p2, float t)
{
    float t2 = t * t;
    float t3 = t2 * t;

    return p1 + 0.5 * t * (p2 - p0) +
           0.5 * t2 * (2.0*p0 - 5.0*p1 + 4.0*p2 - p0) +
           0.5 * t3 * (-p0 + 3.0*p1 - 3.0*p2 + p0);
}

float nms_quadratic3x3Value(float2 st, float freq, float speed)
{
    float nd = 1.0 / freq;

    float v00 = nms_constant(st + float2(-nd, -nd), freq, speed);
    float v10 = nms_constant(st + float2(0.0, -nd), freq, speed);
    float v20 = nms_constant(st + float2(nd, -nd), freq, speed);

    float v01 = nms_constant(st + float2(-nd, 0.0), freq, speed);
    float v11 = nms_constant(st, freq, speed);
    float v21 = nms_constant(st + float2(nd, 0.0), freq, speed);

    float v02 = nms_constant(st + float2(-nd, nd), freq, speed);
    float v12 = nms_constant(st + float2(0.0, nd), freq, speed);
    float v22 = nms_constant(st + float2(nd, nd), freq, speed);

    float2 f = frac(st * freq);

    float y0 = nms_quadratic3(v00, v10, v20, f.x);
    float y1 = nms_quadratic3(v01, v11, v21, f.x);
    float y2 = nms_quadratic3(v02, v12, v22, f.x);

    return nms_quadratic3(y0, y1, y2, f.y);
}

float nms_catmullRom3x3Value(float2 st, float freq, float speed)
{
    float nd = 1.0 / freq;

    float v00 = nms_constant(st + float2(-nd, -nd), freq, speed);
    float v10 = nms_constant(st + float2(0.0, -nd), freq, speed);
    float v20 = nms_constant(st + float2(nd, -nd), freq, speed);

    float v01 = nms_constant(st + float2(-nd, 0.0), freq, speed);
    float v11 = nms_constant(st, freq, speed);
    float v21 = nms_constant(st + float2(nd, 0.0), freq, speed);

    float v02 = nms_constant(st + float2(-nd, nd), freq, speed);
    float v12 = nms_constant(st + float2(0.0, nd), freq, speed);
    float v22 = nms_constant(st + float2(nd, nd), freq, speed);

    float2 f = frac(st * freq);

    float y0 = nms_catmullRom3(v00, v10, v20, f.x);
    float y1 = nms_catmullRom3(v01, v11, v21, f.x);
    float y2 = nms_catmullRom3(v02, v12, v22, f.x);

    return nms_catmullRom3(y0, y1, y2, f.y);
}

float nms_blendBicubic(float p0, float p1, float p2, float p3, float t)
{
    float t2 = t * t;
    float t3 = t2 * t;

    float b0 = (1.0 - t) * (1.0 - t) * (1.0 - t) / 6.0;
    float b1 = (3.0 * t3 - 6.0 * t2 + 4.0) / 6.0;
    float b2 = (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) / 6.0;
    float b3 = t3 / 6.0;

    return p0 * b0 + p1 * b1 + p2 * b2 + p3 * b3;
}

float nms_catmullRom4(float p0, float p1, float p2, float p3, float t)
{
    return p1 + 0.5 * t * (p2 - p0 + t * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 +
           t * (3.0 * (p1 - p2) + p3 - p0)));
}

float nms_blendLinearOrCosine(float a, float b, float amount, int interp)
{
    if (interp == 1)
    {
        return lerp(a, b, amount);
    }
    return lerp(a, b, smoothstep(0.0, 1.0, amount));
}

float nms_bicubicValue(float2 st, float freq, float speed)
{
    float ndX = 1.0 / freq;
    float ndY = 1.0 / freq;

    float u0 = st.x - ndX;
    float u1 = st.x;
    float u2 = st.x + ndX;
    float u3 = st.x + ndX + ndX;

    float v0 = st.y - ndY;
    float v1 = st.y;
    float v2 = st.y + ndY;
    float v3 = st.y + ndY + ndY;

    float x0y0 = nms_constant(float2(u0, v0), freq, speed);
    float x0y1 = nms_constant(float2(u0, v1), freq, speed);
    float x0y2 = nms_constant(float2(u0, v2), freq, speed);
    float x0y3 = nms_constant(float2(u0, v3), freq, speed);

    float x1y0 = nms_constant(float2(u1, v0), freq, speed);
    float x1y1 = nms_constant(st, freq, speed);
    float x1y2 = nms_constant(float2(u1, v2), freq, speed);
    float x1y3 = nms_constant(float2(u1, v3), freq, speed);

    float x2y0 = nms_constant(float2(u2, v0), freq, speed);
    float x2y1 = nms_constant(float2(u2, v1), freq, speed);
    float x2y2 = nms_constant(float2(u2, v2), freq, speed);
    float x2y3 = nms_constant(float2(u2, v3), freq, speed);

    float x3y0 = nms_constant(float2(u3, v0), freq, speed);
    float x3y1 = nms_constant(float2(u3, v1), freq, speed);
    float x3y2 = nms_constant(float2(u3, v2), freq, speed);
    float x3y3 = nms_constant(float2(u3, v3), freq, speed);

    float2 uv = st * freq;

    float y0 = nms_blendBicubic(x0y0, x1y0, x2y0, x3y0, frac(uv.x));
    float y1 = nms_blendBicubic(x0y1, x1y1, x2y1, x3y1, frac(uv.x));
    float y2 = nms_blendBicubic(x0y2, x1y2, x2y2, x3y2, frac(uv.x));
    float y3 = nms_blendBicubic(x0y3, x1y3, x2y3, x3y3, frac(uv.x));

    return nms_blendBicubic(y0, y1, y2, y3, frac(uv.y));
}

float nms_catmullRom4x4Value(float2 st, float freq, float speed)
{
    float ndX = 1.0 / freq;
    float ndY = 1.0 / freq;

    float u0 = st.x - ndX;
    float u1 = st.x;
    float u2 = st.x + ndX;
    float u3 = st.x + ndX + ndX;

    float v0 = st.y - ndY;
    float v1 = st.y;
    float v2 = st.y + ndY;
    float v3 = st.y + ndY + ndY;

    float x0y0 = nms_constant(float2(u0, v0), freq, speed);
    float x0y1 = nms_constant(float2(u0, v1), freq, speed);
    float x0y2 = nms_constant(float2(u0, v2), freq, speed);
    float x0y3 = nms_constant(float2(u0, v3), freq, speed);

    float x1y0 = nms_constant(float2(u1, v0), freq, speed);
    float x1y1 = nms_constant(st, freq, speed);
    float x1y2 = nms_constant(float2(u1, v2), freq, speed);
    float x1y3 = nms_constant(float2(u1, v3), freq, speed);

    float x2y0 = nms_constant(float2(u2, v0), freq, speed);
    float x2y1 = nms_constant(float2(u2, v1), freq, speed);
    float x2y2 = nms_constant(float2(u2, v2), freq, speed);
    float x2y3 = nms_constant(float2(u2, v3), freq, speed);

    float x3y0 = nms_constant(float2(u3, v0), freq, speed);
    float x3y1 = nms_constant(float2(u3, v1), freq, speed);
    float x3y2 = nms_constant(float2(u3, v2), freq, speed);
    float x3y3 = nms_constant(float2(u3, v3), freq, speed);

    float2 uv = st * freq;

    float y0 = nms_catmullRom4(x0y0, x1y0, x2y0, x3y0, frac(uv.x));
    float y1 = nms_catmullRom4(x0y1, x1y1, x2y1, x3y1, frac(uv.x));
    float y2 = nms_catmullRom4(x0y2, x1y2, x2y2, x3y2, frac(uv.x));
    float y3 = nms_catmullRom4(x0y3, x1y3, x2y3, x3y3, frac(uv.x));

    return nms_catmullRom4(y0, y1, y2, y3, frac(uv.y));
}

// Simplex 2D - MIT License.
float3 nms_mod289_3(float3 x)
{
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

float2 nms_mod289_2(float2 x)
{
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

float3 nms_permute3(float3 x)
{
    return nms_mod289_3(((x * 34.0) + 1.0) * x);
}

float nms_simplexValue(float2 st_in, float freq, float s, float blend)
{
    float4 C = float4(
        0.211324865405187,
        0.366025403784439,
        -0.577350269189626,
        0.024390243902439
    );

    float2 uv = float2(st_in.x * freq, st_in.y * freq);
    uv.x = uv.x + s;

    float2 i = floor(uv + dot(uv, C.yy));
    float2 x0 = uv - i + dot(i, C.xx);

    // WGSL: select(vec2(0,1), vec2(1,0), x0.x > x0.y)  -> ternary literal
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float2 x1 = x0 - i1 + float2(C.x, C.x);
    float2 x2 = x0 - float2(1.0, 1.0) + float2(2.0 * C.x, 2.0 * C.x);

    i = nms_mod289_2(i);
    float3 p = nms_permute3(nms_permute3(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));

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
    return nms_periodicFunction(nms_map(v, -1.0, 1.0, 0.0, 1.0) - blend);
}

float nms_sineNoise(float2 st_in, float freq, float s, float blend)
{
    float2 st = st_in * freq;
    st.x = st.x + s;

    float a = blend;
    float b = blend;
    float c = 1.0 - blend;

    float3 r1 = nms_prng(float3(s, s, s)) * 0.75 + float3(0.125, 0.125, 0.125);
    float3 r2 = nms_prng(float3(s + 10.0, s + 10.0, s + 10.0)) * 0.75 + float3(0.125, 0.125, 0.125);
    float x = sin(r1.x * st.y + sin(r1.y * st.x + a) + sin(r1.z * st.x + b) + c);
    float y = sin(r2.x * st.x + sin(r2.y * st.y + b) + sin(r2.z * st.y + c) + a);
    return (x + y) * 0.5 + 0.5;
}

float nms_value(float2 st, float freq, int interp, float speed)
{
    if (interp == 3)
    {
        return nms_catmullRom3x3Value(st, freq, speed);
    }
    else if (interp == 4)
    {
        return nms_catmullRom4x4Value(st, freq, speed);
    }
    else if (interp == 5)
    {
        return nms_quadratic3x3Value(st, freq, speed);
    }
    else if (interp == 6)
    {
        return nms_bicubicValue(st, freq, speed);
    }
    else if (interp == 10)
    {
        float scaledTime = nms_periodicFunction(time) * nms_map(abs(speed), 0.0, 100.0, 0.0, 0.333);
        return nms_simplexValue(st, freq, (float)seed, scaledTime);
    }
    else if (interp == 11)
    {
        float scaledTime = nms_periodicFunction(time) * nms_map(abs(speed), 0.0, 100.0, 0.0, 0.333);
        return nms_sineNoise(st, freq, (float)seed, scaledTime);
    }
    float x1y1 = nms_constant(st, freq, speed);
    if (interp == 0)
    {
        return x1y1;
    }
    float ndX = 1.0 / freq;
    float ndY = 1.0 / freq;
    float x1y2 = nms_constant(float2(st.x, st.y + ndY), freq, speed);
    float x2y1 = nms_constant(float2(st.x + ndX, st.y), freq, speed);
    float x2y2 = nms_constant(float2(st.x + ndX, st.y + ndY), freq, speed);
    float2 uv = st * freq;
    float a = nms_blendLinearOrCosine(x1y1, x2y1, frac(uv.x), interp);
    float b = nms_blendLinearOrCosine(x1y2, x2y2, frac(uv.x), interp);
    return nms_blendLinearOrCosine(a, b, frac(uv.y), interp);
}

float nms_circles(float2 st, float freq)
{
    float dist = length(st - float2(0.5 * aspectRatio, 0.5));
    return dist * freq;
}

float nms_rings(float2 st, float freq)
{
    float dist = length(st - float2(0.5 * aspectRatio, 0.5));
    return cos(dist * NMS_PI * freq);
}

float nms_diamonds(float2 st, float freq)
{
    float2 st2 = st;
    st2 = st2 - float2(0.5 * aspectRatio, 0.5);
    st2 = st2 * freq;
    return cos(st2.x * NMS_PI) + cos(st2.y * NMS_PI);
}

// shape() — n-gon SDF-ish radial field. atan2 arg order copied literally.
float nms_shape(float2 st, int sides, float blend)
{
    float2 st2 = st * 2.0 - float2(aspectRatio, 1.0);
    float a = atan2(st2.x, st2.y) + NMS_PI;
    float r = NMS_TAU / (float)sides;
    return cos(floor(0.5 + a / r) * r - a) * length(st2) * blend;
}

float nms_offset(float2 st, float freq, int loopOffset, float speed, float seedIn)
{
    if (loopOffset == 10)
    {
        return nms_circles(st, freq);
    }
    else if (loopOffset == 20)
    {
        return nms_shape(st, 3, freq * 0.5);
    }
    else if (loopOffset == 30)
    {
        return (abs(st.x - 0.5 * aspectRatio) + abs(st.y - 0.5)) * freq * 0.5;
    }
    else if (loopOffset >= 40 && loopOffset <= 120)
    {
        int sides = loopOffset / 10;
        return nms_shape(st, sides, freq * 0.5);
    }
    else if (loopOffset == 200)
    {
        return st.x * freq * 0.5;
    }
    else if (loopOffset == 210)
    {
        return st.y * freq * 0.5;
    }
    else if (loopOffset >= 300 && loopOffset <= 380)
    {
        int idx = (loopOffset - 300) / 10;
        // WGSL: select(idx + 3, idx, idx <= 6) -> ternary literal
        int interp = (idx <= 6) ? idx : (idx + 3);
        // WGSL: select(freq, map(...), loopOffset == 300) -> ternary literal
        float f = (loopOffset == 300) ? nms_map(freq, 1.0, 6.0, 1.0, 20.0) : freq;
        return 1.0 - nms_value(st + float2(seedIn, seedIn), f, interp, speed);
    }
    else if (loopOffset == 400)
    {
        return 1.0 - nms_rings(st, freq);
    }
    else if (loopOffset == 410)
    {
        return 1.0 - nms_diamonds(st, freq);
    }
    return 0.0;
}

float3 nms_hsv2rgb(float3 hsv)
{
    float h = frac(hsv.x);
    float s = hsv.y;
    float v = hsv.z;

    float c = v * s;
    float x = c * (1.0 - abs(nms_modulo(h * 6.0, 2.0) - 1.0));
    float m = v - c;

    float3 rgb = float3(0.0, 0.0, 0.0);
    if (0.0 <= h && h < 1.0/6.0)
    {
        rgb = float3(c, x, 0.0);
    }
    else if (1.0/6.0 <= h && h < 2.0/6.0)
    {
        rgb = float3(x, c, 0.0);
    }
    else if (2.0/6.0 <= h && h < 3.0/6.0)
    {
        rgb = float3(0.0, c, x);
    }
    else if (3.0/6.0 <= h && h < 4.0/6.0)
    {
        rgb = float3(0.0, x, c);
    }
    else if (4.0/6.0 <= h && h < 5.0/6.0)
    {
        rgb = float3(x, 0.0, c);
    }
    else if (5.0/6.0 <= h && h < 1.0)
    {
        rgb = float3(c, 0.0, x);
    }

    return rgb + float3(m, m, m);
}

float3 nms_linearToSrgb(float3 linearColor)
{
    float3 srgb = float3(0.0, 0.0, 0.0);
    [unroll]
    for (int i = 0; i < 3; i = i + 1)
    {
        if (linearColor[i] <= 0.0031308)
        {
            srgb[i] = linearColor[i] * 12.92;
        }
        else
        {
            srgb[i] = 1.055 * pow(linearColor[i], 1.0 / 2.4) - 0.055;
        }
    }
    return srgb;
}

// oklab transform. WGSL `mat3x3<f32>(col0,col1,col2)` is COLUMN-major and the
// body computes `M * c` => result[i] = sum_j col_j[i] * c[j]. HLSL `mul(M, c)`
// computes result[i] = sum_j M[i][j] * c[j] (row i dot c). So set HLSL row i =
// (col0[i], col1[i], col2[i]) — i.e. the matrices below are written with the
// WGSL columns laid out as HLSL ROWS, and we then use mul(M, c). Verified by
// component expansion.
// fwdA WGSL columns: (1,1,1),(0.3963..,-0.1055..,-0.0894..),(0.2158..,-0.0638..,-1.2914..)
static const float3x3 NMS_FWD_A = float3x3(
    1.0,           0.3963377774,  0.2158037573,
    1.0,          -0.1055613458, -0.0638541728,
    1.0,          -0.0894841775, -1.2914855480
);
static const float3x3 NMS_FWD_B = float3x3(
    4.0767245293, -3.3072168827,  0.2307590544,
   -1.2681437731,  2.6093323231, -0.3411344290,
   -0.0041119885, -0.7034763098,  1.7068625689
);

float3 nms_linear_srgb_from_oklab(float3 c)
{
    float3 lms = mul(NMS_FWD_A, c);
    return mul(NMS_FWD_B, (lms * lms * lms));
}

float3 nms_pal(float t)
{
    float tt = t * (float)repeatPalette + rotatePalette * 0.01;
    float3 color = paletteOffset + paletteAmp * cos(6.28318 * (paletteFreq * tt + palettePhase));

    if (paletteMode == 1)
    {
        color = nms_hsv2rgb(color);
    }
    else if (paletteMode == 2)
    {
        color.y = color.y * -0.509 + 0.276;
        color.z = color.z * -0.509 + 0.198;
        color = nms_linear_srgb_from_oklab(color);
        color = nms_linearToSrgb(color);
    }

    return color;
}

// =============================================================================
// nm_shapes — core per-pixel evaluation. Mirrors WGSL main() exactly.
// globalCoord is the fragment pixel coord (+ tileOffset). `st = pos/res.y`
// divides by HEIGHT only (WGSL: pos.xy / resolution.y). We use fullResolution.y
// as the height denominator to match the engine's untiled-coordinate model.
// =============================================================================
float4 nm_shapes(float2 globalCoord)
{
    float4 color = float4(0.0, 0.0, 1.0, 1.0);
    float2 st = globalCoord / fullResolution.y;

    float lf1 = nms_map(loopAScale, 1.0, 100.0, 6.0, 1.0);
    if (wrap > 0.5)
    {
        lf1 = floor(lf1);
        if (LOOP_A_OFFSET >= 200 && LOOP_A_OFFSET < 300)
        {
            lf1 = lf1 * 2.0;
        }
    }
    float amp1 = nms_map(abs(speedA), 0.0, 100.0, 0.0, 1.0);
    float t1 = 1.0;
    if (speedA < 0.0)
    {
        t1 = time + nms_offset(st, lf1, LOOP_A_OFFSET, amp1, (float)seed);
    }
    else if (speedA > 0.0)
    {
        t1 = time - nms_offset(st, lf1, LOOP_A_OFFSET, amp1, (float)seed);
    }

    float lf2 = nms_map(loopBScale, 1.0, 100.0, 6.0, 1.0);
    if (wrap > 0.5)
    {
        lf2 = floor(lf2);
        if (LOOP_B_OFFSET >= 200 && LOOP_B_OFFSET < 300)
        {
            lf2 = lf2 * 2.0;
        }
    }
    float amp2 = nms_map(abs(speedB), 0.0, 100.0, 0.0, 1.0);
    float t2 = 1.0;
    if (speedB < 0.0)
    {
        t2 = time + nms_offset(st, lf2, LOOP_B_OFFSET, amp2, (float)seed + 10.0);
    }
    else if (speedB > 0.0)
    {
        t2 = time - nms_offset(st, lf2, LOOP_B_OFFSET, amp2, (float)seed + 10.0);
    }

    float a = nms_periodicFunction(t1) * amp1;
    float b = nms_periodicFunction(t2) * amp2;

    float d = abs((a + b) - 1.0);
    if (cyclePalette == -1)
    {
        d = d + time;
    }
    else if (cyclePalette == 1)
    {
        d = d - time;
    }
    color = float4(nms_pal(d), color.a);

    return color;
}

#endif // NM_SHAPES_INCLUDED
