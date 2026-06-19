#ifndef NM_EFFECT_SHAPE_INCLUDED
#define NM_EFFECT_SHAPE_INCLUDED

// =============================================================================
// Shape.hlsl — synth/shape (func: "shape")
//
// "Interference patterns from geometric shapes."
//
// Ported VERBATIM from shaders/effects/synth/shape/wgsl/shape.wgsl (WGSL is
// canonical). GLSL twin consulted only to disambiguate. Single render pass.
//
// IMPORTANT per-effect helper divergence (PORTING-GUIDE golden rule 2):
//   * shape's periodicFunction uses sin(), NOT cos() — it is DIFFERENT from
//     NMCore.nm_periodicFunction (which is the cos form used by synth/noise).
//     So periodicFunction is ported INLINE here and nm_periodicFunction is NOT
//     used. (Reference 08 §2.1 calls out this sin-vs-cos divergence explicitly.)
//   * pcg / prng / map / modulo ARE the shared primitives (identical to all
//     references) and come from NMCore (nm_pcg/nm_prng/nm_map/nm_mod).
//
// LOOP_A_OFFSET / LOOP_B_OFFSET are compile-time #defines in the GLSL twin and
// injected `const`s in WGSL. Per PORTING-GUIDE they are NOT correctness-relevant
// (only a perf workaround) so we bind them as runtime `int` uniforms and branch
// with [branch]. Defaults match definition.js: LOOP_A_OFFSET=40, LOOP_B_OFFSET=30.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Compile-time selectors, modeled as runtime int uniforms ----------------
// definition.js globals.loopAOffset.define = "LOOP_A_OFFSET" (default 40)
//                globals.loopBOffset.define = "LOOP_B_OFFSET" (default 30)
int LOOP_A_OFFSET;
int LOOP_B_OFFSET;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
// seed       : int   (globals.seed,       default 1)   — packed slot 0.w in WGSL
// wrap       : bool  (globals.wrap,        default true) — slot 1.x, tested > 0.5
// loopAScale : float (globals.loopAScale,  default 1)   — slot 1.w
// loopBScale : float (globals.loopBScale,  default 1)   — slot 2.x
// speedA     : int   (globals.speedA,      default 50)  — slot 2.y (stored float)
// speedB     : int   (globals.speedB,      default 50)  — slot 2.z (stored float)
int   seed;
int   wrap;        // bool packed as int/float; tested > 0.5 to match WGSL
float loopAScale;
float loopBScale;
float speedA;      // reference stores/uses as f32; declared float for exactness
float speedB;

// ---- Constants (ported verbatim) --------------------------------------------
static const float SHAPE_PI  = 3.14159265359;
static const float SHAPE_TAU = 6.28318530718;

// =============================================================================
// Core ported helpers. These take explicit args (no globals) so the function is
// reusable by the Shader Graph wrapper. The WGSL uses module-scope vars for
// time/seed/wrap/aspectRatio; here they are threaded through as parameters.
// =============================================================================

// modulo(a,b) = a - b*floor(a/b). WGSL `modulo()`. Use nm_mod (never fmod).
// map(value,inMin,inMax,outMin,outMax). Use nm_map.

// periodicFunction(p): SIN form (DIFFERENT from synth/noise's cos form).
//   let x = TAU * p; return map(sin(x), -1, 1, 0, 1);
float nm_shape_periodicFunction(float p)
{
    float x = SHAPE_TAU * p;
    return nm_map(sin(x), -1.0, 1.0, 0.0, 1.0);
}

// constant(st_in, freq, speed) — canonical WGSL lattice value generator.
float nm_shape_constant(float2 st_in, float freq, float speed,
                        float u_time, float u_seed, bool u_wrap)
{
    float x = st_in.x * freq;
    float y = st_in.y * freq;
    if (u_wrap)
    {
        x = nm_mod(x, freq);
        y = nm_mod(y, freq);
    }
    x = x + u_seed;
    float3 rand = nm_prng(float3(floor(float2(x, y)), u_seed));
    float scaledTime = nm_shape_periodicFunction(rand.x - u_time)
                     * nm_map(abs(speed), 0.0, 100.0, 0.0, 0.33);
    return nm_shape_periodicFunction(rand.y - scaledTime);
}

// ---- 3x3 quadratic interpolation --------------------------------------------
float nm_shape_quadratic3(float p0, float p1, float p2, float t)
{
    float t2 = t * t;
    return p0 * 0.5 * (1.0 - t) * (1.0 - t) +
           p1 * 0.5 * (-2.0 * t2 + 2.0 * t + 1.0) +
           p2 * 0.5 * t2;
}

// catmullRom3 — note the deliberately-redundant `... 4.0*p2 - p0` and
// `-p0 + 3.0*p1 - 3.0*p2 + p0` terms. Reproduced LITERALLY (PORTING-GUIDE H10).
float nm_shape_catmullRom3(float p0, float p1, float p2, float t)
{
    float t2 = t * t;
    float t3 = t2 * t;
    return p1 + 0.5 * t * (p2 - p0) +
           0.5 * t2 * (2.0*p0 - 5.0*p1 + 4.0*p2 - p0) +
           0.5 * t3 * (-p0 + 3.0*p1 - 3.0*p2 + p0);
}

float nm_shape_quadratic3x3Value(float2 st, float freq, float speed,
                                 float u_time, float u_seed, bool u_wrap)
{
    float2 lattice = st * freq;
    float2 f = frac(lattice);
    float nd = 1.0 / freq;

    float v00 = nm_shape_constant(st + float2(-nd, -nd), freq, speed, u_time, u_seed, u_wrap);
    float v10 = nm_shape_constant(st + float2(0.0, -nd), freq, speed, u_time, u_seed, u_wrap);
    float v20 = nm_shape_constant(st + float2(nd, -nd), freq, speed, u_time, u_seed, u_wrap);

    float v01 = nm_shape_constant(st + float2(-nd, 0.0), freq, speed, u_time, u_seed, u_wrap);
    float v11 = nm_shape_constant(st, freq, speed, u_time, u_seed, u_wrap);
    float v21 = nm_shape_constant(st + float2(nd, 0.0), freq, speed, u_time, u_seed, u_wrap);

    float v02 = nm_shape_constant(st + float2(-nd, nd), freq, speed, u_time, u_seed, u_wrap);
    float v12 = nm_shape_constant(st + float2(0.0, nd), freq, speed, u_time, u_seed, u_wrap);
    float v22 = nm_shape_constant(st + float2(nd, nd), freq, speed, u_time, u_seed, u_wrap);

    float y0 = nm_shape_quadratic3(v00, v10, v20, f.x);
    float y1 = nm_shape_quadratic3(v01, v11, v21, f.x);
    float y2 = nm_shape_quadratic3(v02, v12, v22, f.x);

    return nm_shape_quadratic3(y0, y1, y2, f.y);
}

float nm_shape_catmullRom3x3Value(float2 st, float freq, float speed,
                                  float u_time, float u_seed, bool u_wrap)
{
    float2 lattice = st * freq;
    float2 f = frac(lattice);
    float nd = 1.0 / freq;

    float v00 = nm_shape_constant(st + float2(-nd, -nd), freq, speed, u_time, u_seed, u_wrap);
    float v10 = nm_shape_constant(st + float2(0.0, -nd), freq, speed, u_time, u_seed, u_wrap);
    float v20 = nm_shape_constant(st + float2(nd, -nd), freq, speed, u_time, u_seed, u_wrap);

    float v01 = nm_shape_constant(st + float2(-nd, 0.0), freq, speed, u_time, u_seed, u_wrap);
    float v11 = nm_shape_constant(st, freq, speed, u_time, u_seed, u_wrap);
    float v21 = nm_shape_constant(st + float2(nd, 0.0), freq, speed, u_time, u_seed, u_wrap);

    float v02 = nm_shape_constant(st + float2(-nd, nd), freq, speed, u_time, u_seed, u_wrap);
    float v12 = nm_shape_constant(st + float2(0.0, nd), freq, speed, u_time, u_seed, u_wrap);
    float v22 = nm_shape_constant(st + float2(nd, nd), freq, speed, u_time, u_seed, u_wrap);

    float y0 = nm_shape_catmullRom3(v00, v10, v20, f.x);
    float y1 = nm_shape_catmullRom3(v01, v11, v21, f.x);
    float y2 = nm_shape_catmullRom3(v02, v12, v22, f.x);

    return nm_shape_catmullRom3(y0, y1, y2, f.y);
}

// ---- 4x4 interpolation ------------------------------------------------------
float nm_shape_blendBicubic(float p0, float p1, float p2, float p3, float t)
{
    float t2 = t * t;
    float t3 = t2 * t;

    float b0 = (1.0 - t) * (1.0 - t) * (1.0 - t) / 6.0;
    float b1 = (3.0 * t3 - 6.0 * t2 + 4.0) / 6.0;
    float b2 = (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) / 6.0;
    float b3 = t3 / 6.0;

    return p0 * b0 + p1 * b1 + p2 * b2 + p3 * b3;
}

float nm_shape_catmullRom4(float p0, float p1, float p2, float p3, float t)
{
    return p1 + 0.5 * t * (p2 - p0 + t * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 +
           t * (3.0 * (p1 - p2) + p3 - p0)));
}

float nm_shape_blendLinearOrCosine(float a, float b, float amount, int interp)
{
    if (interp == 1)
    {
        return lerp(a, b, amount);
    }
    return lerp(a, b, smoothstep(0.0, 1.0, amount));
}

// ---- Simplex 2D noise helpers (Ashima) --------------------------------------
float3 nm_shape_mod289_v3(float3 x)
{
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

float2 nm_shape_mod289_v2(float2 x)
{
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

float3 nm_shape_permute(float3 x)
{
    return nm_shape_mod289_v3(((x * 34.0) + 1.0) * x);
}

float nm_shape_simplexValue(float2 st, float freq, float s, float blend)
{
    float4 C = float4(0.211324865405187,
                      0.366025403784439,
                     -0.577350269189626,
                      0.024390243902439);

    float2 uv = st * freq;
    uv.x = uv.x + s;

    float2 i = floor(uv + dot(uv, C.yy));
    float2 x0 = uv - i + dot(i, C.xx);

    float2 i1;
    if (x0.x > x0.y)
    {
        i1 = float2(1.0, 0.0);
    }
    else
    {
        i1 = float2(0.0, 1.0);
    }
    float4 x12 = x0.xyxy + C.xxzz;
    x12 = float4(x12.xy - i1, x12.zw);

    float2 i_mod = nm_shape_mod289_v2(i);
    float3 p = nm_shape_permute(nm_shape_permute(i_mod.y + float3(0.0, i1.y, 1.0))
          + i_mod.x + float3(0.0, i1.x, 1.0));

    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), float3(0.0, 0.0, 0.0));
    m = m * m;
    m = m * m;

    float3 x = 2.0 * frac(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;

    m = m * (1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h));

    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.y = a0.y * x12.x + h.y * x12.y;
    g.z = a0.z * x12.z + h.z * x12.w;

    float v = 130.0 * dot(m, g);

    return nm_shape_periodicFunction(nm_map(v, -1.0, 1.0, 0.0, 1.0) - blend);
}

float nm_shape_sineNoise(float2 st_in, float freq, float s, float blend)
{
    float2 st = st_in * freq;
    st.x = st.x + s;

    float a = blend;
    float b = blend;
    float c = 1.0 - blend;

    float3 r1 = nm_prng(float3(s, 0.0, 0.0)) * 0.75 + 0.125;
    float3 r2 = nm_prng(float3(s + 10.0, 0.0, 0.0)) * 0.75 + 0.125;
    float x = sin(r1.x * st.y + sin(r1.y * st.x + a) + sin(r1.z * st.x + b) + c);
    float y = sin(r2.x * st.x + sin(r2.y * st.y + b) + sin(r2.z * st.y + c) + a);

    return (x + y) * 0.5 + 0.5;
}

float nm_shape_bicubicValue(float2 st, float freq, float speed,
                            float u_time, float u_seed, bool u_wrap)
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

    float x0y0 = nm_shape_constant(float2(u0, v0), freq, speed, u_time, u_seed, u_wrap);
    float x0y1 = nm_shape_constant(float2(u0, v1), freq, speed, u_time, u_seed, u_wrap);
    float x0y2 = nm_shape_constant(float2(u0, v2), freq, speed, u_time, u_seed, u_wrap);
    float x0y3 = nm_shape_constant(float2(u0, v3), freq, speed, u_time, u_seed, u_wrap);

    float x1y0 = nm_shape_constant(float2(u1, v0), freq, speed, u_time, u_seed, u_wrap);
    float x1y1 = nm_shape_constant(st, freq, speed, u_time, u_seed, u_wrap);
    float x1y2 = nm_shape_constant(float2(u1, v2), freq, speed, u_time, u_seed, u_wrap);
    float x1y3 = nm_shape_constant(float2(u1, v3), freq, speed, u_time, u_seed, u_wrap);

    float x2y0 = nm_shape_constant(float2(u2, v0), freq, speed, u_time, u_seed, u_wrap);
    float x2y1 = nm_shape_constant(float2(u2, v1), freq, speed, u_time, u_seed, u_wrap);
    float x2y2 = nm_shape_constant(float2(u2, v2), freq, speed, u_time, u_seed, u_wrap);
    float x2y3 = nm_shape_constant(float2(u2, v3), freq, speed, u_time, u_seed, u_wrap);

    float x3y0 = nm_shape_constant(float2(u3, v0), freq, speed, u_time, u_seed, u_wrap);
    float x3y1 = nm_shape_constant(float2(u3, v1), freq, speed, u_time, u_seed, u_wrap);
    float x3y2 = nm_shape_constant(float2(u3, v2), freq, speed, u_time, u_seed, u_wrap);
    float x3y3 = nm_shape_constant(float2(u3, v3), freq, speed, u_time, u_seed, u_wrap);

    float2 uv = st * freq;

    float y0 = nm_shape_blendBicubic(x0y0, x1y0, x2y0, x3y0, frac(uv.x));
    float y1 = nm_shape_blendBicubic(x0y1, x1y1, x2y1, x3y1, frac(uv.x));
    float y2 = nm_shape_blendBicubic(x0y2, x1y2, x2y2, x3y2, frac(uv.x));
    float y3 = nm_shape_blendBicubic(x0y3, x1y3, x2y3, x3y3, frac(uv.x));

    return nm_shape_blendBicubic(y0, y1, y2, y3, frac(uv.y));
}

float nm_shape_catmullRom4x4Value(float2 st, float freq, float speed,
                                  float u_time, float u_seed, bool u_wrap)
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

    float x0y0 = nm_shape_constant(float2(u0, v0), freq, speed, u_time, u_seed, u_wrap);
    float x0y1 = nm_shape_constant(float2(u0, v1), freq, speed, u_time, u_seed, u_wrap);
    float x0y2 = nm_shape_constant(float2(u0, v2), freq, speed, u_time, u_seed, u_wrap);
    float x0y3 = nm_shape_constant(float2(u0, v3), freq, speed, u_time, u_seed, u_wrap);

    float x1y0 = nm_shape_constant(float2(u1, v0), freq, speed, u_time, u_seed, u_wrap);
    float x1y1 = nm_shape_constant(st, freq, speed, u_time, u_seed, u_wrap);
    float x1y2 = nm_shape_constant(float2(u1, v2), freq, speed, u_time, u_seed, u_wrap);
    float x1y3 = nm_shape_constant(float2(u1, v3), freq, speed, u_time, u_seed, u_wrap);

    float x2y0 = nm_shape_constant(float2(u2, v0), freq, speed, u_time, u_seed, u_wrap);
    float x2y1 = nm_shape_constant(float2(u2, v1), freq, speed, u_time, u_seed, u_wrap);
    float x2y2 = nm_shape_constant(float2(u2, v2), freq, speed, u_time, u_seed, u_wrap);
    float x2y3 = nm_shape_constant(float2(u2, v3), freq, speed, u_time, u_seed, u_wrap);

    float x3y0 = nm_shape_constant(float2(u3, v0), freq, speed, u_time, u_seed, u_wrap);
    float x3y1 = nm_shape_constant(float2(u3, v1), freq, speed, u_time, u_seed, u_wrap);
    float x3y2 = nm_shape_constant(float2(u3, v2), freq, speed, u_time, u_seed, u_wrap);
    float x3y3 = nm_shape_constant(float2(u3, v3), freq, speed, u_time, u_seed, u_wrap);

    float2 uv = st * freq;

    float y0 = nm_shape_catmullRom4(x0y0, x1y0, x2y0, x3y0, frac(uv.x));
    float y1 = nm_shape_catmullRom4(x0y1, x1y1, x2y1, x3y1, frac(uv.x));
    float y2 = nm_shape_catmullRom4(x0y2, x1y2, x2y2, x3y2, frac(uv.x));
    float y3 = nm_shape_catmullRom4(x0y3, x1y3, x2y3, x3y3, frac(uv.x));

    return nm_shape_catmullRom4(y0, y1, y2, y3, frac(uv.y));
}

float nm_shape_value(float2 st, float freq, int interp, float speed,
                     float u_time, float u_seed, bool u_wrap)
{
    if (interp == 3)
    {
        return nm_shape_catmullRom3x3Value(st, freq, speed, u_time, u_seed, u_wrap);
    }
    else if (interp == 4)
    {
        return nm_shape_catmullRom4x4Value(st, freq, speed, u_time, u_seed, u_wrap);
    }
    else if (interp == 5)
    {
        return nm_shape_quadratic3x3Value(st, freq, speed, u_time, u_seed, u_wrap);
    }
    else if (interp == 6)
    {
        return nm_shape_bicubicValue(st, freq, speed, u_time, u_seed, u_wrap);
    }
    else if (interp == 10)
    {
        float scaledTime = nm_shape_periodicFunction(u_time) * nm_map(abs(speed), 0.0, 100.0, 0.0, 0.333);
        return nm_shape_simplexValue(st, freq, u_seed, scaledTime);
    }
    else if (interp == 11)
    {
        float scaledTime = nm_shape_periodicFunction(u_time) * nm_map(abs(speed), 0.0, 100.0, 0.0, 0.333);
        return nm_shape_sineNoise(st, freq, u_seed, scaledTime);
    }

    float x1y1 = nm_shape_constant(st, freq, speed, u_time, u_seed, u_wrap);

    if (interp == 0)
    {
        return x1y1;
    }

    float ndX = 1.0 / freq;
    float ndY = 1.0 / freq;

    float x1y2 = nm_shape_constant(float2(st.x, st.y + ndY), freq, speed, u_time, u_seed, u_wrap);
    float x2y1 = nm_shape_constant(float2(st.x + ndX, st.y), freq, speed, u_time, u_seed, u_wrap);
    float x2y2 = nm_shape_constant(float2(st.x + ndX, st.y + ndY), freq, speed, u_time, u_seed, u_wrap);

    float2 uv = st * freq;

    float a = nm_shape_blendLinearOrCosine(x1y1, x2y1, frac(uv.x), interp);
    float b = nm_shape_blendLinearOrCosine(x1y2, x2y2, frac(uv.x), interp);

    return nm_shape_blendLinearOrCosine(a, b, frac(uv.y), interp);
}

// ---- Shape functions --------------------------------------------------------
float nm_shape_circles(float2 st, float freq, float u_aspectRatio)
{
    float dist = length(st - float2(0.5 * u_aspectRatio, 0.5));
    return dist * freq;
}

float nm_shape_rings(float2 st, float freq, float u_aspectRatio)
{
    float dist = length(st - float2(0.5 * u_aspectRatio, 0.5));
    return cos(dist * SHAPE_PI * freq);
}

// diamonds: WGSL reads `pos.xy / resolution.y` (render-target height, no
// tileOffset). The GLSL twin reads `globalCoord / fullResolution.y`. Per
// PORTING-GUIDE coordinate parity (H13) + reference 07 H2 ("Pick fullResolution
// for tiled-render correctness"), we use the tiled global coord / fullResolution.y.
// Caller passes the precomputed stLocal base = NM_GlobalCoord(i)/fullResolution.y.
// TODO(verify): confirm against the parity harness that diamonds (LOOP_OFFSET 410)
// matches the WebGPU golden when renderScale==1 / untiled (resolution==fullResolution).
float nm_shape_diamonds(float2 stBase, float freq, float u_aspectRatio)
{
    float2 stLocal = stBase;
    stLocal = stLocal - float2(0.5 * u_aspectRatio, 0.5);
    stLocal = stLocal * freq;
    return (cos(stLocal.x * SHAPE_PI) + cos(stLocal.y * SHAPE_PI));
}

// shape(): atan2 ARG ORDER preserved literally (PORTING-GUIDE H3).
//   WGSL: atan2(stLocal.x, stLocal.y)  -> HLSL: atan2(stLocal.x, stLocal.y)
float nm_shape_polyShape(float2 st, int sides, float blend, float u_aspectRatio)
{
    float2 stLocal = st * 2.0 - float2(u_aspectRatio, 1.0);
    float a = atan2(stLocal.x, stLocal.y) + SHAPE_PI;
    float r = SHAPE_TAU / (float)sides;
    return cos(floor(0.5 + a / r) * r - a) * length(stLocal) * blend;
}

// offset() — the big LOOP_*_OFFSET dispatch.
//   stBase  = the diamonds base coord (NM_GlobalCoord/fullResolution.y).
//   seedVal = lattice coordinate seed offset (= module seed for A, seed+10 for B).
//   u_modSeed = module-scope `seed` (uniforms.data[0].w). The WGSL value()
//     simplex/sine branches and constant()'s internal `x += seed` ALWAYS use the
//     module-scope seed, NOT seedVal — only the lattice coord uses `st + seedVal`.
//     (Loop B passes seedVal = seed+10 for the coordinate shift, but the internal
//      seed stays `seed`.) Threaded separately to preserve this exactly.
float nm_shape_offset(float2 st, float freq, int loopOffset, float speed,
                      float seedVal, float2 stBase,
                      float u_time, bool u_wrap, float u_aspectRatio, float u_modSeed)
{
    if (loopOffset == 10)
    {
        return nm_shape_circles(st, freq, u_aspectRatio);
    }
    else if (loopOffset == 20)
    {
        return nm_shape_polyShape(st, 3, freq * 0.5, u_aspectRatio);
    }
    else if (loopOffset == 30)
    {
        return (abs(st.x - 0.5 * u_aspectRatio) + abs(st.y - 0.5)) * freq * 0.5;
    }
    else if (loopOffset >= 40 && loopOffset <= 120)
    {
        int sides = loopOffset / 10;
        return nm_shape_polyShape(st, sides, freq * 0.5, u_aspectRatio);
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
        // WGSL: select(idx + 3, idx, idx <= 6)  => (idx <= 6) ? idx : idx + 3
        int interp = (idx <= 6) ? idx : idx + 3;
        // WGSL: select(freq, map(...), loopOffset == 300) => (loopOffset==300) ? map(...) : freq
        float f = (loopOffset == 300) ? nm_map(freq, 1.0, 6.0, 1.0, 20.0) : freq;
        // Coord shifted by seedVal; internal seed is the module-scope u_modSeed.
        return 1.0 - nm_shape_value(st + seedVal, f, interp, speed, u_time, u_modSeed, u_wrap);
    }
    else if (loopOffset == 400)
    {
        return 1.0 - nm_shape_rings(st, freq, u_aspectRatio);
    }
    else if (loopOffset == 410)
    {
        return 1.0 - nm_shape_diamonds(stBase, freq, u_aspectRatio);
    }
    return 0.0;
}

// =============================================================================
// nm_shape — full effect body. Returns the final RGBA (grayscale interference).
//   st     : NM_GlobalCoord(i) / fullResolution.y  (divide by HEIGHT — H13)
//   stBase : same coord, used as the diamonds base
// =============================================================================
float4 nm_shape(float2 st, float2 stBase,
                int loopAOffset, int loopBOffset,
                float u_loopAScale, float u_loopBScale,
                float u_speedA, float u_speedB,
                float u_seed, bool u_wrap, float u_time, float u_aspectRatio)
{
    float4 color = float4(0.0, 0.0, 0.0, 1.0);

    float lf1 = nm_map(u_loopAScale, 1.0, 100.0, 6.0, 1.0);
    if (u_wrap)
    {
        lf1 = floor(lf1);
        if (loopAOffset >= 200 && loopAOffset < 300)
        {
            lf1 = lf1 * 2.0;
        }
    }
    float amp1 = nm_map(abs(u_speedA), 0.0, 100.0, 0.0, 1.0);
    float t1 = 1.0;
    if (u_speedA < 0.0)
    {
        t1 = u_time + nm_shape_offset(st, lf1, loopAOffset, amp1, u_seed, stBase, u_time, u_wrap, u_aspectRatio, u_seed);
    }
    else if (u_speedA > 0.0)
    {
        t1 = u_time - nm_shape_offset(st, lf1, loopAOffset, amp1, u_seed, stBase, u_time, u_wrap, u_aspectRatio, u_seed);
    }

    float lf2 = nm_map(u_loopBScale, 1.0, 100.0, 6.0, 1.0);
    if (u_wrap)
    {
        lf2 = floor(lf2);
        if (loopBOffset >= 200 && loopBOffset < 300)
        {
            lf2 = lf2 * 2.0;
        }
    }
    float amp2 = nm_map(abs(u_speedB), 0.0, 100.0, 0.0, 1.0);
    float t2 = 1.0;
    if (u_speedB < 0.0)
    {
        t2 = u_time + nm_shape_offset(st, lf2, loopBOffset, amp2, u_seed + 10.0, stBase, u_time, u_wrap, u_aspectRatio, u_seed);
    }
    else if (u_speedB > 0.0)
    {
        t2 = u_time - nm_shape_offset(st, lf2, loopBOffset, amp2, u_seed + 10.0, stBase, u_time, u_wrap, u_aspectRatio, u_seed);
    }

    float a = nm_shape_periodicFunction(t1) * amp1;
    float b = nm_shape_periodicFunction(t2) * amp2;

    float d = abs((a + b) - 1.0);

    // Mono output: grayscale intensity
    color = float4(d, d, d, 1.0);

    return color;
}

// ---- Pass: "shape" (progName "shape") ---------------------------------------
float4 NMFrag_shape(NMVaryings i) : SV_Target
{
    // st = globalCoord / fullResolution.y — divide by HEIGHT (PORTING-GUIDE H13).
    float2 globalCoord = NM_GlobalCoord(i);
    float2 st = globalCoord / fullResolution.y;
    // diamonds base = same tiled coord / fullResolution.y (reference 07 H2).
    float2 stBase = globalCoord / fullResolution.y;
    float u_aspectRatio = aspectRatio;   // = fullResolution.x / fullResolution.y

    return nm_shape(st, stBase,
                    LOOP_A_OFFSET, LOOP_B_OFFSET,
                    loopAScale, loopBScale,
                    speedA, speedB,
                    (float)seed, (wrap > 0.5), time, u_aspectRatio);
}

#endif // NM_EFFECT_SHAPE_INCLUDED
