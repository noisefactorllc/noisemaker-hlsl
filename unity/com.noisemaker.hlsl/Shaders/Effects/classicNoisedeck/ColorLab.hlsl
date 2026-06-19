#ifndef NM_COLORLAB_INCLUDED
#define NM_COLORLAB_INCLUDED

// =============================================================================
// ColorLab.hlsl — classicNoisedeck/colorLab, ported PIXEL-IDENTICALLY from the
// canonical WGSL: shaders/effects/classicNoisedeck/colorLab/wgsl/colorLab.wgsl
//
// Single-input filter, single render pass (program "colorLab"). Samples inputTex
// and applies posterize, dither, color-mode conversion, hue/sat/bright/contrast
// grading in one pass.
//
// PORTING-GUIDE notes:
//  * Port from WGSL (top-left/D3D); no per-effect Y flip. The WGSL divides the
//    sample uv by `u.resolution` (NOT the input tex dims, NOT fullResolution).
//    The GLSL uses textureSize(inputTex,0); WGSL is canonical -> we use resolution.
//  * WGSL uses fragCoord.xy (NOT globalCoord) for the dither/random/bayer terms.
//    We mirror that exactly with NM_FragCoord(i) (no tileOffset added).
//  * All `%` on floats are GLSL/WGSL `mod` -> nm_mod (NMCore), never fmod (H6).
//  * pcg/prng/random/nm_map/nm_periodicFunction come from NMCore. hsv2rgb /
//    rgb2hsv / posterize / linearToSrgb / srgbToLinear / linear_srgb_from_oklab /
//    pal are this effect's OWN copies — ported VERBATIM inline (golden rule 2).
//  * NOTE: this effect's prng uses vec3f(st,1.0) (z=1.0), and random() passes
//    vec3f(st,1.0) -> nm_random uses z=0.0, so we DO NOT use nm_random here.
//    We port this effect's prng/random verbatim inline to keep the z=1.0 seed.
//  * NOTE: this effect's hsv2rgb is the 6-branch chroma form (DIFFERS from Tint's
//    clamp form) — ported inline. rgb2hsv differs too (mod 6.0 form).
//  * Compile-everything full 32-bit float; sampler bilinear/clamp/linear (H7).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
int    colorMode;       // default 2 (srgbDefault)
int    palette;         // default 46 (unused in shader body; palette LUT index)
int    paletteMode;     // default 0
float3 paletteOffset;   // default (0.83, 0.6, 0.63)
float3 paletteAmp;      // default (0.5, 0.5, 0.5)
float3 paletteFreq;     // default (1, 1, 1)
float3 palettePhase;    // default (0.3, 0.1, 0)
int    cyclePalette;    // default 1 (forward); choices {off:0,forward:1,backward:-1}
float  rotatePalette;   // default 0
int    repeatPalette;   // default 1
float  hueRotation;     // default 0
float  hueRange;        // default 100
float  saturation;      // default 0
int    invert;          // default 0 (boolean)
float  brightness;      // default 0  (WGSL types u.brightness as i32; default 0)
float  contrast;        // default 50 (WGSL types u.contrast  as i32; default 50)
int    levels;          // default 0
int    dither;          // default 0

// ---- Input surface ----------------------------------------------------------
Texture2D    inputTex;
SamplerState sampler_inputTex;

#define COLORLAB_PI  3.14159265359
#define COLORLAB_TAU 6.28318530718

// -----------------------------------------------------------------------------
// prng / random — this effect's OWN copies. WGSL:
//   fn prng(p: vec3f) -> vec3f { return vec3f(pcg3(vec3u(p))) / f32(0xffffffffu); }
//   fn random(st: vec2f) -> f32 { return prng(vec3f(st, 1.0)).x; }
// vec3u(p) is float->uint TRUNCATION (NOT asuint). pcg3 == nm_pcg algorithm.
// NOTE z = 1.0 here, so this is NOT nm_random (which uses z = 0.0).
// -----------------------------------------------------------------------------
float3 colorLab_prng(float3 p)
{
    return float3(nm_pcg((uint3)p)) / 4294967295.0;
}

float colorLab_random(float2 st)
{
    return colorLab_prng(float3(st, 1.0)).x;
}

// -----------------------------------------------------------------------------
// mapVal — WGSL fn mapVal == nm_map. Use nm_map (identical math).
// posterize — VERBATIM from WGSL fn posterize.
// -----------------------------------------------------------------------------
float3 colorLab_posterize(float3 color, float lev)
{
    if (lev == 0.0) {
        return color;
    }
    float lvl = lev;
    if (lvl == 1.0) {
        lvl = 2.0;
    }
    float gamma = 0.65;
    float3 c = pow(color, float3(gamma, gamma, gamma));
    c = floor(c * lvl) / lvl;
    c = pow(c, float3(1.0 / gamma, 1.0 / gamma, 1.0 / gamma));
    return c;
}

// brightnessContrast — VERBATIM from WGSL. u.brightness/u.contrast are i32 there;
// cast our float uniforms with f32(...) equivalently (value-identical for ints).
float3 colorLab_brightnessContrast(float3 color)
{
    float bright = nm_map(brightness, -100.0, 100.0, -1.0, 1.0);
    float cont   = nm_map(contrast, 0.0, 100.0, 0.0, 2.0);
    return (color - 0.5) * cont + 0.5 + bright;
}

// saturateColor — VERBATIM from WGSL fn saturateColor.
float3 colorLab_saturateColor(float3 color)
{
    float sat = nm_map(saturation, -100.0, 100.0, -1.0, 1.0);
    float avg = (color.r + color.g + color.b) / 3.0;
    return color - (avg - color) * sat;
}

// periodicFunction — VERBATIM from WGSL: map(sin(TAU*p), -1, 1, 0, 1).
// NOTE this is sin-based; NMCore nm_periodicFunction is cos-based -> use inline.
float colorLab_periodicFunction(float p)
{
    float x = COLORLAB_TAU * p;
    return nm_map(sin(x), -1.0, 1.0, 0.0, 1.0);
}

// hsv2rgb — VERBATIM from WGSL fn hsv2rgb (6-branch chroma form; uses % 2.0).
float3 colorLab_hsv2rgb(float3 hsv)
{
    float h = frac(hsv.x);
    float s = hsv.y;
    float v = hsv.z;

    float c = v * s;
    float x = c * (1.0 - abs(nm_mod(h * 6.0, 2.0) - 1.0));
    float m = v - c;

    float3 rgb;
    if (h < 1.0/6.0) {
        rgb = float3(c, x, 0.0);
    } else if (h < 2.0/6.0) {
        rgb = float3(x, c, 0.0);
    } else if (h < 3.0/6.0) {
        rgb = float3(0.0, c, x);
    } else if (h < 4.0/6.0) {
        rgb = float3(0.0, x, c);
    } else if (h < 5.0/6.0) {
        rgb = float3(x, 0.0, c);
    } else {
        rgb = float3(c, 0.0, x);
    }

    return rgb + float3(m, m, m);
}

// rgb2hsv — VERBATIM from WGSL fn rgb2hsv (uses % 6.0 only on the max==r branch).
float3 colorLab_rgb2hsv(float3 rgb)
{
    float r = rgb.r;
    float g = rgb.g;
    float b = rgb.b;

    float maxC = max(r, max(g, b));
    float minC = min(r, min(g, b));
    float delta = maxC - minC;

    float h = 0.0;
    if (delta != 0.0) {
        if (maxC == r) {
            h = nm_mod((g - b) / delta, 6.0) / 6.0;
        } else if (maxC == g) {
            h = ((b - r) / delta + 2.0) / 6.0;
        } else {
            h = ((r - g) / delta + 4.0) / 6.0;
        }
    }
    if (h < 0.0) { h = h + 1.0; }

    float s = 0.0;
    if (maxC != 0.0) {
        s = delta / maxC;
    }
    float v = maxC;

    return float3(h, s, v);
}

// linearToSrgb — VERBATIM from WGSL fn linearToSrgb.
float3 colorLab_linearToSrgb(float3 linearC)
{
    float3 srgb;
    if (linearC.r <= 0.0031308) { srgb.r = linearC.r * 12.92; }
    else { srgb.r = 1.055 * pow(linearC.r, 1.0 / 2.4) - 0.055; }
    if (linearC.g <= 0.0031308) { srgb.g = linearC.g * 12.92; }
    else { srgb.g = 1.055 * pow(linearC.g, 1.0 / 2.4) - 0.055; }
    if (linearC.b <= 0.0031308) { srgb.b = linearC.b * 12.92; }
    else { srgb.b = 1.055 * pow(linearC.b, 1.0 / 2.4) - 0.055; }
    return srgb;
}

// srgbToLinear — VERBATIM from WGSL fn srgbToLinear.
float3 colorLab_srgbToLinear(float3 srgb)
{
    float3 linearC;
    if (srgb.r <= 0.04045) { linearC.r = srgb.r / 12.92; }
    else { linearC.r = pow((srgb.r + 0.055) / 1.055, 2.4); }
    if (srgb.g <= 0.04045) { linearC.g = srgb.g / 12.92; }
    else { linearC.g = pow((srgb.g + 0.055) / 1.055, 2.4); }
    if (srgb.b <= 0.04045) { linearC.b = srgb.b / 12.92; }
    else { linearC.b = pow((srgb.b + 0.055) / 1.055, 2.4); }
    return linearC;
}

// linear_srgb_from_oklab — VERBATIM from WGSL. WGSL mat3x3f is COLUMN-major:
//   mat3x3f(c0x,c0y,c0z, c1x,c1y,c1z, c2x,c2y,c2z); product fwdA * c uses columns.
// In HLSL we replicate the exact (lms = fwdA*c, return fwdB*(lms^3)) arithmetic by
// expanding the column-vector dot products literally so associativity matches.
float3 colorLab_linear_srgb_from_oklab(float3 c)
{
    // fwdA columns (WGSL row-listing is column-major):
    //   col0 = (1.0, 1.0, 1.0)
    //   col1 = (0.3963377774, -0.1055613458, -0.0894841775)
    //   col2 = (0.2158037573, -0.0638541728, -1.2914855480)
    // lms = col0*c.x + col1*c.y + col2*c.z
    float3 lms;
    lms.x = 1.0 * c.x + 0.3963377774 * c.y + 0.2158037573 * c.z;
    lms.y = 1.0 * c.x + -0.1055613458 * c.y + -0.0638541728 * c.z;
    lms.z = 1.0 * c.x + -0.0894841775 * c.y + -1.2914855480 * c.z;

    float3 lms3 = lms * lms * lms;

    // fwdB columns:
    //   col0 = (4.0767245293, -1.2681437731, -0.0041119885)
    //   col1 = (-3.3072168827, 2.6093323231, -0.7034763098)
    //   col2 = (0.2307590544, -0.3411344290, 1.7068625689)
    float3 outc;
    outc.x = 4.0767245293 * lms3.x + -3.3072168827 * lms3.y + 0.2307590544 * lms3.z;
    outc.y = -1.2681437731 * lms3.x + 2.6093323231 * lms3.y + -0.3411344290 * lms3.z;
    outc.z = -0.0041119885 * lms3.x + -0.7034763098 * lms3.y + 1.7068625689 * lms3.z;
    return outc;
}

// pal — VERBATIM from WGSL fn pal. NOTE f32(u.repeatPalette) (int->float).
float3 colorLab_pal(float t_in)
{
    float3 a = paletteOffset;
    float3 b = paletteAmp;
    float3 c = paletteFreq;
    float3 d = palettePhase;

    float t = t_in * (float)repeatPalette + rotatePalette * 0.01;
    float3 color = a + b * cos(6.28318 * (c * t + d));

    if (paletteMode == 1) {
        color = colorLab_hsv2rgb(color);
    } else if (paletteMode == 2) {
        color.y = color.y * -0.509 + 0.276;
        color.z = color.z * -0.509 + 0.198;
        color = colorLab_linear_srgb_from_oklab(color);
        color = colorLab_linearToSrgb(color);
    }

    return color;
}

// -----------------------------------------------------------------------------
// nm_colorLab — core per-pixel evaluation. Ported VERBATIM from WGSL fn main().
// `color` is the already-sampled input RGBA; `fragCoord` is the WGSL
// @builtin(position).xy analog (NM_FragCoord(i)).
// -----------------------------------------------------------------------------
float4 nm_colorLab(float4 color, float2 fragCoord)
{
    if ((float)levels != 0.0) {
        color = float4(colorLab_posterize(color.rgb, (float)levels), color.a);
    }

    float bright = colorLab_rgb2hsv(color.rgb).b;

    if (dither == 1) {
        color = float4(color.rgb * float3(step(0.5, bright), step(0.5, bright), step(0.5, bright)), color.a);
    } else if (dither == 2) {
        float s = step(colorLab_random(fragCoord.xy), bright);
        color = float4(color.rgb * float3(s, s, s), color.a);
    } else if (dither == 3) {
        float s = step(colorLab_periodicFunction(colorLab_random(fragCoord.xy) + time), bright);
        color = float4(color.rgb * float3(s, s, s), color.a);
    } else if (dither == 4) {
        float2 coord = nm_mod(fragCoord.xy, float2(4.0, 4.0)) - 0.5;
        if (bright < 0.12) {
            color = float4(float3(0.0, 0.0, 0.0), color.a);
        } else if (bright < 0.24) {
            if (coord.x == 1.0 && coord.y == 1.0) { } else { color = float4(float3(0.0, 0.0, 0.0), color.a); }
        } else if (bright < 0.36) {
            if ((coord.x == 1.0 && coord.y == 1.0) || (coord.x == 3.0 && coord.y == 3.0)) { } else { color = float4(float3(0.0, 0.0, 0.0), color.a); }
        } else if (bright < 0.48) {
            if ((coord.x == 1.0 || coord.x == 3.0) && (coord.y == 1.0 || coord.y == 3.0)) { } else { color = float4(float3(0.0, 0.0, 0.0), color.a); }
        } else if (bright < 0.60) {
            if ((coord.x == 1.0 || coord.x == 3.0) && (coord.y == 1.0 || coord.y == 3.0)) { color = float4(float3(0.0, 0.0, 0.0), color.a); }
        } else if (bright < 0.72) {
            if ((coord.x == 1.0 && coord.y == 1.0) || (coord.x == 3.0 && coord.y == 3.0)) { color = float4(float3(0.0, 0.0, 0.0), color.a); }
        } else if (bright < 0.84) {
            if (coord.x == 1.0 && coord.y == 1.0) { color = float4(float3(0.0, 0.0, 0.0), color.a); }
        }
    }

    // color mode
    if (colorMode == 0) {
        float g = colorLab_rgb2hsv(color.rgb).b;
        color = float4(float3(g, g, g), color.a);
    } else if (colorMode == 1) {
        color = float4(colorLab_srgbToLinear(color.rgb), color.a);
    } else if (colorMode == 3) {
        float3 c = color.rgb;
        c.g = c.g * -0.509 + 0.276;
        c.b = c.b * -0.509 + 0.198;
        c = colorLab_linear_srgb_from_oklab(c);
        c = colorLab_linearToSrgb(c);
        color = float4(c, color.a);
    } else if (colorMode == 4) {
        float d = colorLab_rgb2hsv(color.rgb).b;
        if (cyclePalette == -1) {
            d += time;
        } else if (cyclePalette == 1) {
            d -= time;
        }
        color = float4(colorLab_pal(d), color.a);
    }

    float3 hsv = colorLab_rgb2hsv(color.rgb);
    hsv.x = nm_mod(hsv.x * nm_map(hueRange, 0.0, 200.0, 0.0, 2.0) + (hueRotation / 360.0), 1.0);
    color = float4(colorLab_hsv2rgb(hsv), color.a);

    if (invert != 0) {
        color = float4(float3(1.0, 1.0, 1.0) - color.rgb, color.a);
    }

    color = float4(colorLab_brightnessContrast(color.rgb), color.a);
    color = float4(colorLab_saturateColor(color.rgb), color.a);

    return color;
}

#endif // NM_COLORLAB_INCLUDED
