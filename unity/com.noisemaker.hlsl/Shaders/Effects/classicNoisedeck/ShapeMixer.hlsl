#ifndef NM_SHAPEMIXER_INCLUDED
#define NM_SHAPEMIXER_INCLUDED

// =============================================================================
// ShapeMixer.hlsl — classicNoisedeck/shapeMixer, ported PIXEL-IDENTICALLY from
// the canonical WGSL: shaders/effects/classicNoisedeck/shapeMixer/wgsl/shapeMixer.wgsl
//
// Two-input mixer (color1 = inputTex, color2 = tex). Generates a procedural
// "shape" field (circles/diamonds/polygons/scan/noise/rings/sine), animates it,
// blends the two inputs' per-pixel luminance under a selectable blend mode, then
// colorizes via a palette (cosine / hsv / oklab / hue-rotate modes). One render
// pass (definition.js passes.length==1, program "shapeMixer").
//
// PORTING-GUIDE notes:
//  * All helpers below are this effect's OWN copies, ported VERBATIM inline
//    (golden rule 2). hsv2rgb/rgb2hsv/posterize/shape/etc. differ between effects
//    despite shared names — do NOT substitute NMCore versions.
//  * aspectRatio(): the WGSL defines aspect = u.resolution.x / u.resolution.y
//    (the CURRENT render target). This is NOT NMFullscreen's `aspectRatio` macro
//    (which uses fullResolution). We define a local nm_aspectRatio() from
//    `resolution` to match the WGSL exactly. // TODO(verify) untiled: resolution
//    == fullResolution so they coincide; tiled renders would differ but the
//    reference uses u.resolution here.
//  * LOOP_OFFSET: definition.js declares loopOffset as a compile-time `define`.
//    Per PORTING-GUIDE we declare it as an int uniform and branch at runtime.
//    The WGSL `offset()` / `main()` reference `LOOP_OFFSET` as a constant; here
//    it is the `LOOP_OFFSET` uniform. All variants are kept; branches use the
//    same comparisons as the WGSL.
//  * select(b,a,cond) (WGSL) -> cond ? a : b (HLSL) — reversed arg order. Applied
//    literally in rgb2hsv saturation and value()'s interp computation.
//  * `%` on floats in WGSL (rgb2hsv hue, blendFloat mode 5, hue cycle, blendVec3
//    mode 5) is GLSL-style mod (sign of divisor) -> nm_mod. WGSL `%` on f32 is
//    actually fmod-like (sign of dividend); however the reference GLSL uses mod().
//    // TODO(verify): WGSL f32 `%` truncates toward zero. To stay faithful to the
//    canonical WGSL we use HLSL fmod for those f32 `%` ops below. nm_mod is used
//    only where the GLSL/Python semantics demand sign-of-divisor — none here, so
//    fmod matches WGSL.
//  * bitcast<u32>(f) -> asuint(f) (bit reinterpret). u32(float) -> (uint) cast
//    (numeric truncation). vec3u(p) in pcg arg is (uint3) truncation.
//  * pcg/prng here are LOCAL copies matching the WGSL's own (prng divides by
//    f32(0xffffffffu) and does plain vec3u(p) truncation — NOT NMCore's sign-fold
//    nm_prng). Ported inline to match the WGSL bit-for-bit.
//  * refract(I,N,eta): HLSL refract matches GLSL/WGSL refract semantics.
//  * Linear, clamp-to-edge, non-sRGB samplers (H7) — set in ShapeMixer.shader.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
int    blendMode;       // globals.blendMode.uniform, default 2 (max)
int    LOOP_OFFSET;     // globals.loopOffset.define "LOOP_OFFSET", default 10 (circle)
float  loopScale;       // globals.loopScale.uniform, default 80
int    wrap;            // globals.wrap.uniform (boolean), default 1
int    seed;            // globals.seed.uniform, default 1
int    animate;         // globals.animate.uniform, default 1 (forward)
int    palette;         // globals.palette.uniform, default 41 (UI-only; unused in body)
int    paletteMode;     // globals.paletteMode.uniform, default 0
float3 paletteOffset;   // globals.paletteOffset.uniform, default (0.83,0.6,0.63)
float3 paletteAmp;      // globals.paletteAmp.uniform, default (0.5,0.5,0.5)
float3 paletteFreq;     // globals.paletteFreq.uniform, default (1,1,1)
float3 palettePhase;    // globals.palettePhase.uniform, default (0.3,0.1,0)
int    cyclePalette;    // globals.cyclePalette.uniform, default 1 (forward)
float  rotatePalette;   // globals.rotatePalette.uniform, default 0
int    repeatPalette;   // globals.repeatPalette.uniform, default 1
int    levels;          // globals.levels.uniform, default 0

// Local PI/TAU (WGSL consts).
static const float SM_PI  = 3.14159265359;
static const float SM_TAU = 6.28318530718;

// aspectRatio() = u.resolution.x / u.resolution.y (current target). Local copy.
float nm_aspectRatio() { return resolution.x / resolution.y; }

float mapRange(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

float periodicFunction(float p)
{
    return mapRange(sin(p * SM_TAU), -1.0, 1.0, 0.0, 1.0);
}

// PCG PRNG — LOCAL copy (matches the WGSL's own).
uint3 pcg(uint3 v_in)
{
    uint3 v = v_in * 1664525u + 1013904223u;
    v.x += v.y * v.z;
    v.y += v.z * v.x;
    v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z;
    v.y += v.z * v.x;
    v.z += v.x * v.y;
    return v;
}

float3 prng(float3 p)
{
    return float3(pcg((uint3)p)) / 4294967295.0;
}

float3 hsv2rgb(float3 hsv)
{
    float h = frac(hsv.x);
    float s = hsv.y;
    float v = hsv.z;
    float c = v * s;
    float x = c * (1.0 - abs(frac(h * 6.0) * 2.0 - 1.0));
    float m = v - c;
    float3 rgb;
    if (h < 1.0/6.0) { rgb = float3(c, x, 0.0); }
    else if (h < 2.0/6.0) { rgb = float3(x, c, 0.0); }
    else if (h < 3.0/6.0) { rgb = float3(0.0, c, x); }
    else if (h < 4.0/6.0) { rgb = float3(0.0, x, c); }
    else if (h < 5.0/6.0) { rgb = float3(x, 0.0, c); }
    else { rgb = float3(c, 0.0, x); }
    return rgb + float3(m, m, m);
}

float3 rgb2hsv(float3 rgb)
{
    float maxC = max(rgb.r, max(rgb.g, rgb.b));
    float minC = min(rgb.r, min(rgb.g, rgb.b));
    float delta = maxC - minC;
    float h = 0.0;
    if (delta != 0.0) {
        // GLSL golden (shapeMixer.glsl:110) uses floor-based mod():
        // mod((g-b)/delta, 6.0). For maxC==r and g<b the arg is negative, where
        // floor-mod (GLSL) and fmod (WGSL `%`) diverge by 6 → large hue error.
        // The parity golden is WebGL2/GLSL, so match GLSL: use nm_mod.
        if (maxC == rgb.r) { h = nm_mod((rgb.g - rgb.b) / delta, 6.0) / 6.0; }
        else if (maxC == rgb.g) { h = ((rgb.b - rgb.r) / delta + 2.0) / 6.0; }
        else { h = ((rgb.r - rgb.g) / delta + 4.0) / 6.0; }
    }
    float s = (maxC != 0.0) ? (delta / maxC) : 0.0;
    return float3(h, s, maxC);
}

float3 linearToSrgb(float3 lin)
{
    float3 srgb;
    srgb.x = (lin.x <= 0.0031308) ? (lin.x * 12.92) : (1.055 * pow(lin.x, 1.0/2.4) - 0.055);
    srgb.y = (lin.y <= 0.0031308) ? (lin.y * 12.92) : (1.055 * pow(lin.y, 1.0/2.4) - 0.055);
    srgb.z = (lin.z <= 0.0031308) ? (lin.z * 12.92) : (1.055 * pow(lin.z, 1.0/2.4) - 0.055);
    return srgb;
}

// OKLab matrices. WGSL mat3x3f columns -> HLSL float3x3 built row-by-row so that
// `M * c` (WGSL: column-major, M*v = sum_i col_i * v[i]) is reproduced via mul(M, c)
// with M's ROWS = WGSL columns transposed. We store the matrices transposed and
// use mul(c, M) is error-prone; instead we expand the matrix-vector products
// explicitly below to guarantee bit-identical evaluation order.

// WGSL: lms = invB * c ; oklab = invA * (sign(lms) * pow(abs(lms), 0.333333))
float3 oklab_from_linear_srgb(float3 c)
{
    // invB columns (WGSL mat3x3f, each vec3f = a COLUMN):
    //   col0 = (0.4121656120, 0.2118591070, 0.0883097947)
    //   col1 = (0.5362752080, 0.6807189584, 0.2818474174)
    //   col2 = (0.0514575653, 0.1074065790, 0.6302613616)
    // invB * c = col0*c.x + col1*c.y + col2*c.z  =>  row i picks col0[i],col1[i],col2[i]
    float3 lms;
    lms.x = 0.4121656120 * c.x + 0.5362752080 * c.y + 0.0514575653 * c.z;
    lms.y = 0.2118591070 * c.x + 0.6807189584 * c.y + 0.1074065790 * c.z;
    lms.z = 0.0883097947 * c.x + 0.2818474174 * c.y + 0.6302613616 * c.z;
    float3 t = sign(lms) * pow(abs(lms), float3(0.333333, 0.333333, 0.333333));
    // invA columns (WGSL):
    //   col0 = (0.2104542553, 0.7936177850, -0.0040720468)
    //   col1 = (1.9779984951, -2.4285922050, 0.4505937099)
    //   col2 = (0.0259040371, 0.7827717662, -0.8086757660)
    float3 o;
    o.x = 0.2104542553 * t.x + 1.9779984951 * t.y + 0.0259040371 * t.z;
    o.y = 0.7936177850 * t.x + (-2.4285922050) * t.y + 0.7827717662 * t.z;
    o.z = (-0.0040720468) * t.x + 0.4505937099 * t.y + (-0.8086757660) * t.z;
    return o;
}

// WGSL: lms = fwdA * c ; out = fwdB * (lms*lms*lms)
float3 linear_srgb_from_oklab(float3 c)
{
    // fwdA columns (WGSL):
    //   col0 = (1.0, 1.0, 1.0)
    //   col1 = (0.3963377774, -0.1055613458, -0.0894841775)
    //   col2 = (0.2158037573, -0.0638541728, -1.2914855480)
    float3 lms;
    lms.x = 1.0 * c.x + 0.3963377774 * c.y + 0.2158037573 * c.z;
    lms.y = 1.0 * c.x + (-0.1055613458) * c.y + (-0.0638541728) * c.z;
    lms.z = 1.0 * c.x + (-0.0894841775) * c.y + (-1.2914855480) * c.z;
    float3 lms3 = lms * lms * lms;
    // fwdB columns (WGSL mat3x3f, each vec3f = a COLUMN):
    //   col0 = (4.0767245293, -1.2681437731, -0.0041119885)
    //   col1 = (-3.3072168827, 2.6093323231, -0.7034763098)
    //   col2 = (0.2307590544, -0.3411344290, 1.7068625689)
    // fwdB * v => row i picks col0[i],col1[i],col2[i]
    float3 o;
    o.x = 4.0767245293 * lms3.x + (-3.3072168827) * lms3.y + 0.2307590544 * lms3.z;
    o.y = (-1.2681437731) * lms3.x + 2.6093323231 * lms3.y + (-0.3411344290) * lms3.z;
    o.z = (-0.0041119885) * lms3.x + (-0.7034763098) * lms3.y + 1.7068625689 * lms3.z;
    return o;
}

float3 pal(float t_in)
{
    float t = t_in * (float)repeatPalette + rotatePalette * 0.01;
    float3 color = paletteOffset + paletteAmp * cos(SM_TAU * (paletteFreq * t + palettePhase));
    if (paletteMode == 1) { color = hsv2rgb(color); }
    else if (paletteMode == 2) {
        color.g = color.g * -0.509 + 0.276;
        color.b = color.b * -0.509 + 0.198;
        color = linear_srgb_from_oklab(color);
        color = linearToSrgb(color);
    }
    return color;
}

float luminance(float3 color)
{
    return rgb2hsv(color).b;
}

float posterize(float d_in, float levIn)
{
    float lev = levIn;
    if (lev == 0.0) { return d_in; }
    else if (lev == 1.0) { lev = 2.0; }
    float d = clamp(d_in, 0.0, 0.99);
    return (floor(d * lev) + 0.5) / lev;
}

float posterize2(float d, float levIn)
{
    if (levIn == 0.0) { return d; }
    float lev = levIn + 0.1;
    return floor(d * lev) / lev;
}

float3 posterize2_vec3(float3 c, float lev)
{
    return float3(posterize2(c.r, lev), posterize2(c.g, lev), posterize2(c.b, lev));
}

// Shapes
float rings(float2 st, float freq)
{
    float dist = length(st - float2(0.5 * nm_aspectRatio(), 0.5));
    return cos(dist * SM_PI * freq);
}

float circles(float2 st, float freq)
{
    float dist = length(st - float2(0.5 * nm_aspectRatio(), 0.5));
    return dist * freq;
}

float diamonds(float2 st_in, float freq)
{
    float2 st = st_in;
    st -= float2(0.5 * nm_aspectRatio(), 0.5);
    st *= freq;
    return cos(st.x * SM_PI) + cos(st.y * SM_PI);
}

float shape(float2 st_in, int sides, float blend)
{
    float2 st = st_in * 2.0 - float2(nm_aspectRatio(), 1.0);
    float a = atan2(st.x, st.y) + SM_PI;
    float r = SM_TAU / (float)sides;
    return cos(floor(0.5 + a / r) * r - a) * length(st) * blend;
}

// Noise functions
int positiveModulo(int value, int modulus)
{
    if (modulus == 0) { return 0; }
    int r = value % modulus;
    if (r < 0) { r += modulus; }
    return r;
}

float3 randomFromLatticeWithOffset(float2 st, float freq, int2 offset)
{
    float2 lattice = st * freq;
    float2 baseFloor = floor(lattice);
    int2 base = (int2)baseFloor + offset;
    float2 fracv = lattice - baseFloor;
    int seedInt = (int)floor((float)seed);
    float seedFrac = frac((float)seed);
    float xCombined = fracv.x + seedFrac;
    int xi = base.x + seedInt + (int)floor(xCombined);
    int yi = base.y;
    if (wrap != 0) {
        int freqInt = (int)(freq + 0.5);
        if (freqInt > 0) {
            xi = positiveModulo(xi, freqInt);
            yi = positiveModulo(yi, freqInt);
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
    uint3 prngState = pcg(state);
    float denom = 4294967295.0;
    return float3((float)prngState.x / denom, (float)prngState.y / denom, (float)prngState.z / denom);
}

float constant(float2 st, float freq)
{
    float3 randTime = randomFromLatticeWithOffset(st, freq, int2(40, 0));
    float scaledTime = 1.0;
    if (animate == -1) { scaledTime = periodicFunction(randTime.x - time); }
    else if (animate == 1) { scaledTime = periodicFunction(randTime.x + time); }
    float3 rnd = randomFromLatticeWithOffset(st, freq, int2(0, 0));
    return periodicFunction(rnd.x - scaledTime);
}

float quadratic3(float p0, float p1, float p2, float t)
{
    float t2 = t * t;
    float B0 = 0.5 * (1.0 - t) * (1.0 - t);
    float B1 = 0.5 * (-2.0 * t2 + 2.0 * t + 1.0);
    float B2 = 0.5 * t2;
    return p0 * B0 + p1 * B1 + p2 * B2;
}

float quadratic3x3Value(float2 st, float freq)
{
    float2 f = frac(st * freq);
    float nd = 1.0 / freq;
    float v00 = constant(st + float2(-nd, -nd), freq);
    float v10 = constant(st + float2(0.0, -nd), freq);
    float v20 = constant(st + float2(nd, -nd), freq);
    float v01 = constant(st + float2(-nd, 0.0), freq);
    float v11 = constant(st, freq);
    float v21 = constant(st + float2(nd, 0.0), freq);
    float v02 = constant(st + float2(-nd, nd), freq);
    float v12 = constant(st + float2(0.0, nd), freq);
    float v22 = constant(st + float2(nd, nd), freq);
    float y0 = quadratic3(v00, v10, v20, f.x);
    float y1 = quadratic3(v01, v11, v21, f.x);
    float y2 = quadratic3(v02, v12, v22, f.x);
    return quadratic3(y0, y1, y2, f.y);
}

float blendLinearOrCosine(float a, float b, float amount, int interp)
{
    if (interp == 1) { return lerp(a, b, amount); }
    return lerp(a, b, smoothstep(0.0, 1.0, amount));
}

// Simplex noise
float3 mod289_3(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float2 mod289_2(float2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float3 permute3(float3 x) { return mod289_3(((x * 34.0) + 1.0) * x); }

float simplexValue(float2 st_in, float freq, float s, float blend)
{
    float4 C = float4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
    float2 uv = st_in * freq;
    uv.x += s;
    float2 i = floor(uv + dot(uv, C.yy));
    float2 x0 = uv - i + dot(i, C.xx);
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12 = float4(x12.xy - i1, x12.zw);
    i = mod289_2(i);
    float3 p = permute3(permute3(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));
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
    float v = 130.0 * dot(m, g);
    return periodicFunction(mapRange(v, -1.0, 1.0, 0.0, 1.0) - blend);
}

float sineNoise(float2 st_in, float freq)
{
    float2 st = st_in;
    st -= float2(nm_aspectRatio() * 0.5, 0.5);
    st *= freq;
    st += float2(nm_aspectRatio() * 0.5, 0.5);
    float3 r1 = prng(float3((float)seed, (float)seed, (float)seed));
    float3 r2 = prng(float3((float)seed + 10.0, (float)seed + 10.0, (float)seed + 10.0));
    float scaleA = r1.x * SM_TAU;
    float scaleC = r1.y * SM_TAU;
    float scaleB = r1.z * SM_TAU;
    float scaleD = r2.x * SM_TAU;
    float offA = r2.y * SM_TAU;
    float offB = r2.z * SM_TAU;
    return sin(scaleA * st.x + sin(scaleB * st.y + offA)) + sin(scaleC * st.y + sin(scaleD * st.x + offB)) * 0.5 + 0.5;
}

float value(float2 st, float freq, int interp)
{
    if (interp == 5) { return quadratic3x3Value(st, freq); }
    else if (interp == 10) {
        float scaledTime = 1.0;
        if (animate == -1) { scaledTime = simplexValue(st, freq, (float)seed + 40.0, time); }
        else if (animate == 1) { scaledTime = simplexValue(st, freq, (float)seed + 40.0, -time); }
        return simplexValue(st, freq, (float)seed, scaledTime);
    }
    float x1y1 = constant(st, freq);
    if (interp == 0) { return x1y1; }
    float ndX = 1.0 / freq; float ndY = 1.0 / freq;
    float x1y2 = constant(float2(st.x, st.y + ndY), freq);
    float x2y1 = constant(float2(st.x + ndX, st.y), freq);
    float x2y2 = constant(float2(st.x + ndX, st.y + ndY), freq);
    float2 uv = st * freq;
    float a = blendLinearOrCosine(x1y1, x2y1, frac(uv.x), interp);
    float b = blendLinearOrCosine(x1y2, x2y2, frac(uv.x), interp);
    return blendLinearOrCosine(a, b, frac(uv.y), interp);
}

float offset(float2 st_in, float freq)
{
    float2 st = st_in;
    st.x *= nm_aspectRatio();
    if (LOOP_OFFSET == 10) { return circles(st, freq); }
    else if (LOOP_OFFSET == 20) { return shape(st, 3, freq * 0.5); }
    else if (LOOP_OFFSET == 30) { return (abs(st.x - 0.5 * nm_aspectRatio()) + abs(st.y - 0.5)) * freq * 0.5; }
    else if (LOOP_OFFSET >= 40 && LOOP_OFFSET <= 80) {
        int sides = LOOP_OFFSET / 10;
        return shape(st, sides, freq * 0.5);
    }
    else if (LOOP_OFFSET == 200) { return st.x * freq * 0.5; }
    else if (LOOP_OFFSET == 210) { return st.y * freq * 0.5; }
    else if (LOOP_OFFSET == 380) { return 1.0 - sineNoise(st, freq); }
    else if (LOOP_OFFSET >= 300 && LOOP_OFFSET <= 370) {
        int idx = (LOOP_OFFSET - 300) / 10;
        int interp = (idx <= 6) ? idx : (idx + 3);
        return 1.0 - value(st, freq, interp);
    }
    else if (LOOP_OFFSET == 400) { return 1.0 - rings(st, freq); }
    else if (LOOP_OFFSET == 410) { return 1.0 - diamonds(st, freq) * 0.5 + 0.5; }
    return 0.0;
}

float blendFloat(float color1, float color2, int mode, float factorIn)
{
    float factor = 1.0 - factorIn;
    if (mode == 0) { return color1 + color2 * factor; }
    else if (mode == 1) { float c2 = max(0.1, color2 * factor); return color1 / c2; }
    else if (mode == 2) { return max(color1, color2 * factor); }
    else if (mode == 3) { return min(color1, color2 * factor); }
    else if (mode == 4) { return lerp(color1, color2, clamp(factor, 0.0, 1.0)); }
    else if (mode == 5) { float c2 = max(0.1, color2 * factor); return fmod(color1, c2); }
    else if (mode == 6) { return color1 * color2 * factor; }
    else if (mode == 7) {
        // reflect for scalar: r = i - 2*dot(n,i)*n = i - 2*n*i*n = i*(1 - 2*n^2)
        float n = color2 * factor;
        return color1 - 2.0 * n * color1 * n;
    }
    else if (mode == 8) {
        // refract for scalar approximation
        float eta = factor;
        float cosi = color1;
        float k = 1.0 - eta * eta * (1.0 - cosi * cosi);
        if (k < 0.0) { return 0.0; }
        return eta * color1 + (eta * cosi - sqrt(k)) * color2;
    }
    else if (mode == 9) { return color1 - color2 * factor; }
    return lerp(color1, color2, clamp(factor, 0.0, 1.0));
}

float3 blendVec3(float3 color1, float3 color2, int mode, float factorIn)
{
    float factor = 1.0 - factorIn;
    if (mode == 0) { return color1 + color2 * factor; }
    else if (mode == 1) { return color1 / (color2 * factor); }
    else if (mode == 2) { return max(color1, color2 * factor); }
    else if (mode == 3) { return min(color1, color2 * factor); }
    else if (mode == 4) { return lerp(color1, color2, clamp(factor, 0.0, 1.0)); }
    else if (mode == 5) { return fmod(color1, (color2 * factor)); }
    else if (mode == 6) { return color1 * color2 * factor; }
    else if (mode == 7) { return reflect(color1, color2 * factor); }
    else if (mode == 8) { return refract(color1, color2, factor); }
    else if (mode == 9) { return color1 - color2 * factor; }
    return lerp(color1, color2, clamp(factor, 0.0, 1.0));
}

// -----------------------------------------------------------------------------
// nm_shapeMixer — core per-pixel evaluation. Takes the two already-sampled input
// colors (color1 = inputTex, color2 = tex) and the normalized fragment coord
// `st` (= fragCoord.xy / resolution, WGSL line 416), returns the composited RGBA.
// Ported VERBATIM from shapeMixer.wgsl main() lines 415-462.
// -----------------------------------------------------------------------------
float4 nm_shapeMixer(float4 color1, float4 color2, float2 st)
{
    float freq = 1.0;
    if (LOOP_OFFSET == 350) {
        freq = mapRange(loopScale, 1.0, 100.0, 12.0, 0.5);
    } else {
        freq = mapRange(loopScale, 1.0, 100.0, 10.0, 2.0);
    }
    if (LOOP_OFFSET >= 300 && LOOP_OFFSET < 340 && wrap != 0) {
        freq = floor(freq) * 2.0;
    }

    float t = 1.0;
    if (animate == -1) { t = time + offset(st, freq); }
    else if (animate == 1) { t = time - offset(st, freq); }
    else { t = offset(st, freq); }
    float blendy = periodicFunction(t);

    if (LOOP_OFFSET == 0) { blendy = 0.5; }

    float avg1 = luminance(color1.rgb);
    float avg2 = luminance(color2.rgb);
    float avgMix = blendFloat(avg1, avg2, blendMode, blendy);
    float d = posterize(avgMix, (float)levels);

    float4 color;

    if (paletteMode == 4) {
        float3 c = blendVec3(color1.rgb, color2.rgb, blendMode, blendy * 0.5);
        c = rgb2hsv(c);
        float hue = c.r + rotatePalette * 0.01;
        if (cyclePalette == -1) { hue = fmod(hue + time, 1.0); }
        else if (cyclePalette == 1) { hue = fmod(hue - time, 1.0); }
        c = hsv2rgb(float3(hue, c.g, c.b));
        c = posterize2_vec3(c, (float)levels);
        color = float4(c, max(color1.a, color2.a));
    } else {
        float palD = d;
        if (cyclePalette == -1) { palD = d + time; }
        else if (cyclePalette == 1) { palD = d - time; }
        color = float4(pal(palD), max(color1.a, color2.a));
    }

    return color;
}

#endif // NM_SHAPEMIXER_INCLUDED
