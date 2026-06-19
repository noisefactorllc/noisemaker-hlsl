#ifndef NM_EFFECT_KALEIDO_INCLUDED
#define NM_EFFECT_KALEIDO_INCLUDED

// =============================================================================
// Kaleido.hlsl — classicNoisedeck/kaleido (func: "kaleido")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/classicNoisedeck/kaleido/wgsl/kaleido.wgsl
// (GLSL consulted only to disambiguate coordinates / texel size / tiling.)
//
// Single-input filter. Samples the input feed with mirrored kaleidoscopic
// wedges; an animated radial "offset" loop drives a blend amount, and an
// optional convolution / pixellate / posterize kernel is applied at the end.
// Single render pass (program "kaleido").
//
// PORTING-GUIDE notes / hazards handled:
//  * periodicFunction(p) HERE is SIN-based: map(sin(p*TAU),-1,1,0,1) =
//    (sin(p*TAU)+1)*0.5. The shared NMCore nm_periodicFunction is COS-based, so
//    it MUST NOT be used — this effect's own sin version is ported inline (kl_).
//  * PRNG: this effect's prng() is PLAIN (uint3)p TRUNCATION with NO sign-fold;
//    randomFromLatticeWithOffset hashes a hand-built uint3 state directly with
//    pcg. The shared NMCore nm_prng() adds a sign-fold -> NOT bit-identical, so
//    pcg (nm_pcg, identical PCG-3D) is reused but prng/random are inline.
//  * METRIC, LOOP_OFFSET, DIRECTION, KERNEL are compile-time defines in WGSL/GLSL
//    (injectDefines). Per PORTING-GUIDE they become int uniforms branched at
//    runtime with [branch] (the WGSL keeps all variants and const-folds).
//    Defaults METRIC=0, LOOP_OFFSET=10, DIRECTION=2, KERNEL=0 (definition.js).
//  * Coordinate: WGSL `uv = position.xy / u.resolution.y`; GLSL `uv =
//    (gl_FragCoord.xy + tileOffset) / fullResolution.y`. Divide by HEIGHT (.y)
//    so uv.x spans [0, aspect] (H13). Identical untiled; use the tiling-aware
//    GLSL form NM_GlobalCoord(i) / fullResolution.y. No per-effect Y flip
//    (ported from WGSL, top-left canonical).
//  * convolve()/pixellate() texel size: WGSL `1.0 / u.resolution`; GLSL
//    `1.0 / resolution`. Both use the PER-TILE render resolution (NOT the input
//    texture dimensions, NOT fullResolution) — we mirror that with `resolution`.
//  * Final sample uses the kaleidoscoped uv directly (kaleidoscope returns
//    fract(st), 0..1), so no tile-local UV conversion is needed.
//  * atan2: WGSL `atan2(st.x, st.y)` in shape(), `atan2(st.y, st.x)` in
//    kaleidoscope() -> HLSL atan2 with the SAME arg order kept literally (H3).
//  * glslMod: kaleidoscope folds a signed angle and the WGSL deliberately uses
//    GLSL-style mod (sign of divisor) via glslMod() -> nm_mod (NEVER fmod, H6).
//  * `select(0.0, delta/maxC, maxC != 0.0)` -> `maxC != 0.0 ? delta/maxC : 0.0`.
//  * `select(vec2(0,1), vec2(1,0), x0.x > x0.y)` -> `x0.x > x0.y ? (1,0):(0,1)`.
//  * rgb2hsv uses `% 6.0` on a possibly-negative value: WGSL `%` truncates
//    toward zero (sign of x). HLSL `%` on floats ALSO truncates toward zero, so
//    HLSL `%` matches the WGSL here (NOT nm_mod, which would change the sign).
//  * `bitcast<u32>(f)` -> asuint(f) (bit reinterpret); `u32(i)` -> (uint)i
//    (two's-complement); `vec3u(p)` -> (uint3)p (float trunc). Match each.
//  * `mix`->lerp, `fract`->frac, `radians(d)`->d*PI/180 (kept as the literal
//    expression). Full 32-bit float; PCG/asuint are bit-sensitive.
//  * TODO(verify): runtime must bind a bilinear, clamp-to-edge, NON-sRGB sampler
//    (H7). METRIC / LOOP_OFFSET / DIRECTION / KERNEL branches and the noise
//    LOOP_OFFSET variants (300..380) need parity-harness confirmation.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (reference binding: sampler@0, inputTex@1) ------
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
// WGSL types: kaleido is f32 (GLSL `uniform float kaleido`), speed f32,
// loopScale f32, effectWidth f32, seed i32, wrap i32.
float kaleido;       // globals.sides.uniform        default 8  (float side count)
float loopScale;     // globals.loopScale.uniform     default 1
float speed;         // globals.speed.uniform         default 5
int   seed;          // globals.seed.uniform          default 1
int   wrap;          // globals.wrap.uniform          default 1 (true)
float effectWidth;   // globals.effectWidth.uniform   default 0

// Compile-time defines in the reference; int uniforms + [branch] here.
int METRIC;          // globals.metric.define          default 0   (circle)
int LOOP_OFFSET;     // globals.loopOffset.define      default 10  (circle)
int DIRECTION;       // globals.direction.define       default 2   (none)
int KERNEL;          // globals.kernel.define          default 0   (none)

#define KL_PI  3.14159265359
#define KL_TAU 6.28318530718

// aspectRatio() — WGSL u.resolution.x/u.resolution.y. We use the engine alias
// (fullResolution.x/fullResolution.y); identical untiled. Provided by NMCore.
float kl_aspectRatio() { return aspectRatio; }

float kl_map(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

// SIN-based periodicFunction (this effect's own; NMCore's is cos-based).
float kl_periodicFunction(float p)
{
    return kl_map(sin(p * KL_TAU), -1.0, 1.0, 0.0, 1.0);
}

// prng(p) = vec3f(pcg(vec3u(p))) / f32(0xffffffffu). (uint3)p is float trunc.
float3 kl_prng(float3 p)
{
    return float3(nm_pcg((uint3)p)) / 4294967295.0;
}

int kl_positiveModulo(int value, int modulus)
{
    if (modulus == 0) { return 0; }
    int r = value % modulus;
    if (r < 0) { r += modulus; }
    return r;
}

float3 kl_randomFromLatticeWithOffset(float2 st, float freq, int2 offset)
{
    float2 lattice = st * freq;
    float2 baseFloor = floor(lattice);
    int2 base = (int2)baseFloor + offset;
    // (frac unused beyond xCombined per WGSL; kept literal) ---------------------
    float2 frac_ = lattice - baseFloor;
    int seedInt = (int)floor((float)seed);
    float seedFrac = frac((float)seed);
    float xCombined = frac_.x + seedFrac;
    int xi = base.x + seedInt + (int)floor(xCombined);
    int yi = base.y;
    if (wrap != 0)
    {
        int freqInt = (int)(freq + 0.5);
        if (freqInt > 0)
        {
            xi = kl_positiveModulo(xi, freqInt);
            yi = kl_positiveModulo(yi, freqInt);
        }
    }
    uint xBits = (uint)xi;
    uint yBits = (uint)yi;
    uint seedBits = asuint((float)seed);
    uint fracBits = asuint(seedFrac);
    uint3 jitter = uint3(
        (fracBits * 374761393u) ^ 0x9E3779B9u,
        (fracBits * 668265263u) ^ 0x7F4A7C15u,
        (fracBits * 2246822519u) ^ 0x94D049B4u
    );
    uint3 state = uint3(xBits, yBits, seedBits) ^ jitter;
    uint3 prngState = nm_pcg(state);
    float denom = 4294967295.0;
    return float3((float)prngState.x / denom, (float)prngState.y / denom, (float)prngState.z / denom);
}

float kl_constant(float2 st, float freq)
{
    float3 randTime = kl_randomFromLatticeWithOffset(st, freq, int2(40, 0));
    float scaledTime = kl_periodicFunction(randTime.x - time) * kl_map(abs(speed), 0.0, 100.0, 0.0, 0.333);
    float3 rand = kl_randomFromLatticeWithOffset(st, freq, int2(0, 0));
    return kl_periodicFunction(rand.y - scaledTime);
}

float kl_quadratic3(float p0, float p1, float p2, float t)
{
    float t2 = t * t;
    float B0 = 0.5 * (1.0 - t) * (1.0 - t);
    float B1 = 0.5 * (-2.0 * t2 + 2.0 * t + 1.0);
    float B2 = 0.5 * t2;
    return p0 * B0 + p1 * B1 + p2 * B2;
}

float kl_catmullRom3(float p0, float p1, float p2, float t)
{
    float t2 = t * t;
    float t3 = t2 * t;
    return p1 + 0.5 * t * (p2 - p0) + 0.5 * t2 * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p0) + 0.5 * t3 * (-p0 + 3.0 * p1 - 3.0 * p2 + p0);
}

float kl_quadratic3x3Value(float2 st, float freq)
{
    float2 f = frac(st * freq);
    float nd = 1.0 / freq;
    float v00 = kl_constant(st + float2(-nd, -nd), freq);
    float v10 = kl_constant(st + float2(0.0, -nd), freq);
    float v20 = kl_constant(st + float2(nd, -nd), freq);
    float v01 = kl_constant(st + float2(-nd, 0.0), freq);
    float v11 = kl_constant(st, freq);
    float v21 = kl_constant(st + float2(nd, 0.0), freq);
    float v02 = kl_constant(st + float2(-nd, nd), freq);
    float v12 = kl_constant(st + float2(0.0, nd), freq);
    float v22 = kl_constant(st + float2(nd, nd), freq);
    float y0 = kl_quadratic3(v00, v10, v20, f.x);
    float y1 = kl_quadratic3(v01, v11, v21, f.x);
    float y2 = kl_quadratic3(v02, v12, v22, f.x);
    return kl_quadratic3(y0, y1, y2, f.y);
}

float kl_catmullRom3x3Value(float2 st, float freq)
{
    float2 f = frac(st * freq);
    float nd = 1.0 / freq;
    float v00 = kl_constant(st + float2(-nd, -nd), freq);
    float v10 = kl_constant(st + float2(0.0, -nd), freq);
    float v20 = kl_constant(st + float2(nd, -nd), freq);
    float v01 = kl_constant(st + float2(-nd, 0.0), freq);
    float v11 = kl_constant(st, freq);
    float v21 = kl_constant(st + float2(nd, 0.0), freq);
    float v02 = kl_constant(st + float2(-nd, nd), freq);
    float v12 = kl_constant(st + float2(0.0, nd), freq);
    float v22 = kl_constant(st + float2(nd, nd), freq);
    float y0 = kl_catmullRom3(v00, v10, v20, f.x);
    float y1 = kl_catmullRom3(v01, v11, v21, f.x);
    float y2 = kl_catmullRom3(v02, v12, v22, f.x);
    return kl_catmullRom3(y0, y1, y2, f.y);
}

float kl_blendBicubic(float p0, float p1, float p2, float p3, float t)
{
    float t2 = t * t;
    float t3 = t2 * t;
    float B0 = (1.0 - t) * (1.0 - t) * (1.0 - t) / 6.0;
    float B1 = (3.0 * t3 - 6.0 * t2 + 4.0) / 6.0;
    float B2 = (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) / 6.0;
    float B3 = t3 / 6.0;
    return p0 * B0 + p1 * B1 + p2 * B2 + p3 * B3;
}

float kl_catmullRom4(float p0, float p1, float p2, float p3, float t)
{
    return p1 + 0.5 * t * (p2 - p0 + t * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 + t * (3.0 * (p1 - p2) + p3 - p0)));
}

float kl_blendLinearOrCosine(float a, float b, float amount, int interp)
{
    if (interp == 1) { return lerp(a, b, amount); }
    return lerp(a, b, smoothstep(0.0, 1.0, amount));
}

// Simplex noise -----------------------------------------------------------------
float3 kl_mod289_3(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float2 kl_mod289_2(float2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float3 kl_permute3(float3 x) { return kl_mod289_3(((x * 34.0) + 1.0) * x); }

float kl_simplexValue(float2 v)
{
    float4 C = float4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
    float2 i = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12 = float4(x12.xy - i1, x12.zw);
    i = kl_mod289_2(i);
    float3 p = kl_permute3(kl_permute3(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));
    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), float3(0.0, 0.0, 0.0));
    m = m * m;
    m = m * m;
    float3 x = 2.0 * frac(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.y = a0.y * x12.x + h.y * x12.y;
    g.z = a0.z * x12.z + h.z * x12.w;
    return 130.0 * dot(m, g);
}

float kl_sineNoise(float2 st_in, float freq)
{
    float2 st = st_in - float2(0.5 * kl_aspectRatio(), 0.5);
    float3 rand = kl_randomFromLatticeWithOffset(st, freq, int2(20, 0));
    float waveFreq = rand.x * 50.0;
    float waveAmp = rand.y;
    float wavePhase = rand.z * KL_TAU;
    float3 randTime = kl_randomFromLatticeWithOffset(st, freq, int2(40, 0));
    float phaseOffset = kl_periodicFunction(randTime.x - time) * kl_map(abs(speed), 0.0, 100.0, 0.0, 0.333);
    float dist = length(st);
    float sineWave = sin(dist * waveFreq + wavePhase - phaseOffset) * waveAmp;
    return kl_periodicFunction(sineWave);
}

float kl_bicubicValue(float2 st, float freq)
{
    float ndX = 1.0 / freq;
    float ndY = 1.0 / freq;
    float u0 = st.x - ndX; float u1 = st.x; float u2 = st.x + ndX; float u3 = st.x + ndX + ndX;
    float v0 = st.y - ndY; float v1 = st.y; float v2 = st.y + ndY; float v3 = st.y + ndY + ndY;
    float x0y0 = kl_constant(float2(u0, v0), freq); float x0y1 = kl_constant(float2(u0, v1), freq);
    float x0y2 = kl_constant(float2(u0, v2), freq); float x0y3 = kl_constant(float2(u0, v3), freq);
    float x1y0 = kl_constant(float2(u1, v0), freq); float x1y1 = kl_constant(st, freq);
    float x1y2 = kl_constant(float2(u1, v2), freq); float x1y3 = kl_constant(float2(u1, v3), freq);
    float x2y0 = kl_constant(float2(u2, v0), freq); float x2y1 = kl_constant(float2(u2, v1), freq);
    float x2y2 = kl_constant(float2(u2, v2), freq); float x2y3 = kl_constant(float2(u2, v3), freq);
    float x3y0 = kl_constant(float2(u3, v0), freq); float x3y1 = kl_constant(float2(u3, v1), freq);
    float x3y2 = kl_constant(float2(u3, v2), freq); float x3y3 = kl_constant(float2(u3, v3), freq);
    float2 uv = st * freq;
    float y0 = kl_blendBicubic(x0y0, x1y0, x2y0, x3y0, frac(uv.x));
    float y1 = kl_blendBicubic(x0y1, x1y1, x2y1, x3y1, frac(uv.x));
    float y2 = kl_blendBicubic(x0y2, x1y2, x2y2, x3y2, frac(uv.x));
    float y3 = kl_blendBicubic(x0y3, x1y3, x2y3, x3y3, frac(uv.x));
    return kl_blendBicubic(y0, y1, y2, y3, frac(uv.y));
}

float kl_catmullRom4x4Value(float2 st, float freq)
{
    float ndX = 1.0 / freq; float ndY = 1.0 / freq;
    float u0 = st.x - ndX; float u1 = st.x; float u2 = st.x + ndX; float u3 = st.x + ndX + ndX;
    float v0 = st.y - ndY; float v1 = st.y; float v2 = st.y + ndY; float v3 = st.y + ndY + ndY;
    float x0y0 = kl_constant(float2(u0, v0), freq); float x0y1 = kl_constant(float2(u0, v1), freq);
    float x0y2 = kl_constant(float2(u0, v2), freq); float x0y3 = kl_constant(float2(u0, v3), freq);
    float x1y0 = kl_constant(float2(u1, v0), freq); float x1y1 = kl_constant(st, freq);
    float x1y2 = kl_constant(float2(u1, v2), freq); float x1y3 = kl_constant(float2(u1, v3), freq);
    float x2y0 = kl_constant(float2(u2, v0), freq); float x2y1 = kl_constant(float2(u2, v1), freq);
    float x2y2 = kl_constant(float2(u2, v2), freq); float x2y3 = kl_constant(float2(u2, v3), freq);
    float x3y0 = kl_constant(float2(u3, v0), freq); float x3y1 = kl_constant(float2(u3, v1), freq);
    float x3y2 = kl_constant(float2(u3, v2), freq); float x3y3 = kl_constant(float2(u3, v3), freq);
    float2 uv = st * freq;
    float y0 = kl_catmullRom4(x0y0, x1y0, x2y0, x3y0, frac(uv.x));
    float y1 = kl_catmullRom4(x0y1, x1y1, x2y1, x3y1, frac(uv.x));
    float y2 = kl_catmullRom4(x0y2, x1y2, x2y2, x3y2, frac(uv.x));
    float y3 = kl_catmullRom4(x0y3, x1y3, x2y3, x3y3, frac(uv.x));
    return kl_catmullRom4(y0, y1, y2, y3, frac(uv.y));
}

float kl_value(float2 st_in, float freq, int interp)
{
    float2 st = st_in - float2(0.5 * kl_aspectRatio(), 0.5);
    if (interp == 3) { return kl_catmullRom3x3Value(st, freq); }
    else if (interp == 4) { return kl_catmullRom4x4Value(st, freq); }
    else if (interp == 5) { return kl_quadratic3x3Value(st, freq); }
    else if (interp == 6) { return kl_bicubicValue(st, freq); }
    else if (interp == 10) { return kl_periodicFunction(kl_simplexValue(st * freq + float2((float)seed, (float)seed))); }
    else if (interp == 11) { return kl_sineNoise(st, freq); }
    float x1y1 = kl_constant(st, freq);
    if (interp == 0) { return x1y1; }
    float ndX = 1.0 / freq; float ndY = 1.0 / freq;
    float x1y2 = kl_constant(float2(st.x, st.y + ndY), freq);
    float x2y1 = kl_constant(float2(st.x + ndX, st.y), freq);
    float x2y2 = kl_constant(float2(st.x + ndX, st.y + ndY), freq);
    float2 uv = st * freq;
    float a = kl_blendLinearOrCosine(x1y1, x2y1, frac(uv.x), interp);
    float b = kl_blendLinearOrCosine(x1y2, x2y2, frac(uv.x), interp);
    return kl_blendLinearOrCosine(a, b, frac(uv.y), interp);
}

float3 kl_hsv2rgb(float3 hsv)
{
    float h = frac(hsv.x); float s = hsv.y; float v = hsv.z;
    float c = v * s; float x = c * (1.0 - abs(frac(h * 6.0) * 2.0 - 1.0)); float m = v - c;
    float3 rgb;
    if (h < 1.0 / 6.0) { rgb = float3(c, x, 0.0); }
    else if (h < 2.0 / 6.0) { rgb = float3(x, c, 0.0); }
    else if (h < 3.0 / 6.0) { rgb = float3(0.0, c, x); }
    else if (h < 4.0 / 6.0) { rgb = float3(0.0, x, c); }
    else if (h < 5.0 / 6.0) { rgb = float3(x, 0.0, c); }
    else { rgb = float3(c, 0.0, x); }
    return rgb + float3(m, m, m);
}

float3 kl_rgb2hsv(float3 rgb)
{
    float maxC = max(rgb.r, max(rgb.g, rgb.b));
    float minC = min(rgb.r, min(rgb.g, rgb.b));
    float delta = maxC - minC;
    float h = 0.0;
    if (delta != 0.0)
    {
        // WGSL `% 6.0` truncates toward zero (sign of x); HLSL `%` matches.
        if (maxC == rgb.r) { h = ((rgb.g - rgb.b) / delta % 6.0) / 6.0; }
        else if (maxC == rgb.g) { h = ((rgb.b - rgb.r) / delta + 2.0) / 6.0; }
        else { h = ((rgb.r - rgb.g) / delta + 4.0) / 6.0; }
    }
    float s = (maxC != 0.0) ? (delta / maxC) : 0.0;
    return float3(h, s, maxC);
}

// convolve — WGSL `1.0 / u.resolution`; GLSL `1.0 / resolution`. Per-tile size.
float3 kl_convolve(float2 uv, float kernel[9], bool divide)
{
    float2 steps = 1.0 / resolution;
    float2 offsets[9] =
    {
        float2(-steps.x, -steps.y), float2(0.0, -steps.y), float2(steps.x, -steps.y),
        float2(-steps.x, 0.0),      float2(0.0, 0.0),      float2(steps.x, 0.0),
        float2(-steps.x, steps.y),  float2(0.0, steps.y),  float2(steps.x, steps.y)
    };
    float kernelWeight = 0.0;
    float3 conv = float3(0.0, 0.0, 0.0);
    float ew = effectWidth;
    [unroll]
    for (int i = 0; i < 9; i++)
    {
        float3 color = inputTex.Sample(sampler_inputTex, uv + offsets[i] * ew).rgb;
        conv += color * kernel[i];
        kernelWeight += kernel[i];
    }
    if (divide && kernelWeight != 0.0) { conv /= kernelWeight; }
    return clamp(conv, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

float3 kl_derivatives(float3 color, float2 uv, bool divide)
{
    float deriv_x[9] = { 0.0, 0.0, 0.0, 0.0, 1.0, -1.0, 0.0, 0.0, 0.0 };
    float deriv_y[9] = { 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, -1.0, 0.0 };
    return color * distance(kl_convolve(uv, deriv_x, divide), kl_convolve(uv, deriv_y, divide));
}

float3 kl_sobel(float3 color, float2 uv)
{
    float sobel_x[9] = { 1.0, 0.0, -1.0, 2.0, 0.0, -2.0, 1.0, 0.0, -1.0 };
    float sobel_y[9] = { 1.0, 2.0, 1.0, 0.0, 0.0, 0.0, -1.0, -2.0, -1.0 };
    return color * distance(kl_convolve(uv, sobel_x, false), kl_convolve(uv, sobel_y, false));
}

float3 kl_outline(float3 color, float2 uv)
{
    float sobel_x[9] = { 1.0, 0.0, -1.0, 2.0, 0.0, -2.0, 1.0, 0.0, -1.0 };
    float sobel_y[9] = { 1.0, 2.0, 1.0, 0.0, 0.0, 0.0, -1.0, -2.0, -1.0 };
    return max(color - distance(kl_convolve(uv, sobel_x, false), kl_convolve(uv, sobel_y, false)), float3(0.0, 0.0, 0.0));
}

float3 kl_shadow(float3 color_in, float2 uv)
{
    float sobel_x[9] = { 1.0, 0.0, -1.0, 2.0, 0.0, -2.0, 1.0, 0.0, -1.0 };
    float sobel_y[9] = { 1.0, 2.0, 1.0, 0.0, 0.0, 0.0, -1.0, -2.0, -1.0 };
    float3 color = kl_rgb2hsv(color_in);
    float shade_dist = distance(kl_convolve(uv, sobel_x, false), kl_convolve(uv, sobel_y, false));
    float highlight = shade_dist * shade_dist;
    float shade = (1.0 - ((1.0 - color.z) * (1.0 - highlight))) * shade_dist;
    color = float3(color.x, color.y, lerp(color.z, shade, 0.75));
    return kl_hsv2rgb(color);
}

float3 kl_convolutionKernel(float3 color, float2 uv)
{
    float emboss[9]  = { -2.0, -1.0, 0.0, -1.0, 1.0, 1.0, 0.0, 1.0, 2.0 };
    float sharpen[9] = { -1.0, 0.0, -1.0, 0.0, 5.0, 0.0, -1.0, 0.0, -1.0 };
    float blur[9]    = { 1.0, 2.0, 1.0, 2.0, 4.0, 2.0, 1.0, 2.0, 1.0 };
    float edge2[9]   = { -1.0, 0.0, -1.0, 0.0, 4.0, 0.0, -1.0, 0.0, -1.0 };
    [branch]
    if (KERNEL == 1) { return kl_convolve(uv, blur, true); }
    else if (KERNEL == 2) { return kl_derivatives(color, uv, true); }
    else if (KERNEL == 120) { return clamp(kl_derivatives(color, uv, false) * 2.5, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0)); }
    else if (KERNEL == 3) { return color * kl_convolve(uv, edge2, true); }
    else if (KERNEL == 4) { return kl_convolve(uv, emboss, false); }
    else if (KERNEL == 5) { return kl_outline(color, uv); }
    else if (KERNEL == 6) { return kl_shadow(color, uv); }
    else if (KERNEL == 7) { return kl_convolve(uv, sharpen, false); }
    else if (KERNEL == 8) { return kl_sobel(color, uv); }
    return color;
}

float kl_shape(float2 st_in, int sides, float blend)
{
    if (sides < 2) { return distance(st_in, float2(0.5, 0.5)); }
    float2 st = float2(st_in.x, 1.0 - st_in.y) * 2.0 - float2(kl_aspectRatio(), 1.0);
    float a = atan2(st.x, st.y) + KL_PI;
    float r = KL_TAU / (float)sides;
    return cos(floor(0.5 + a / r) * r - a) * length(st) * blend;
}

float3 kl_posterize(float3 color, float levIn)
{
    float lev = levIn;
    if (lev == 0.0) { return color; }
    else if (lev == 1.0) { lev = 2.0; }
    float3 c = clamp(color, float3(0.0, 0.0, 0.0), float3(0.99, 0.99, 0.99));
    return (floor(c * lev) + 0.5) / lev;
}

float3 kl_pixellate(float2 uv, float size)
{
    float dx = size / resolution.x;
    float dy = size / resolution.y;
    return inputTex.Sample(sampler_inputTex, float2(dx * floor(uv.x / dx), dy * floor(uv.y / dy))).rgb;
}

float kl_circles(float2 st, float freq)
{
    return length(st - float2(0.5 * kl_aspectRatio(), 0.5)) * freq;
}

float kl_rings(float2 st, float freq)
{
    return cos(length(st - float2(0.5 * kl_aspectRatio(), 0.5)) * KL_PI * freq);
}

float kl_diamonds(float2 st, float freq)
{
    float2 s = st; s.x -= 0.5 * kl_aspectRatio(); s *= freq;
    return sin(s.x * KL_PI) + sin(s.y * KL_PI);
}

float kl_getMetric(float2 st)
{
    float2 diff = float2(0.5 * kl_aspectRatio(), 0.5) - st;
    if (METRIC == 0) { return length(st - float2(0.5 * kl_aspectRatio(), 0.5)); }
    else if (METRIC == 1) { return abs(diff.x) + abs(diff.y); }
    else if (METRIC == 2) { return max(max(abs(diff.x) - diff.y * -0.5, -1.0 * diff.y), max(abs(diff.x) - diff.y * 0.5, 1.0 * diff.y)); }
    else if (METRIC == 3) { return max((abs(diff.x) + abs(diff.y)) / sqrt(2.0), max(abs(diff.x), abs(diff.y))); }
    else if (METRIC == 4) { return max(abs(diff.x), abs(diff.y)); }
    else if (METRIC == 5) { return max(abs(diff.x) - diff.y * -0.5, -1.0 * diff.y); }
    return 1.0;
}

float kl_offset(float2 st, float freq)
{
    if (LOOP_OFFSET == 10) { return kl_circles(st, freq); }
    else if (LOOP_OFFSET == 20) { return kl_shape(st, 3, freq * 0.5); }
    else if (LOOP_OFFSET == 30) { return (abs(st.x - 0.5 * kl_aspectRatio()) + abs(st.y - 0.5)) * freq * 0.5; }
    else if (LOOP_OFFSET == 40) { return kl_shape(st, 4, freq * 0.5); }
    else if (LOOP_OFFSET == 50) { return kl_shape(st, 5, freq * 0.5); }
    else if (LOOP_OFFSET == 60) { return kl_shape(st, 6, freq * 0.5); }
    else if (LOOP_OFFSET == 70) { return kl_shape(st, 7, freq * 0.5); }
    else if (LOOP_OFFSET == 80) { return kl_shape(st, 8, freq * 0.5); }
    else if (LOOP_OFFSET == 90) { return kl_shape(st, 9, freq * 0.5); }
    else if (LOOP_OFFSET == 100) { return kl_shape(st, 10, freq * 0.5); }
    else if (LOOP_OFFSET == 110) { return kl_shape(st, 11, freq * 0.5); }
    else if (LOOP_OFFSET == 120) { return kl_shape(st, 12, freq * 0.5); }
    else if (LOOP_OFFSET == 200) { return st.x * freq * 0.5; }
    else if (LOOP_OFFSET == 210) { return st.y * freq * 0.5; }
    else if (LOOP_OFFSET == 300) { return 1.0 - kl_value(st, freq, 0); }
    else if (LOOP_OFFSET == 310) { return 1.0 - kl_value(st, freq, 1); }
    else if (LOOP_OFFSET == 320) { return 1.0 - kl_value(st, freq, 2); }
    else if (LOOP_OFFSET == 330) { return 1.0 - kl_value(st, freq, 3); }
    else if (LOOP_OFFSET == 340) { return 1.0 - kl_value(st, freq, 4); }
    else if (LOOP_OFFSET == 350) { return 1.0 - kl_value(st, freq, 5); }
    else if (LOOP_OFFSET == 360) { return 1.0 - kl_value(st, freq, 6); }
    else if (LOOP_OFFSET == 370) { return 1.0 - kl_value(st, freq, 10); }
    else if (LOOP_OFFSET == 380) { return 1.0 - kl_value(st, freq, 11); }
    else if (LOOP_OFFSET == 400) { return 1.0 - kl_rings(st, freq); }
    else if (LOOP_OFFSET == 410) { return 1.0 - kl_diamonds(st, freq); }
    return 0.0;
}

// kaleidoscope folds a signed angle -> GLSL-style mod (sign of divisor) via
// nm_mod, NOT HLSL fmod (H6). WGSL `glslMod(x,y) = x - y*floor(x/y)` == nm_mod.
float2 kl_kaleidoscope(float2 st_in, float sides, float blendy)
{
    float r = kl_getMetric(st_in) + blendy;
    float2 st = st_in - float2(0.5 * kl_aspectRatio(), 0.5);
    float a = atan2(st.y, st.x);
    float dir = time;
    if (DIRECTION == 1) { dir *= -1.0; }
    else if (DIRECTION == 2) { dir = 1.0; }
    float ma = nm_mod(a + radians(90.0) - radians(360.0 / sides * dir), KL_TAU / sides);
    ma = abs(ma - KL_PI / sides);
    st = r * float2(cos(ma), sin(ma));
    return frac(st);
}

// ---- Pass: "kaleido" ---------------------------------------------------------
float4 NMFrag_kaleido(NMVaryings i) : SV_Target
{
    // WGSL: uv = position.xy / u.resolution.y. GLSL: (gl_FragCoord + tileOffset)
    // / fullResolution.y. Divide by HEIGHT; uv.x spans [0, aspect] (H13).
    float2 globalCoord = NM_GlobalCoord(i);
    float2 uv = globalCoord / fullResolution.y;

    float lf = kl_map(loopScale, 1.0, 100.0, 6.0, 1.0);
    if (wrap != 0) { lf = floor(lf); }

    float t = time + kl_offset(uv, lf) * speed * 0.01;
    float blendy = kl_periodicFunction(t) * kl_map(abs(speed), 0.0, 100.0, 0.0, 2.0);

    uv = kl_kaleidoscope(uv, kaleido, blendy);
    float4 color = inputTex.Sample(sampler_inputTex, uv);

    [branch]
    if (effectWidth != 0.0 && KERNEL != 0)
    {
        if (KERNEL == 10) { color = float4(kl_pixellate(uv, effectWidth * 4.0), color.a); }
        else if (KERNEL == 110) { color = float4(kl_posterize(color.rgb, floor(kl_map(effectWidth, 0.0, 10.0, 0.0, 20.0))), color.a); }
        else { color = float4(kl_convolutionKernel(color.rgb, uv), color.a); }
    }

    return color;
}

#endif // NM_EFFECT_KALEIDO_INCLUDED
