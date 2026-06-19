#ifndef NM_DITHER_INCLUDED
#define NM_DITHER_INCLUDED

// =============================================================================
// Dither.hlsl — filter/dither, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/dither/wgsl/dither.wgsl
//
// Ordered dithering with classic patterns (Bayer 2x2/4x4/8x8, dot, line,
// crosshatch, noise) and retro color palettes (monochrome, Game Boy green,
// amber monitor, PICO-8, C64, CGA, ZX Spectrum, Apple II, EGA), plus a
// per-channel quantization mode driven by `levels`. Single render pass.
//
// PORTING-GUIDE notes:
//  * Single render pass (definition.js passes[].length == 1, program "dither").
//  * Port from WGSL, not GLSL (golden rule 1). The WGSL feeds the RAW frag coord
//    `pos.xy` (NOT globalCoord = pos+tileOffset, and NOT matrixScale*renderScale)
//    into getDitherThreshold. We mirror the WGSL: NM_FragCoord(i) and bare
//    `matrixScale`. (The GLSL's tileOffset/renderScale tiling reconciliation is a
//    backend-side concern; WGSL is canonical for the math.)
//  * Sample uv = fragCoord / the INPUT TEXTURE's own dimensions (WGSL line 366-367:
//    texSize = textureDimensions(inputTex); uv = pos.xy / texSize). Mirrored with
//    inputTex.GetDimensions, divided into NM_FragCoord(i). No flip (top-left UV).
//  * matrixScale: WGSL Uniforms types it `matrixScale: f32` (so getDitherThreshold
//    receives an f32 `scale`). definition.js types the param `int` (default 2).
//    We declare a `float matrixScale` uniform — the runtime feeds the int value as
//    a float, matching the WGSL's f32 path exactly (floor(pixelCoord/scale)).
//  * ditherType / palette / levels are `int` uniforms ([branch] over the WGSL
//    if/else chains). Compile-time `const` enum values inlined as literals below.
//  * `hash()` (noise dither) is `pcg(...).x / 0xffffffff` after sign-folding p.x,p.y
//    with z=0 — identical to NMCore nm_random(p) (= nm_prng(float3(p,0)).x). Use
//    nm_random (the ONE shared primitive; NMCore pcg/prng/random). Divisor is
//    4294967295.0 (H11) inside nm_prng — exact.
//  * Bayer 2x2/4x4 use array lookups (WGSL getBayer2x2/getBayer4x4 with arrays);
//    Bayer 8x8 uses a 64-entry array lookup. Ported verbatim. `(y & N)*M + (x & N)`
//    indexing copied literally; HLSL `&` on int is the same bitwise op.
//  * colorDistance / palette getters / findClosestPaletteColor / quantizeWithDither
//    / ditherWithPalette are this effect's OWN copies — ported VERBATIM inline,
//    NOT hoisted to a shared lib (golden rule 2).
//  * Final: result = lerp(color.rgb, result, mixAmount); alpha passed through.
//  * Linear, clamp-to-edge, non-sRGB sampler (H7) on the SamplerState in the shader.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
int   ditherType;   // globals.type.uniform "ditherType", default 1 (bayer4x4)
float matrixScale;  // globals.matrixScale.uniform "matrixScale", default 2 (WGSL f32 scale)
float threshold;    // globals.threshold.uniform "threshold", default 0.0
int   palette;      // globals.palette.uniform "palette", default 0 (input)
int   levels;       // globals.levels.uniform "levels", default 4
float mixAmount;    // globals.mix.uniform "mixAmount", default 1.0
// `time` (WGSL uniforms.time) supplied by NMFullscreen as the engine global `time`.

// Dither type constants (WGSL const)
#define DITHER_BAYER_2X2 0
#define DITHER_BAYER_4X4 1
#define DITHER_BAYER_8X8 2
#define DITHER_DOT 3
#define DITHER_LINE 4
#define DITHER_CROSSHATCH 5
#define DITHER_NOISE 6

// Palette constants (WGSL const)
#define PALETTE_INPUT 0
#define PALETTE_MONOCHROME 1
#define PALETTE_DOT_MATRIX_GREEN 2
#define PALETTE_AMBER 3
#define PALETTE_PICO8 4
#define PALETTE_C64 5
#define PALETTE_CGA 6
#define PALETTE_ZX_SPECTRUM 7
#define PALETTE_APPLE_II 8
#define PALETTE_EGA 9

// -----------------------------------------------------------------------------
// getBayer2x2 — VERBATIM from dither.wgsl. Array of 4, idx = (y&1)*2 + (x&1).
// -----------------------------------------------------------------------------
float getBayer2x2(int x, int y)
{
    float bayer[4] = {
        0.0/4.0, 2.0/4.0,
        3.0/4.0, 1.0/4.0
    };
    int idx = (y & 1) * 2 + (x & 1);
    return bayer[idx];
}

// -----------------------------------------------------------------------------
// getBayer4x4 — VERBATIM from dither.wgsl. Array of 16, idx = (y&3)*4 + (x&3).
// -----------------------------------------------------------------------------
float getBayer4x4(int x, int y)
{
    float bayer[16] = {
         0.0/16.0,  8.0/16.0,  2.0/16.0, 10.0/16.0,
        12.0/16.0,  4.0/16.0, 14.0/16.0,  6.0/16.0,
         3.0/16.0, 11.0/16.0,  1.0/16.0,  9.0/16.0,
        15.0/16.0,  7.0/16.0, 13.0/16.0,  5.0/16.0
    };
    int idx = (y & 3) * 4 + (x & 3);
    return bayer[idx];
}

// -----------------------------------------------------------------------------
// getBayer8x8 — VERBATIM from dither.wgsl. xm = x&7, ym = y&7, idx = ym*8 + xm.
// -----------------------------------------------------------------------------
float getBayer8x8(int x, int y)
{
    int xm = x & 7;
    int ym = y & 7;

    float bayer8[64] = {
         0.0/64.0, 32.0/64.0,  8.0/64.0, 40.0/64.0,  2.0/64.0, 34.0/64.0, 10.0/64.0, 42.0/64.0,
        48.0/64.0, 16.0/64.0, 56.0/64.0, 24.0/64.0, 50.0/64.0, 18.0/64.0, 58.0/64.0, 26.0/64.0,
        12.0/64.0, 44.0/64.0,  4.0/64.0, 36.0/64.0, 14.0/64.0, 46.0/64.0,  6.0/64.0, 38.0/64.0,
        60.0/64.0, 28.0/64.0, 52.0/64.0, 20.0/64.0, 62.0/64.0, 30.0/64.0, 54.0/64.0, 22.0/64.0,
         3.0/64.0, 35.0/64.0, 11.0/64.0, 43.0/64.0,  1.0/64.0, 33.0/64.0,  9.0/64.0, 41.0/64.0,
        51.0/64.0, 19.0/64.0, 59.0/64.0, 27.0/64.0, 49.0/64.0, 17.0/64.0, 57.0/64.0, 25.0/64.0,
        15.0/64.0, 47.0/64.0,  7.0/64.0, 39.0/64.0, 13.0/64.0, 45.0/64.0,  5.0/64.0, 37.0/64.0,
        63.0/64.0, 31.0/64.0, 55.0/64.0, 23.0/64.0, 61.0/64.0, 29.0/64.0, 53.0/64.0, 21.0/64.0
    };

    return bayer8[ym * 8 + xm];
}

// -----------------------------------------------------------------------------
// hash — VERBATIM from dither.wgsl: pcg over sign-folded p.x,p.y with z=0,
// returning f32(v.x)/f32(0xffffffffu). This is exactly NMCore nm_random(p)
// (= nm_prng(float3(p,0)).x): same sign-fold, same pcg, same /4294967295.0.
// -----------------------------------------------------------------------------
float hash(float2 p)
{
    return nm_random(p);
}

// -----------------------------------------------------------------------------
// dotPattern — VERBATIM from dither.wgsl. (The GLSL computes an unused `c`; WGSL
// omits it — we follow WGSL.)
// -----------------------------------------------------------------------------
float dotPattern(float2 uv, float scale)
{
    float2 p = uv * scale;
    float d = length(frac(p) - 0.5);
    return smoothstep(0.5, 0.0, d);
}

// -----------------------------------------------------------------------------
// linePattern — VERBATIM from dither.wgsl.
// -----------------------------------------------------------------------------
float linePattern(float2 uv, float scale)
{
    float p = uv.y * scale;
    return abs(frac(p) - 0.5) * 2.0;
}

// -----------------------------------------------------------------------------
// crosshatchPattern — VERBATIM from dither.wgsl.
// -----------------------------------------------------------------------------
float crosshatchPattern(float2 uv, float scale)
{
    float2 p = uv * scale;
    float line1 = abs(frac(p.x + p.y) - 0.5) * 2.0;
    float line2 = abs(frac(p.x - p.y) - 0.5) * 2.0;
    return min(line1, line2);
}

// -----------------------------------------------------------------------------
// getDitherThreshold — VERBATIM from dither.wgsl. scaledCoord = floor(pixelCoord/
// scale); pattern scales use 1.0/(8.0*scale); noise uses hash(scaledCoord + time*0.001).
// -----------------------------------------------------------------------------
float getDitherThreshold(float2 pixelCoord, int ditherTypeArg, float scale, float timeArg)
{
    float2 scaledCoord = floor(pixelCoord / scale);
    int x = (int)scaledCoord.x;
    int y = (int)scaledCoord.y;

    [branch]
    if (ditherTypeArg == DITHER_BAYER_2X2) {
        return getBayer2x2(x, y);
    } else if (ditherTypeArg == DITHER_BAYER_4X4) {
        return getBayer4x4(x, y);
    } else if (ditherTypeArg == DITHER_BAYER_8X8) {
        return getBayer8x8(x, y);
    } else if (ditherTypeArg == DITHER_DOT) {
        return dotPattern(pixelCoord, 1.0 / (8.0 * scale));
    } else if (ditherTypeArg == DITHER_LINE) {
        return linePattern(pixelCoord, 1.0 / (8.0 * scale));
    } else if (ditherTypeArg == DITHER_CROSSHATCH) {
        return crosshatchPattern(pixelCoord, 1.0 / (8.0 * scale));
    } else if (ditherTypeArg == DITHER_NOISE) {
        return hash(scaledCoord + timeArg * 0.001);
    }

    return 0.5;
}

// -----------------------------------------------------------------------------
// quantizeWithDither — VERBATIM from dither.wgsl.
// -----------------------------------------------------------------------------
float3 quantizeWithDither(float3 color, float levelsArg, float ditherValue, float thresh)
{
    float adjustedDither = ditherValue - 0.5 + thresh;
    float3 dithered = color + adjustedDither / levelsArg;
    return floor(dithered * levelsArg) / (levelsArg - 1.0);
}

// -----------------------------------------------------------------------------
// colorDistance — VERBATIM from dither.wgsl (this effect's own copy).
// -----------------------------------------------------------------------------
float colorDistance(float3 a, float3 b)
{
    float3 diff = a - b;
    return dot(diff, diff);
}

// ---- Palette color getters — VERBATIM from dither.wgsl switch tables ----------
float3 getDotMatrixGreen(int i)
{
    switch (i) {
        case 0: return float3(0.06, 0.22, 0.06);
        case 1: return float3(0.19, 0.38, 0.19);
        case 2: return float3(0.55, 0.67, 0.06);
        default: return float3(0.61, 0.74, 0.06);
    }
}

float3 getAmber(int i)
{
    switch (i) {
        case 0: return float3(0.0, 0.0, 0.0);
        case 1: return float3(0.4, 0.2, 0.0);
        case 2: return float3(0.8, 0.4, 0.0);
        default: return float3(1.0, 0.6, 0.0);
    }
}

float3 getCGA(int i)
{
    switch (i) {
        case 0: return float3(0.0, 0.0, 0.0);
        case 1: return float3(0.0, 1.0, 1.0);
        case 2: return float3(1.0, 0.0, 1.0);
        default: return float3(1.0, 1.0, 1.0);
    }
}

float3 getPico8(int i)
{
    switch (i) {
        case 0: return float3(0.0, 0.0, 0.0);
        case 1: return float3(0.114, 0.169, 0.325);
        case 2: return float3(0.494, 0.145, 0.325);
        case 3: return float3(0.0, 0.529, 0.318);
        case 4: return float3(0.671, 0.322, 0.212);
        case 5: return float3(0.373, 0.341, 0.310);
        case 6: return float3(0.761, 0.765, 0.780);
        case 7: return float3(1.0, 0.945, 0.910);
        case 8: return float3(1.0, 0.0, 0.302);
        case 9: return float3(1.0, 0.639, 0.0);
        case 10: return float3(1.0, 0.925, 0.153);
        case 11: return float3(0.0, 0.894, 0.212);
        case 12: return float3(0.161, 0.678, 1.0);
        case 13: return float3(0.514, 0.463, 0.612);
        case 14: return float3(1.0, 0.467, 0.659);
        default: return float3(1.0, 0.8, 0.667);
    }
}

float3 getC64(int i)
{
    switch (i) {
        case 0: return float3(0.0, 0.0, 0.0);
        case 1: return float3(1.0, 1.0, 1.0);
        case 2: return float3(0.533, 0.0, 0.0);
        case 3: return float3(0.667, 1.0, 0.933);
        case 4: return float3(0.8, 0.267, 0.8);
        case 5: return float3(0.0, 0.8, 0.333);
        case 6: return float3(0.0, 0.0, 0.667);
        case 7: return float3(0.933, 0.933, 0.467);
        case 8: return float3(0.867, 0.533, 0.333);
        case 9: return float3(0.4, 0.267, 0.0);
        case 10: return float3(1.0, 0.467, 0.467);
        case 11: return float3(0.2, 0.2, 0.2);
        case 12: return float3(0.467, 0.467, 0.467);
        case 13: return float3(0.667, 1.0, 0.4);
        case 14: return float3(0.0, 0.533, 1.0);
        default: return float3(0.6, 0.6, 0.6);
    }
}

float3 getZXSpectrum(int i)
{
    switch (i) {
        case 0: return float3(0.0, 0.0, 0.0);
        case 1: return float3(0.0, 0.0, 0.839);
        case 2: return float3(0.839, 0.0, 0.0);
        case 3: return float3(0.839, 0.0, 0.839);
        case 4: return float3(0.0, 0.839, 0.0);
        case 5: return float3(0.0, 0.839, 0.839);
        case 6: return float3(0.839, 0.839, 0.0);
        case 7: return float3(0.839, 0.839, 0.839);
        case 8: return float3(0.0, 0.0, 1.0);
        case 9: return float3(1.0, 0.0, 0.0);
        case 10: return float3(1.0, 0.0, 1.0);
        case 11: return float3(0.0, 1.0, 0.0);
        case 12: return float3(0.0, 1.0, 1.0);
        case 13: return float3(1.0, 1.0, 0.0);
        default: return float3(1.0, 1.0, 1.0);
    }
}

float3 getAppleII(int i)
{
    switch (i) {
        case 0: return float3(0.0, 0.0, 0.0);
        case 1: return float3(0.882, 0.0, 0.494);
        case 2: return float3(0.247, 0.0, 0.682);
        case 3: return float3(1.0, 0.0, 1.0);
        case 4: return float3(0.0, 0.494, 0.263);
        case 5: return float3(0.502, 0.502, 0.502);
        case 6: return float3(0.0, 0.325, 1.0);
        case 7: return float3(0.667, 0.671, 1.0);
        case 8: return float3(0.502, 0.302, 0.0);
        case 9: return float3(1.0, 0.467, 0.0);
        case 10: return float3(0.502, 0.502, 0.502);
        case 11: return float3(1.0, 0.616, 0.667);
        case 12: return float3(0.0, 0.831, 0.0);
        case 13: return float3(1.0, 1.0, 0.0);
        case 14: return float3(0.333, 1.0, 0.557);
        default: return float3(1.0, 1.0, 1.0);
    }
}

float3 getEGA(int i)
{
    switch (i) {
        case 0: return float3(0.0, 0.0, 0.0);
        case 1: return float3(0.0, 0.0, 0.667);
        case 2: return float3(0.0, 0.667, 0.0);
        case 3: return float3(0.0, 0.667, 0.667);
        case 4: return float3(0.667, 0.0, 0.0);
        case 5: return float3(0.667, 0.0, 0.667);
        case 6: return float3(0.667, 0.333, 0.0);
        case 7: return float3(0.667, 0.667, 0.667);
        case 8: return float3(0.333, 0.333, 0.333);
        case 9: return float3(0.333, 0.333, 1.0);
        case 10: return float3(0.333, 1.0, 0.333);
        case 11: return float3(0.333, 1.0, 1.0);
        case 12: return float3(1.0, 0.333, 0.333);
        case 13: return float3(1.0, 0.333, 1.0);
        case 14: return float3(1.0, 1.0, 0.333);
        default: return float3(1.0, 1.0, 1.0);
    }
}

// -----------------------------------------------------------------------------
// findClosestPaletteColor — VERBATIM from dither.wgsl. count defaults to 16 with
// overrides (4 for dot-matrix/amber/CGA, 15 for ZX). minDist seed 999999.0.
// -----------------------------------------------------------------------------
float3 findClosestPaletteColor(float3 color, int paletteType)
{
    if (paletteType == PALETTE_MONOCHROME) {
        float luma = dot(color, float3(0.299, 0.587, 0.114));
        if (luma > 0.5) {
            return float3(1.0, 1.0, 1.0);
        } else {
            return float3(0.0, 0.0, 0.0);
        }
    }

    float3 closest = float3(0.0, 0.0, 0.0);
    float minDist = 999999.0;
    int count = 16;

    if (paletteType == PALETTE_DOT_MATRIX_GREEN || paletteType == PALETTE_AMBER || paletteType == PALETTE_CGA) {
        count = 4;
    } else if (paletteType == PALETTE_ZX_SPECTRUM) {
        count = 15;
    }

    for (int i = 0; i < count; i = i + 1) {
        float3 palColor = float3(0.0, 0.0, 0.0);

        if (paletteType == PALETTE_DOT_MATRIX_GREEN) {
            palColor = getDotMatrixGreen(i);
        } else if (paletteType == PALETTE_AMBER) {
            palColor = getAmber(i);
        } else if (paletteType == PALETTE_PICO8) {
            palColor = getPico8(i);
        } else if (paletteType == PALETTE_C64) {
            palColor = getC64(i);
        } else if (paletteType == PALETTE_CGA) {
            palColor = getCGA(i);
        } else if (paletteType == PALETTE_ZX_SPECTRUM) {
            palColor = getZXSpectrum(i);
        } else if (paletteType == PALETTE_APPLE_II) {
            palColor = getAppleII(i);
        } else if (paletteType == PALETTE_EGA) {
            palColor = getEGA(i);
        }

        float dist = colorDistance(color, palColor);
        if (dist < minDist) {
            minDist = dist;
            closest = palColor;
        }
    }

    return closest;
}

// -----------------------------------------------------------------------------
// ditherWithPalette — VERBATIM from dither.wgsl.
// -----------------------------------------------------------------------------
float3 ditherWithPalette(float3 color, float ditherValue, float thresh, int paletteType)
{
    float3 dithered = clamp(color + (ditherValue - 0.5 + thresh) * 0.25, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
    return findClosestPaletteColor(dithered, paletteType);
}

// -----------------------------------------------------------------------------
// nm_dither — core per-pixel evaluation. Takes the already-sampled base color and
// the raw pixel coordinate (NM_FragCoord, WGSL pos.xy) and returns dithered RGBA.
// Ported VERBATIM from dither.wgsl main().
// -----------------------------------------------------------------------------
float4 nm_dither(float4 color, float2 pixelCoord)
{
    float ditherValue = getDitherThreshold(pixelCoord, ditherType, matrixScale, time);

    float3 result;

    if (palette == PALETTE_INPUT) {
        result = quantizeWithDither(color.rgb, (float)levels, ditherValue, threshold);
    } else {
        result = ditherWithPalette(color.rgb, ditherValue, threshold, palette);
    }

    result = lerp(color.rgb, result, mixAmount);

    return float4(result, color.a);
}

#endif // NM_DITHER_INCLUDED
