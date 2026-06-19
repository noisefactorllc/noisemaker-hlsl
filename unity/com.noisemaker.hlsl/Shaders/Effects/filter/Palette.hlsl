#ifndef NM_PALETTE_INCLUDED
#define NM_PALETTE_INCLUDED

// =============================================================================
// Palette.hlsl — filter/palette, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/palette/wgsl/palette.wgsl
//
// Apply cosine color palettes based on luminance. Supports RGB, HSV, and OkLab
// colorspaces (mode flag encoded in palette entry amp.w).
//
// PORTING-GUIDE notes:
//  * Single render pass (definition.js passes[0].program = "palette").
//  * uv = fragCoord / textureDimensions(inputTex) — divided by INPUT tex dims,
//    not fullResolution. Mirror exactly: NM_FragCoord(i) / tex size.
//  * hsv_to_rgb / oklab_to_rgb are this effect's OWN copies — ported VERBATIM
//    inline (PORTING-GUIDE golden rule 2). Do NOT substitute generics.
//  * floorMod is this effect's own helper (mirrors WGSL fn floorMod); uses
//    nm_mod (not fmod) per PORTING-GUIDE translation table.
//  * WGSL select(high, low, linear <= 0.0031308) — reversed! maps to
//    (linear <= 0.0031308) ? low : high  in HLSL.
//  * Palette table: 55 entries, 0-indexed array, 1-indexed public indices.
//    paletteIndex <= 0 || > 55 → passthrough. Declared as static const arrays.
//  * paletteIndex: int uniform. rotation: int uniform (-1/0/1). alpha: float.
//    repeat: float (WGSL uses it as f32 in `lum * repeat`). offset: float.
//  * time engine global is provided by NMFullscreen.hlsl.
//  * Linear, clamp-to-edge, non-sRGB sampler (H7).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
int   paletteIndex;   // globals.index.uniform   "paletteIndex",  default palette.brushedMetal = 7
int   rotation;       // globals.rotation.uniform "rotation",      default 0
float offset;         // globals.offset.uniform   "offset",        default 0
float repeat;         // globals.repeat.uniform   "repeat",        default 1
float alpha;          // globals.alpha.uniform    "alpha",         default 1

// =============================================================================
// Palette data — 55 entries, 0-indexed (palette public index = array index + 1).
// Struct mirrors WGSL PaletteEntry: amp (xyz=amplitude, w=mode 0=rgb/1=hsv/2=oklab),
// freq, offset (renamed palOff to avoid clash with the uniform), phase.
// =============================================================================
struct PaletteEntry {
    float4 amp;
    float4 freq;
    float4 palOff;
    float4 phase;
};

static const PaletteEntry palettes[55] = {
    // 1: seventiesShirt (rgb)
    { float4(0.76, 0.88, 0.37, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.93, 0.97, 0.52, 0.0), float4(0.21, 0.41, 0.56, 0.0) },
    // 2: fiveG (rgb)
    { float4(0.56851584, 0.7740668, 0.23485267, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.5, 0.5, 0.5, 0.0), float4(0.727029, 0.08039695, 0.10427457, 0.0) },
    // 3: afterimage (rgb)
    { float4(0.5, 0.5, 0.5, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.5, 0.5, 0.5, 0.0), float4(0.3, 0.2, 0.2, 0.0) },
    // 4: barstow (rgb)
    { float4(0.45, 0.2, 0.1, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.7, 0.2, 0.2, 0.0), float4(0.5, 0.4, 0.0, 0.0) },
    // 5: bloob (rgb)
    { float4(0.09, 0.59, 0.48, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.2, 0.31, 0.98, 0.0), float4(0.88, 0.4, 0.33, 0.0) },
    // 6: blueSkies (rgb)
    { float4(0.5, 0.5, 0.5, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.1, 0.4, 0.7, 0.0), float4(0.1, 0.1, 0.1, 0.0) },
    // 7: brushedMetal (rgb)
    { float4(0.5, 0.5, 0.5, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.5, 0.5, 0.5, 0.0), float4(0.0, 0.1, 0.2, 0.0) },
    // 8: burningSky (rgb)
    { float4(0.7259015, 0.7004237, 0.9494409, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.63290054, 0.37883538, 0.29405284, 0.0), float4(0.0, 0.1, 0.2, 0.0) },
    // 9: california (rgb)
    { float4(0.94, 0.33, 0.27, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.74, 0.37, 0.73, 0.0), float4(0.44, 0.17, 0.88, 0.0) },
    // 10: columbia (rgb)
    { float4(1.0, 0.7, 1.0, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(1.0, 0.4, 0.9, 0.0), float4(0.4, 0.5, 0.6, 0.0) },
    // 11: cottonCandy (rgb)
    { float4(0.51, 0.39, 0.41, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.59, 0.53, 0.94, 0.0), float4(0.15, 0.41, 0.46, 0.0) },
    // 12: darkSatin (hsv)
    { float4(0.0, 0.0, 0.51, 1.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.0, 0.0, 0.43, 0.0), float4(0.0, 0.0, 0.36, 0.0) },
    // 13: dealerHat (rgb)
    { float4(0.83, 0.45, 0.19, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.79, 0.45, 0.35, 0.0), float4(0.28, 0.91, 0.61, 0.0) },
    // 14: dreamy (rgb)
    { float4(0.5, 0.5, 0.5, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.5, 0.5, 0.5, 0.0), float4(0.0, 0.2, 0.25, 0.0) },
    // 15: eventHorizon (rgb)
    { float4(0.5, 0.5, 0.5, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.22, 0.48, 0.62, 0.0), float4(0.1, 0.3, 0.2, 0.0) },
    // 16: ghostly (hsv)
    { float4(0.02, 0.92, 0.76, 1.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.51, 0.49, 0.51, 0.0), float4(0.71, 0.23, 0.66, 0.0) },
    // 17: grayscale (rgb)
    { float4(0.5, 0.5, 0.5, 0.0), float4(2.0, 2.0, 2.0, 0.0), float4(0.5, 0.5, 0.5, 0.0), float4(1.0, 1.0, 1.0, 0.0) },
    // 18: hazySunset (rgb)
    { float4(0.79, 0.56, 0.22, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.96, 0.5, 0.49, 0.0), float4(0.15, 0.98, 0.87, 0.0) },
    // 19: heatmap (rgb)
    { float4(0.75804377, 0.62868536, 0.2227562, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.35536355, 0.12935615, 0.17060602, 0.0), float4(0.0, 0.25, 0.5, 0.0) },
    // 20: hypercolor (rgb)
    { float4(0.79, 0.5, 0.23, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.75, 0.47, 0.45, 0.0), float4(0.08, 0.84, 0.16, 0.0) },
    // 21: jester (rgb)
    { float4(0.7, 0.81, 0.73, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.1, 0.22, 0.27, 0.0), float4(0.99, 0.12, 0.94, 0.0) },
    // 22: justBlue (rgb)
    { float4(0.5, 0.5, 0.5, 0.0), float4(0.0, 0.0, 1.0, 0.0), float4(0.5, 0.5, 0.5, 0.0), float4(0.5, 0.5, 0.5, 0.0) },
    // 23: justCyan (rgb)
    { float4(0.5, 0.5, 0.5, 0.0), float4(0.0, 1.0, 1.0, 0.0), float4(0.5, 0.5, 0.5, 0.0), float4(0.5, 0.5, 0.5, 0.0) },
    // 24: justGreen (rgb)
    { float4(0.5, 0.5, 0.5, 0.0), float4(0.0, 1.0, 0.0, 0.0), float4(0.5, 0.5, 0.5, 0.0), float4(0.5, 0.5, 0.5, 0.0) },
    // 25: justPurple (rgb)
    { float4(0.5, 0.5, 0.5, 0.0), float4(1.0, 0.0, 1.0, 0.0), float4(0.5, 0.5, 0.5, 0.0), float4(0.5, 0.5, 0.5, 0.0) },
    // 26: justRed (rgb)
    { float4(0.5, 0.5, 0.5, 0.0), float4(1.0, 0.0, 0.0, 0.0), float4(0.5, 0.5, 0.5, 0.0), float4(0.5, 0.5, 0.5, 0.0) },
    // 27: justYellow (rgb)
    { float4(0.5, 0.5, 0.5, 0.0), float4(1.0, 1.0, 0.0, 0.0), float4(0.5, 0.5, 0.5, 0.0), float4(0.5, 0.5, 0.5, 0.0) },
    // 28: mars (rgb)
    { float4(0.74, 0.33, 0.09, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.62, 0.2, 0.2, 0.0), float4(0.2, 0.1, 0.0, 0.0) },
    // 29: modesto (rgb)
    { float4(0.56, 0.68, 0.39, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.72, 0.07, 0.62, 0.0), float4(0.25, 0.4, 0.41, 0.0) },
    // 30: moss (rgb)
    { float4(0.78, 0.39, 0.07, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.0, 0.53, 0.33, 0.0), float4(0.94, 0.92, 0.9, 0.0) },
    // 31: neptune (rgb)
    { float4(0.5, 0.5, 0.5, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.2, 0.64, 0.62, 0.0), float4(0.15, 0.2, 0.3, 0.0) },
    // 32: netOfGems (rgb)
    { float4(0.5, 0.5, 0.5, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.64, 0.12, 0.84, 0.0), float4(0.1, 0.25, 0.15, 0.0) },
    // 33: organic (rgb)
    { float4(0.42, 0.42, 0.04, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.47, 0.27, 0.27, 0.0), float4(0.41, 0.14, 0.11, 0.0) },
    // 34: papaya (rgb)
    { float4(0.65, 0.4, 0.11, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.72, 0.45, 0.08, 0.0), float4(0.71, 0.8, 0.84, 0.0) },
    // 35: radioactive (rgb)
    { float4(0.62, 0.79, 0.11, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.22, 0.56, 0.17, 0.0), float4(0.15, 0.1, 0.25, 0.0) },
    // 36: royal (rgb)
    { float4(0.5, 0.5, 0.5, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.41, 0.22, 0.67, 0.0), float4(0.2, 0.25, 0.2, 0.0) },
    // 37: santaCruz (rgb)
    { float4(0.5, 0.5, 0.5, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.5, 0.5, 0.5, 0.0), float4(0.25, 0.5, 0.75, 0.0) },
    // 38: sherbet (rgb)
    { float4(0.6059281, 0.17591387, 0.17166573, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.5224456, 0.3864609, 0.36020845, 0.0), float4(0.0, 0.25, 0.5, 0.0) },
    // 39: sherbetDouble (rgb)
    { float4(0.6059281, 0.17591387, 0.17166573, 0.0), float4(2.0, 2.0, 2.0, 0.0), float4(0.5224456, 0.3864609, 0.36020845, 0.0), float4(0.0, 0.25, 0.5, 0.0) },
    // 40: silvermane (oklab)
    { float4(0.42, 0.0, 0.0, 2.0), float4(2.0, 2.0, 2.0, 0.0), float4(0.45, 0.5, 0.42, 0.0), float4(0.63, 1.0, 1.0, 0.0) },
    // 41: skykissed (rgb)
    { float4(0.5, 0.5, 0.5, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.83, 0.6, 0.63, 0.0), float4(0.3, 0.1, 0.0, 0.0) },
    // 42: solaris (rgb)
    { float4(0.5, 0.5, 0.5, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.6, 0.4, 0.1, 0.0), float4(0.3, 0.2, 0.1, 0.0) },
    // 43: spooky (oklab)
    { float4(0.46, 0.73, 0.19, 2.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.27, 0.79, 0.78, 0.0), float4(0.27, 0.16, 0.04, 0.0) },
    // 44: springtime (rgb)
    { float4(0.67, 0.25, 0.27, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.74, 0.48, 0.46, 0.0), float4(0.07, 0.79, 0.39, 0.0) },
    // 45: sproingtime (rgb)
    { float4(0.9, 0.43, 0.34, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.56, 0.69, 0.32, 0.0), float4(0.03, 0.8, 0.4, 0.0) },
    // 46: sulphur (rgb)
    { float4(0.73, 0.36, 0.52, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.78, 0.68, 0.15, 0.0), float4(0.74, 0.93, 0.28, 0.0) },
    // 47: summoning (rgb)
    { float4(1.0, 0.0, 0.8, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.0, 0.0, 0.0, 0.0), float4(0.0, 0.5, 0.1, 0.0) },
    // 48: superhero (rgb)
    { float4(1.0, 0.25, 0.5, 0.0), float4(0.5, 0.5, 0.5, 0.0), float4(0.0, 0.0, 0.25, 0.0), float4(0.5, 0.0, 0.0, 0.0) },
    // 49: toxic (rgb)
    { float4(0.5, 0.5, 0.5, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.26, 0.57, 0.03, 0.0), float4(0.0, 0.1, 0.3, 0.0) },
    // 50: tropicalia (oklab)
    { float4(0.28, 0.08, 0.65, 2.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.48, 0.6, 0.03, 0.0), float4(0.1, 0.15, 0.3, 0.0) },
    // 51: tungsten (rgb)
    { float4(0.65, 0.93, 0.73, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.31, 0.21, 0.27, 0.0), float4(0.43, 0.45, 0.48, 0.0) },
    // 52: vaporwave (rgb)
    { float4(0.9, 0.76, 0.63, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.0, 0.19, 0.68, 0.0), float4(0.43, 0.23, 0.32, 0.0) },
    // 53: vibrant (rgb)
    { float4(0.78, 0.63, 0.68, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.41, 0.03, 0.16, 0.0), float4(0.81, 0.61, 0.06, 0.0) },
    // 54: vintage (rgb)
    { float4(0.97, 0.74, 0.23, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.97, 0.38, 0.35, 0.0), float4(0.34, 0.41, 0.44, 0.0) },
    // 55: vintagePhoto (rgb)
    { float4(0.68, 0.79, 0.57, 0.0), float4(1.0, 1.0, 1.0, 0.0), float4(0.56, 0.35, 0.14, 0.0), float4(0.73, 0.9, 0.99, 0.0) }
};

// -----------------------------------------------------------------------------
// floorMod — WGSL fn floorMod: floored mod matching GLSL mod(x,y) behavior.
// WGSL: return x - y * floor(x / y);
// Uses nm_mod alias per PORTING-GUIDE (not fmod).
// -----------------------------------------------------------------------------
float floorMod(float x, float y)
{
    return nm_mod(x, y);
}

// -----------------------------------------------------------------------------
// hsv_to_rgb — ported VERBATIM from palette.wgsl. Per-effect copy.
// WGSL:
//   let c = v * s;
//   let hp = h * 6.0;
//   let x = c * (1.0 - abs(floorMod(hp, 2.0) - 1.0));
//   let m = v - c;
//   if (hp < 1.0) { rgb = (c,x,0) } else if (hp < 2.0) { rgb = (x,c,0) }
//   else if (hp < 3.0) { rgb = (0,c,x) } else if (hp < 4.0) { rgb = (0,x,c) }
//   else if (hp < 5.0) { rgb = (x,0,c) } else { rgb = (c,0,x) }
//   return rgb + vec3f(m,m,m);
// -----------------------------------------------------------------------------
float3 hsv_to_rgb(float3 hsv)
{
    float h = hsv.x;
    float s = hsv.y;
    float v = hsv.z;

    float c = v * s;
    float hp = h * 6.0;
    float x = c * (1.0 - abs(floorMod(hp, 2.0) - 1.0));
    float m = v - c;

    float3 rgb;
    if (hp < 1.0) {
        rgb = float3(c, x, 0.0);
    } else if (hp < 2.0) {
        rgb = float3(x, c, 0.0);
    } else if (hp < 3.0) {
        rgb = float3(0.0, c, x);
    } else if (hp < 4.0) {
        rgb = float3(0.0, x, c);
    } else if (hp < 5.0) {
        rgb = float3(x, 0.0, c);
    } else {
        rgb = float3(c, 0.0, x);
    }

    return rgb + float3(m, m, m);
}

// -----------------------------------------------------------------------------
// oklab_to_linear_rgb — ported VERBATIM from palette.wgsl.
// -----------------------------------------------------------------------------
float3 oklab_to_linear_rgb(float3 lab)
{
    float L = lab.x;
    float a = lab.y;
    float b = lab.z;

    float l_ = L + 0.3963377774 * a + 0.2158037573 * b;
    float m_ = L - 0.1055613458 * a - 0.0638541728 * b;
    float s_ = L - 0.0894841775 * a - 1.2914855480 * b;

    float l = l_ * l_ * l_;
    float m = m_ * m_ * m_;
    float s = s_ * s_ * s_;

    return float3(
         4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    );
}

// -----------------------------------------------------------------------------
// linear_to_srgb — ported VERBATIM from palette.wgsl.
// WGSL select(high, low, linear <= 0.0031308) — reversed args!
// WGSL select(false_val, true_val, cond) → cond ? true_val : false_val
// Component-wise: result[i] = (linear[i] <= 0.0031308) ? low[i] : high[i]
// -----------------------------------------------------------------------------
float3 linear_to_srgb(float3 lin)
{
    float3 low  = lin * 12.92;
    float3 high = 1.055 * pow(lin, float3(1.0 / 2.4, 1.0 / 2.4, 1.0 / 2.4)) - 0.055;
    // Component-wise select matching WGSL select(high, low, linear <= vec3f(0.0031308))
    float3 mask = float3(
        (lin.x <= 0.0031308) ? 1.0 : 0.0,
        (lin.y <= 0.0031308) ? 1.0 : 0.0,
        (lin.z <= 0.0031308) ? 1.0 : 0.0
    );
    return lerp(high, low, mask);
}

// -----------------------------------------------------------------------------
// oklab_to_rgb — ported VERBATIM from palette.wgsl.
// WGSL:
//   labMod.g = labMod.g * -0.509 + 0.276;
//   labMod.b = labMod.b * -0.509 + 0.198;
//   return clamp(linear_to_srgb(oklab_to_linear_rgb(labMod)), 0, 1);
// -----------------------------------------------------------------------------
float3 oklab_to_rgb(float3 lab)
{
    float3 labMod = lab;
    labMod.g = labMod.g * -0.509 + 0.276;
    labMod.b = labMod.b * -0.509 + 0.198;
    float3 linear_rgb = oklab_to_linear_rgb(labMod);
    return clamp(linear_to_srgb(linear_rgb), float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

// -----------------------------------------------------------------------------
// cosine_palette — IQ formula. Ported VERBATIM from palette.wgsl.
// WGSL:
//   let TAU = 6.283185307179586;
//   return clamp(offset + amp * cos(TAU * (freq * t + phase)), 0, 1);
// -----------------------------------------------------------------------------
float3 cosine_palette(float t, float3 amp, float3 freq, float3 pal_offset, float3 phase)
{
    const float TAU = 6.283185307179586;
    return clamp(pal_offset + amp * cos(TAU * (freq * t + phase)), float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

// -----------------------------------------------------------------------------
// nm_palette — core per-pixel evaluation. Ported VERBATIM from palette.wgsl main().
// Takes the already-sampled input color and the current engine time.
// Returns blended RGBA.
// -----------------------------------------------------------------------------
float4 nm_palette(float4 inputColor, float engineTime)
{
    // Index 0 is passthrough
    if (paletteIndex <= 0 || paletteIndex > 55)
    {
        return inputColor;
    }

    // WGSL: lum = dot(inputColor.rgb, vec3f(0.299, 0.587, 0.114))
    float lum = dot(inputColor.rgb, float3(0.299, 0.587, 0.114));

    // WGSL: t = lum * repeat + offset * 0.01
    float t = lum * repeat + offset * 0.01;

    [branch]
    if (rotation == -1)
    {
        t = t + engineTime;
    }
    else if (rotation == 1)
    {
        t = t - engineTime;
    }

    // Array is 0-indexed, palette indices are 1-indexed
    PaletteEntry entry = palettes[paletteIndex - 1];

    // Extract mode from amp.w: WGSL i32(entry.amp.w + 0.5)
    int mode = (int)(entry.amp.w + 0.5);

    float3 paletteColor = cosine_palette(t, entry.amp.xyz, entry.freq.xyz, entry.palOff.xyz, entry.phase.xyz);

    float3 finalColor;
    [branch]
    if (mode == 1)
    {
        // HSV mode
        finalColor = hsv_to_rgb(paletteColor);
    }
    else if (mode == 2)
    {
        // OkLab mode
        finalColor = oklab_to_rgb(paletteColor);
    }
    else
    {
        // RGB mode (default)
        finalColor = paletteColor;
    }

    // WGSL: mix(inputColor.rgb, finalColor, alpha)
    float3 blendedColor = lerp(inputColor.rgb, finalColor, alpha);

    return float4(blendedColor, inputColor.a);
}

#endif // NM_PALETTE_INCLUDED
