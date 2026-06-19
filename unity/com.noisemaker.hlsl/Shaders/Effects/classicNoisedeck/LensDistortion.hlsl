#ifndef NM_EFFECT_LENSDISTORTION_INCLUDED
#define NM_EFFECT_LENSDISTORTION_INCLUDED

// =============================================================================
// LensDistortion.hlsl — classicNoisedeck/lensDistortion (func: "lensDistortion")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/classicNoisedeck/lensDistortion/wgsl/lensDistortion.wgsl
//
// Lens distortion (barrel/pincushion) with chromatic/prismatic aberration,
// per-shape distance metric, animated looping, tint-reflect, and vignette.
// Single render pass: "lensDistortion" / progName "lensDistortion".
//
// PORTING-GUIDE notes:
//  * filter: samples inputTex. UV = fragCoord / resolution (WGSL u.resolution).
//    In WGSL the sampler is "samp" and the texture is "inputTex".
//  * The WGSL uses `u.resolution` (= the render target size) for both UV
//    derivation and the internal aspect ratio inside _distance().
//    Here we use `resolution` (the NMFullscreen alias = _NM_Resolution.xy).
//    GetDimensions is NOT used — all coords follow resolution exactly.
//  * nm_mod not fmod. Used for WGSL `% 6.0 / 6.0` inside rgb2hsv and for
//    the hexagon distance `% 2.0`.
//  * WGSL select(b,a,cond) reversed — all ternaries copied as c?a:b.
//  * hsv2rgb, rgb2hsv, saturateColor, _distance, mapVal all per-effect
//    (different from any sibling effect). Copied verbatim.
//  * `aspectLens`, `modulate` are boolean uniforms declared int, tested !=0.
//  * loopScale, speed, mode, shape, blendMode are int or float uniforms.
//  * The tint "reflect" formula: tint*tint / (1 - color). Guard: all(color==1)
//    passes color through unchanged.
//  * Vignette uses `uv` = fragCoord/resolution (same as the sample UV).
//  * Full 32-bit float. No half/min16float.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (WGSL binding 0: samp, binding 1: inputTex) ----
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
int   shape;         // default 0  (circle=0, cosine=10, diamond=1, hexagon=2, octagon=3, square=4, triangle=6)
float distortion;    // default 0   [-100, 100]
int   aspectLens;    // default 0   (boolean: 0 or 1)
float loopScale;     // default 100 [1, 100]
float speed;         // default 0   [-100, 100]
int   mode;          // default 0   (chromaticRgb=0, prismaticHsv=1)
float aberration;    // default 50  [0, 100]
int   blendMode;     // default 0   (add=0, alpha=1)
int   modulate;      // default 0   (boolean: 0 or 1)
float4 tint;         // default (0,0,0,0) — rgb used, alpha unused  [color]
float alpha;         // default 0   [0, 100]  (tint opacity)
float hueRotation;   // default 0   [0, 360]
float hueRange;      // default 0   [0, 100]
float saturation;    // default 0   [-100, 100]
float passthru;      // default 50  [0, 100]
float vignetteAmt;   // default 0   [-100, 100]

// ---- Constants ---------------------------------------------------------------

// ---- Helpers (verbatim from WGSL, per-effect) --------------------------------

// mapVal: linear remap
float mapVal(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

// hsv2rgb — per-effect version from lensDistortion.wgsl
float3 nm_ld_hsv2rgb(float3 hsv)
{
    float h = frac(hsv.x);
    float s = hsv.y;
    float v = hsv.z;

    float c = v * s;
    float x = c * (1.0 - abs(nm_mod(h * 6.0, 2.0) - 1.0));
    float m = v - c;

    float3 rgb;
    if      (h < 1.0/6.0) { rgb = float3(c, x, 0.0); }
    else if (h < 2.0/6.0) { rgb = float3(x, c, 0.0); }
    else if (h < 3.0/6.0) { rgb = float3(0.0, c, x); }
    else if (h < 4.0/6.0) { rgb = float3(0.0, x, c); }
    else if (h < 5.0/6.0) { rgb = float3(x, 0.0, c); }
    else                   { rgb = float3(c, 0.0, x); }

    return rgb + float3(m, m, m);
}

// rgb2hsv — per-effect version from lensDistortion.wgsl
float3 nm_ld_rgb2hsv(float3 rgb)
{
    float r = rgb.r;
    float g = rgb.g;
    float b = rgb.b;

    float maxC = max(r, max(g, b));
    float minC = min(r, min(g, b));
    float delta = maxC - minC;

    float h = 0.0;
    if (delta != 0.0)
    {
        if      (maxC == r) { h = nm_mod((g - b) / delta, 6.0) / 6.0; }
        else if (maxC == g) { h = ((b - r) / delta + 2.0) / 6.0; }
        else                { h = ((r - g) / delta + 4.0) / 6.0; }
    }
    if (h < 0.0) { h = h + 1.0; }

    float s = 0.0;
    if (maxC != 0.0) { s = delta / maxC; }
    float v = maxC;

    return float3(h, s, v);
}

// saturateColor — per-effect version from lensDistortion.wgsl
float3 nm_ld_saturateColor(float3 color)
{
    float sat = mapVal(saturation, -100.0, 100.0, -1.0, 1.0);
    float avg = (color.r + color.g + color.b) / 3.0;
    return color - (avg - color) * sat;
}

// _distance — per-effect shape distance + animation, verbatim from WGSL
// NOTE: uses `resolution` (= _NM_Resolution.xy) matching WGSL u.resolution
float nm_ld_distance(float2 diff, float2 uv)
{
    float ar = resolution.x / resolution.y;   // WGSL: u.resolution.x / u.resolution.y
    float uvx = uv.x * ar;
    float dist = 1.0;

    [branch]
    if (shape == 0)
    {
        // Euclidean
        dist = length(diff);
    }
    else if (shape == 1)
    {
        // Manhattan
        dist = abs(uvx - 0.5 * ar) + abs(uv.y - 0.5);
    }
    else if (shape == 2)
    {
        // hexagon
        dist = max(max(abs(diff.x) - diff.y * -0.5, -1.0 * diff.y), max(abs(diff.x) - diff.y * 0.5, 1.0 * diff.y));
    }
    else if (shape == 3)
    {
        // octagon
        dist = max((abs(uvx - 0.5 * ar) + abs(uv.y - 0.5)) / sqrt(2.0), max(abs(uvx - 0.5 * ar), abs(uv.y - 0.5)));
    }
    else if (shape == 4)
    {
        // Chebychev
        dist = max(abs(uvx - 0.5 * ar), abs(uv.y - 0.5));
    }
    else if (shape == 6)
    {
        // Triangle
        dist = max(abs(diff.x) - diff.y * -0.5, -1.0 * diff.y);
    }
    else if (shape == 10)
    {
        // Cosine
        dist = 1.0 - length(float2((cos(diff.x * NM_TAU) + 1.0) * 0.5, (cos(diff.y * NM_TAU) + 1.0) * 0.5));
    }

    float lf = mapVal(loopScale, 1.0, 100.0, 6.0, 1.0);

    float t = 1.0;
    if (speed < 0.0)
    {
        t = dist * lf + time;
    }
    else
    {
        t = dist * lf - time;
    }
    return lerp(dist,
                (sin(t * NM_TAU) + 1.0 * 0.5) * abs(speed) * 0.005,
                abs(speed) * 0.01);
}

// =============================================================================
// NMFrag_lensDistortion — single-pass fragment entry (progName "lensDistortion")
//
// WGSL main() ported verbatim. `uv` = fragCoord.xy / u.resolution (which is
// the render-target resolution, available as `resolution` from NMFullscreen).
// =============================================================================
float4 NMFrag_lensDistortion(NMVaryings i) : SV_Target
{
    float ar = resolution.x / resolution.y;
    float2 uv = NM_FragCoord(i) / resolution;  // WGSL: fragCoord.xy / u.resolution

    float4 color = float4(0.0, 0.0, 0.0, 1.0);

    float2 diff = float2(0.5, 0.5) - uv;
    [branch]
    if (aspectLens != 0)
    {
        diff = float2(0.5 * ar, 0.5) - float2(uv.x * ar, uv.y);
    }
    float centerDist = nm_ld_distance(diff, uv);

    float distort = 0.0;
    float zoom    = 1.0;
    if (distortion < 0.0)
    {
        distort = mapVal(distortion, -100.0, 0.0, -2.0, 0.0);
        zoom    = mapVal(distortion, -100.0, 0.0, 0.04, 0.0);
    }
    else
    {
        distort = mapVal(distortion, 0.0, 100.0, 0.0, 2.0);
        zoom    = mapVal(distortion, 0.0, 100.0, 0.0, -1.0);
    }

    // aberration and lensing
    float2 lensedCoords = frac((uv - diff * zoom) - diff * centerDist * centerDist * distort);

    float aberrationOffset = mapVal(aberration, 0.0, 100.0, 0.0, 0.05) * centerDist * NM_PI * 0.5;

    float redOffset  = lerp(clamp(lensedCoords.x + aberrationOffset, 0.0, 1.0), lensedCoords.x, lensedCoords.x);
    float4 red   = inputTex.Sample(sampler_inputTex, float2(redOffset, lensedCoords.y));

    float4 green = inputTex.Sample(sampler_inputTex, lensedCoords);

    float blueOffset = lerp(lensedCoords.x, clamp(lensedCoords.x - aberrationOffset, 0.0, 1.0), lensedCoords.x);
    float4 blue  = inputTex.Sample(sampler_inputTex, float2(blueOffset, lensedCoords.y));

    // from aberration
    float3 hsv = float3(1.0, 1.0, 1.0);

    float t = 0.0;
    [branch]
    if (modulate != 0)
    {
        t = time;
    }

    [branch]
    if (mode == 0)
    {
        // chromatic
        color = float4(red.r, green.g, blue.b, color.a) - green;
        color = float4(color.rgb, green.a);

        // tweak hue of edges
        hsv = nm_ld_rgb2hsv(color.rgb);
        hsv = float3(frac(hsv.x + (1.0 - (hueRotation / 360.0)) + hsv.x * hueRange * 0.01 + t), 1.0, hsv.z);
    }
    else
    {
        // prismatic
        // get edges
        float prismEdge = length(float4(red.r, green.g, blue.b, color.a) - green);
        color = float4(float3(prismEdge, prismEdge, prismEdge) * green.rgb, green.a);

        // boost hue range of edges
        hsv = nm_ld_rgb2hsv(color.rgb);
        hsv = float3(frac(((hsv.x + 0.125 + (1.0 - (hueRotation / 360.0))) * (2.0 + hueRange * 0.05)) + t), 1.0, hsv.z);
    }

    // desaturate original
    float3 greenMod = nm_ld_saturateColor(green.rgb) * mapVal(passthru, 0.0, 100.0, 0.0, 2.0);

    // recombine
    [branch]
    if (blendMode == 0)
    {
        // add
        color = float4(min(greenMod + nm_ld_hsv2rgb(hsv), float3(1.0, 1.0, 1.0)), color.a);
    }
    else if (blendMode == 1)
    {
        // alpha
        color = float4(min(max(greenMod - float3(hsv.z, hsv.z, hsv.z), float3(0.0, 0.0, 0.0)) + nm_ld_hsv2rgb(hsv), float3(1.0, 1.0, 1.0)), color.a);
    }
    // end aberration

    // apply tint (reflect mode from blendo)
    float3 tintResult;
    if (all(color.rgb == float3(1.0, 1.0, 1.0)))
    {
        tintResult = color.rgb;
    }
    else
    {
        tintResult = min(tint.rgb * tint.rgb / (float3(1.0, 1.0, 1.0) - color.rgb), float3(1.0, 1.0, 1.0));
    }
    color = float4(lerp(color.rgb, tintResult, alpha * 0.01), max(color.a, alpha * 0.01));

    // vignette
    [branch]
    if (vignetteAmt < 0.0)
    {
        float vigFactor = 1.0 - pow(length(float2(0.5, 0.5) - uv) * 1.125, 2.0);
        color = float4(
            lerp(color.rgb * vigFactor, color.rgb, mapVal(vignetteAmt, -100.0, 0.0, 0.0, 1.0)),
            max(color.a, length(float2(0.5, 0.5) - uv) * mapVal(vignetteAmt, -100.0, 0.0, 1.0, 0.0))
        );
    }
    else
    {
        float vigFactor = 1.0 - pow(length(float2(0.5, 0.5) - uv) * 1.125, 2.0);
        color = float4(
            lerp(color.rgb, float3(1.0, 1.0, 1.0) - (float3(1.0, 1.0, 1.0) - color.rgb * vigFactor), mapVal(vignetteAmt, 0.0, 100.0, 0.0, 1.0)),
            max(color.a, length(float2(0.5, 0.5) - uv) * mapVal(vignetteAmt, -100.0, 0.0, 1.0, 0.0))
        );
    }

    return color;
}

#endif // NM_EFFECT_LENSDISTORTION_INCLUDED
