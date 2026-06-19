#ifndef NM_EFFECT_CELLREFRACT_INCLUDED
#define NM_EFFECT_CELLREFRACT_INCLUDED

// =============================================================================
// CellRefract.hlsl — classicNoisedeck/cellRefract (func: "cellRefract")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/classicNoisedeck/cellRefract/wgsl/cellRefract.wgsl
// (GLSL consulted only to disambiguate PRNG arg-order / tiling.)
//
// Single-input filter. Cell-noise distance fields refract the input feed; an
// optional convolution / pixellate / posterize kernel is applied at the end.
// Single render pass (program "cellRefract").
//
// PORTING-GUIDE notes / hazards handled:
//  * PRNG: this effect's prng() is PLAIN (uint3)p TRUNCATION with NO sign-fold.
//    The shared NMCore nm_prng() adds a sign-fold (p>=0 ? p*2 : -p*2+1), which
//    would change every cell origin -> NOT bit-identical. So we port this
//    effect's own prng() INLINE (reusing nm_pcg, which is the identical PCG-3D).
//  * SHAPE and KERNEL are compile-time defines in WGSL/GLSL (injectDefines).
//    Per PORTING-GUIDE they become int uniforms branched at runtime with
//    [branch] (the WGSL keeps all variants and const-folds). Defaults SHAPE=1,
//    KERNEL=0 match the #ifndef fallbacks in the GLSL.
//  * Coordinate: WGSL `st = position.xy / u.resolution`. We use the tiling-aware
//    GLSL form `globalCoord / fullResolution` (identical when untiled, where
//    resolution == fullResolution, tileOffset == 0) and convert the warped UV
//    to a tile-local sample UV exactly as the GLSL does. No per-effect Y flip
//    (ported from WGSL, top-left canonical).
//  * convolve()/pixellate() texel size: WGSL uses `1.0 / u.resolution`; GLSL
//    uses `1.0 / textureSize(inputTex)`. Identical untiled. We use the input
//    texture dimensions (GLSL form, tiling-correct) — `texSize` below.
//  * atan2: WGSL `atan2(st.x, st.y)` -> HLSL `atan2(st.x, st.y)` (arg order kept).
//  * `mix`->lerp. `fract`->frac. `select`->?:. NOTE: rgb2hsv's hue wrap is the
//    WGSL `%` operator (sign-of-dividend), so it ports to fmod, NOT nm_mod.
//  * Full 32-bit float; PCG is bit-sensitive.
//  * TODO(verify): runtime must bind a bilinear, clamp-to-edge, NON-sRGB sampler
//    (H7); diamond SHAPE==1 and each KERNEL branch need parity-harness checks.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (reference binding: sampler@0, inputTex@1) ------
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
float scale;        // globals.scale.uniform        default 50
float cellScale;    // globals.cellScale.uniform     default 75
float cellSmooth;   // globals.smooth.uniform        default 0
float variation;    // globals.variation.uniform     default 0
float speed;        // globals.speed.uniform         default 1   (i32 in WGSL, used as float)
float effectWidth;  // globals.effectWidth.uniform   default 0
float refractAmt;   // globals.amount.uniform        default 23
float direction;    // globals.direction.uniform     default 0
int   wrap;         // globals.wrap.uniform          default 0
int   seed;         // globals.seed.uniform          default 1

// Compile-time defines in the reference; int uniforms + [branch] here.
int SHAPE;          // globals.shape.define          default 1 (diamond)
int KERNEL;         // globals.kernel.define         default 0 (none)

#define CR_PI  3.14159265359
#define CR_TAU 6.28318530718

// ---- This effect's own PRNG (plain truncation, NO sign-fold) -----------------
// WGSL: fn prng(p: vec3f) -> vec3f { return vec3f(pcg(vec3u(p))) / f32(0xffffffffu); }
// pcg is the identical PCG-3D (nm_pcg). vec3u(p) is float->uint TRUNCATION.
float3 cr_prng(float3 p)
{
    return float3(nm_pcg((uint3)p)) / 4294967295.0;
}

float cr_map(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

float3 cr_hsv2rgb(float3 hsv)
{
    float h = frac(hsv.x);
    float s = hsv.y;
    float v = hsv.z;
    float c = v * s;
    float x = c * (1.0 - abs(frac(h * 6.0) * 2.0 - 1.0));
    float m = v - c;
    float3 rgb;
    if (h < 1.0 / 6.0)      { rgb = float3(c, x, 0.0); }
    else if (h < 2.0 / 6.0) { rgb = float3(x, c, 0.0); }
    else if (h < 3.0 / 6.0) { rgb = float3(0.0, c, x); }
    else if (h < 4.0 / 6.0) { rgb = float3(0.0, x, c); }
    else if (h < 5.0 / 6.0) { rgb = float3(x, 0.0, c); }
    else                    { rgb = float3(c, 0.0, x); }
    return rgb + float3(m, m, m);
}

float3 cr_rgb2hsv(float3 rgb)
{
    float maxC = max(rgb.r, max(rgb.g, rgb.b));
    float minC = min(rgb.r, min(rgb.g, rgb.b));
    float delta = maxC - minC;
    float h = 0.0;
    if (delta != 0.0)
    {
        // WGSL uses `%` (sign-of-dividend) here with NO `if (h<0) h+=1` fixup —
        // NOT GLSL always-positive mod. Match WGSL exactly with fmod (the one
        // place fmod is correct, because the reference is WGSL `%`, not mod()).
        if (maxC == rgb.r)      { h = fmod((rgb.g - rgb.b) / delta, 6.0) / 6.0; }
        else if (maxC == rgb.g) { h = ((rgb.b - rgb.r) / delta + 2.0) / 6.0; }
        else                    { h = ((rgb.r - rgb.g) / delta + 4.0) / 6.0; }
    }
    float s = (maxC != 0.0) ? (delta / maxC) : 0.0;
    return float3(h, s, maxC);
}

// convolve — WGSL `1.0/u.resolution`; we use input texture texel size (GLSL form).
float3 cr_convolve(float2 uv, float kernel[9], bool divide, float2 texSize)
{
    float2 steps = 1.0 / texSize;
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

float3 cr_derivatives(float3 color, float2 uv, bool divide, float2 texSize)
{
    float deriv_x[9] = { 0.0, 0.0, 0.0, 0.0, 1.0, -1.0, 0.0, 0.0, 0.0 };
    float deriv_y[9] = { 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, -1.0, 0.0 };
    float3 s1 = cr_convolve(uv, deriv_x, divide, texSize);
    float3 s2 = cr_convolve(uv, deriv_y, divide, texSize);
    float dist = distance(s1, s2);
    return color * dist;
}

float3 cr_sobel(float3 color, float2 uv, float2 texSize)
{
    float sobel_x[9] = { 1.0, 0.0, -1.0, 2.0, 0.0, -2.0, 1.0, 0.0, -1.0 };
    float sobel_y[9] = { 1.0, 2.0, 1.0, 0.0, 0.0, 0.0, -1.0, -2.0, -1.0 };
    float3 s1 = cr_convolve(uv, sobel_x, false, texSize);
    float3 s2 = cr_convolve(uv, sobel_y, false, texSize);
    float dist = distance(s1, s2);
    return color * dist;
}

float3 cr_shadow(float3 color_in, float2 uv, float2 texSize)
{
    float sobel_x[9] = { 1.0, 0.0, -1.0, 2.0, 0.0, -2.0, 1.0, 0.0, -1.0 };
    float sobel_y[9] = { 1.0, 2.0, 1.0, 0.0, 0.0, 0.0, -1.0, -2.0, -1.0 };
    float3 color = cr_rgb2hsv(color_in);
    float3 x = cr_convolve(uv, sobel_x, false, texSize);
    float3 y = cr_convolve(uv, sobel_y, false, texSize);
    float shade_dist = distance(x, y);
    float highlight = shade_dist * shade_dist;
    float shade = (1.0 - ((1.0 - color.z) * (1.0 - highlight))) * shade_dist;
    float alpha = 0.75;
    color = float3(color.x, color.y, lerp(color.z, shade, alpha));
    return cr_hsv2rgb(color);
}

float3 cr_outline(float3 color, float2 uv, float2 texSize)
{
    float sobel_x[9] = { 1.0, 0.0, -1.0, 2.0, 0.0, -2.0, 1.0, 0.0, -1.0 };
    float sobel_y[9] = { 1.0, 2.0, 1.0, 0.0, 0.0, 0.0, -1.0, -2.0, -1.0 };
    float3 s1 = cr_convolve(uv, sobel_x, false, texSize);
    float3 s2 = cr_convolve(uv, sobel_y, false, texSize);
    float dist = distance(s1, s2);
    return max(color - dist, float3(0.0, 0.0, 0.0));
}

float3 cr_convolutionKernel(float3 color, float2 uv, float2 texSize)
{
    float emboss[9]  = { -2.0, -1.0, 0.0, -1.0, 1.0, 1.0, 0.0, 1.0, 2.0 };
    float sharpen[9] = { -1.0, 0.0, -1.0, 0.0, 5.0, 0.0, -1.0, 0.0, -1.0 };
    float blur[9]    = { 1.0, 2.0, 1.0, 2.0, 4.0, 2.0, 1.0, 2.0, 1.0 };
    float edge2[9]   = { -1.0, 0.0, -1.0, 0.0, 4.0, 0.0, -1.0, 0.0, -1.0 };

    [branch]
    if (KERNEL == 1)        { return cr_convolve(uv, blur, true, texSize); }
    else if (KERNEL == 2)   { return cr_derivatives(color, uv, true, texSize); }
    else if (KERNEL == 120) { return clamp(cr_derivatives(color, uv, false, texSize) * 2.5, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0)); }
    else if (KERNEL == 3)   { return color * cr_convolve(uv, edge2, true, texSize); }
    else if (KERNEL == 4)   { return cr_convolve(uv, emboss, false, texSize); }
    else if (KERNEL == 5)   { return cr_outline(color, uv, texSize); }
    else if (KERNEL == 6)   { return cr_shadow(color, uv, texSize); }
    else if (KERNEL == 7)   { return cr_convolve(uv, sharpen, false, texSize); }
    else if (KERNEL == 8)   { return cr_sobel(color, uv, texSize); }
    else if (KERNEL == 9)   { return max(color, cr_convolve(uv, edge2, true, texSize)); }
    return color;
}

// WGSL: fn polarShape(st, sides) { a = atan2(st.x, st.y) + PI; r = TAU/sides;
//        return cos(floor(0.5 + a/r) * r - a) * length(st); }
float cr_polarShape(float2 st, int sides)
{
    float a = atan2(st.x, st.y) + CR_PI;
    float r = CR_TAU / (float)sides;
    return cos(floor(0.5 + a / r) * r - a) * length(st);
}

float cr_shapeFn(float2 st_in, float2 offset, float scaleArg)
{
    float2 st = st_in + offset;
    float d = 1.0;
    [branch]
    if (SHAPE == 0)      { d = length(st * 1.2); }
    else if (SHAPE == 2) { d = cr_polarShape(st * 1.2, 6); }
    else if (SHAPE == 3) { d = cr_polarShape(st * 1.2, 8); }
    else if (SHAPE == 4) { d = cr_polarShape(st * 1.5, 4); }
    else if (SHAPE == 6) { d = cr_polarShape(float2(st.x, st.y + 0.05) * 1.5, 3); }
    return d * scaleArg;
}

float cr_smin(float a, float b, float k)
{
    if (k == 0.0) { return min(a, b); }
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

float cr_cells(float2 st_in, float freq, float cellSize)
{
    float2 st = st_in * freq;
    // GLSL: st += prng(vec3(float(seed))).xy  — seed splatted to (seed,seed,seed).
    st += cr_prng(float3((float)seed, (float)seed, (float)seed)).xy;
    float2 i = floor(st);
    float2 f = frac(st);
    float d = 1.0;
    [unroll]
    for (int y = -2; y <= 2; y++)
    {
        [unroll]
        for (int x = -2; x <= 2; x++)
        {
            float2 n = float2((float)x, (float)y);
            float2 wrap_coord = i + n;
            float2 cellPoint = cr_prng(float3(wrap_coord, (float)seed)).xy;
            float3 r1 = cr_prng(float3((float)seed, wrap_coord)) * 0.5 - 0.25;
            float3 r2 = cr_prng(float3(wrap_coord, (float)seed)) * 2.0 - 1.0;
            float spd = floor(speed);
            cellPoint += float2(sin(time * CR_TAU * spd + r2.x) * r1.x, cos(time * CR_TAU * spd + r2.y) * r1.y);
            float2 diff = n + cellPoint - f;
            float dist;
            [branch]
            if (SHAPE == 1)
            {
                dist = (abs(n.x + cellPoint.x - f.x) + abs(n.y + cellPoint.y - f.y)) * cellSize;
            }
            else
            {
                dist = cr_shapeFn(float2(diff.x, -diff.y), float2(0.0, 0.0), cellSize);
            }
            dist += r1.z * (variation * 0.01);
            d = cr_smin(d, dist, cellSmooth * 0.01);
        }
    }
    return d;
}

float3 cr_posterize(float3 color, float levIn)
{
    float lev = levIn;
    if (lev == 0.0) { return color; }
    else if (lev == 1.0) { lev = 2.0; }
    float3 c = clamp(color, float3(0.0, 0.0, 0.0), float3(0.99, 0.99, 0.99));
    return (floor(c * lev) + 0.5) / lev;
}

float3 cr_pixellate(float2 uv, float size, float2 texSize)
{
    if (size <= 1.0) { return inputTex.Sample(sampler_inputTex, uv).rgb; }
    float dx = size / texSize.x;
    float dy = size / texSize.y;
    float2 coord = float2(dx * floor(uv.x / dx), dy * floor(uv.y / dy));
    return inputTex.Sample(sampler_inputTex, coord).rgb;
}

// ---- Pass: "cellRefract" -----------------------------------------------------
float4 NMFrag_cellRefract(NMVaryings i) : SV_Target
{
    uint tw, th;
    inputTex.GetDimensions(tw, th);
    float2 texSize = float2((float)tw, (float)th);

    // WGSL: st = position.xy / u.resolution. GLSL adds tileOffset and divides by
    // fullResolution. Identical untiled; use the tiling-aware GLSL form.
    float2 globalCoord = NM_GlobalCoord(i);
    float2 st = globalCoord / fullResolution;

    float freq = cr_map(scale, 1.0, 100.0, 20.0, 1.0);
    float cellSize = cr_map(cellScale, 1.0, 100.0, 3.0, 0.75);
    float d = cr_cells(st * float2(aspectRatio, 1.0), freq, cellSize);
    float refAmt = cr_map(refractAmt, 0.0, 100.0, 0.0, 0.125);
    float refLen = d + direction / 360.0;
    st.x += cos(refLen * CR_TAU) * refAmt;
    st.y += sin(refLen * CR_TAU) * refAmt;

    if (wrap == 1)
    {
        st = frac(st);
    }

    // Convert warped global UV to tile-local UV (GLSL form; identity untiled).
    float2 localUV = (st * fullResolution - tileOffset) / texSize;
    float4 color = inputTex.Sample(sampler_inputTex, localUV);

    float ew = effectWidth;
    [branch]
    if (ew != 0.0 && KERNEL != 0)
    {
        if (KERNEL == 100)
        {
            color = float4(cr_pixellate(localUV, ew * 4.0, texSize), color.a);
        }
        else if (KERNEL == 110)
        {
            color = float4(cr_posterize(color.rgb, floor(cr_map(ew, 0.0, 10.0, 0.0, 20.0))), color.a);
        }
        else
        {
            color = float4(cr_convolutionKernel(color.rgb, localUV, texSize), color.a);
        }
    }

    return color;
}

#endif // NM_EFFECT_CELLREFRACT_INCLUDED
