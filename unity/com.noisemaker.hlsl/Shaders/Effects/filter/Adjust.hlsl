#ifndef NM_EFFECT_ADJUST_INCLUDED
#define NM_EFFECT_ADJUST_INCLUDED

// =============================================================================
// Adjust.hlsl — filter/adjust (func: "adjust")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/filter/adjust/wgsl/adjust.wgsl
//
// Combined color adjustment: colorspace reinterpretation (RGB / HSV / OKLab /
// OKLCH) + hue/saturation + brightness/contrast, in one render pass.
//
// Helpers (hsv2rgb, rgb2hsv, floorMod, mapVal, the OKLab matrices,
// linear_srgb_from_oklab, linearToSrgb) are ported VERBATIM and INLINE per
// PORTING-GUIDE — they are NOT hoisted into NMCore. This effect uses NO
// PCG/prng. `mapVal`/`floorMod` are local copies of the WGSL forms (not the
// NMCore variants) to keep the port self-contained and literal.
//
// NUMERIC / TRANSLATION HAZARDS handled:
//  * Sampling UV: WGSL uses `pos.xy / textureDimensions(inputTex)` — divides by
//    the INPUT TEXTURE dimensions (NOT fullResolution, NOT fullResolution.y).
//    -> HLSL: inputTex.GetDimensions(w,h); uv = NM_FragCoord(i) / float2(w,h).
//    NM_FragCoord (no tileOffset) mirrors WGSL @builtin(position).xy.
//  * `floorMod(x,y) = x - y*floor(x/y)` — this effect's own GLSL `mod`/WGSL
//    helper. Kept inline; equivalent to nm_mod but copied literally per guide.
//  * mat3x3 in WGSL/GLSL is COLUMN-MAJOR and `M * v` = col0*v.x+col1*v.y+col2*v.z.
//    Reproduced as explicit column accumulation to avoid any HLSL row/col-major
//    ambiguity. Constants kept full-precision exactly as the WGSL literals.
//  * mode is an int uniform; if/else-if chain matches the WGSL exactly (mode 0
//    leaves color untouched).
//  * cube exponent / sRGB transfer constants (12.92, 0.0031308, 1.055, 1/2.4,
//    0.055) kept literal. 1.0/2.4 left as a division (matches WGSL `1.0 / 2.4`).
//  * fract -> frac. abs/cos/sin/pow/max/min map 1:1.
// =============================================================================

// The input texture + sampler and the fragment entry live in Adjust.shader
// (matching the sibling filter/tint convention), so the runtime binds inputTex
// and the named uniforms via MaterialPropertyBlock without duplicate decls.
#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
// Bound by the runtime via MaterialPropertyBlock.
int   mode;        // 0: rgb (off), 1: HSV, 2: OKLab, 3: OKLCH   default 0
float rotation;    // hue rotation degrees, [-180,180]           default 0
float hueRange;    // hue range, [0,200]                          default 100
float saturation;  // [0,4]                                       default 1
float brightness;  // [0,10]                                      default 1
float contrast;    // [0,1]                                       default 0.5

static const float NM_ADJ_TAU = 6.28318530718;

// map(value, inMin, inMax, outMin, outMax) — verbatim WGSL `mapVal`.
float nm_adj_mapVal(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

// floorMod(x,y) = x - y*floor(x/y) — verbatim WGSL `floorMod`.
float nm_adj_floorMod(float x, float y)
{
    return x - y * floor(x / y);
}

// --- Colorspace functions (verbatim from WGSL) ---

float3 nm_adj_hsv2rgb(float3 hsv)
{
    float h = frac(hsv.x);
    float s = hsv.y;
    float v = hsv.z;
    float c = v * s;
    float x = c * (1.0 - abs(nm_adj_floorMod(h * 6.0, 2.0) - 1.0));
    float m = v - c;
    float3 rgb;
    if (h < 1.0/6.0) { rgb = float3(c, x, 0.0); }
    else if (h < 2.0/6.0) { rgb = float3(x, c, 0.0); }
    else if (h < 3.0/6.0) { rgb = float3(0.0, c, x); }
    else if (h < 4.0/6.0) { rgb = float3(0.0, x, c); }
    else if (h < 5.0/6.0) { rgb = float3(x, 0.0, c); }
    else { rgb = float3(c, 0.0, x); }
    return rgb + m;
}

float3 nm_adj_rgb2hsv(float3 rgb)
{
    float r = rgb.r; float g = rgb.g; float b = rgb.b;
    float maxC = max(r, max(g, b));
    float minC = min(r, min(g, b));
    float delta = maxC - minC;

    float h = 0.0;
    if (delta != 0.0)
    {
        if (maxC == r)
        {
            h = nm_adj_floorMod((g - b) / delta, 6.0) / 6.0;
        }
        else if (maxC == g)
        {
            h = ((b - r) / delta + 2.0) / 6.0;
        }
        else
        {
            h = ((r - g) / delta + 4.0) / 6.0;
        }
    }
    float s = 0.0;
    if (maxC != 0.0) { s = delta / maxC; }
    return float3(h, s, maxC);
}

// OKLab -> linear sRGB matrices.
// WGSL mat3x3 is column-major; M*c = col0*c.x + col1*c.y + col2*c.z.
//   fwdA columns: (1,1,1), (0.3963377774,-0.1055613458,-0.0894841775),
//                 (0.2158037573,-0.0638541728,-1.2914855480)
//   fwdB columns: (4.0767245293,-1.2681437731,-0.0041119885),
//                 (-3.3072168827,2.6093323231,-0.7034763098),
//                 (0.2307590544,-0.3411344290,1.7068625689)
// Reproduced as explicit column accumulation (literal column constants).
float3 nm_adj_linear_srgb_from_oklab(float3 c)
{
    float3 fwdA_c0 = float3(1.0, 1.0, 1.0);
    float3 fwdA_c1 = float3(0.3963377774, -0.1055613458, -0.0894841775);
    float3 fwdA_c2 = float3(0.2158037573, -0.0638541728, -1.2914855480);
    float3 lms = fwdA_c0 * c.x + fwdA_c1 * c.y + fwdA_c2 * c.z;

    float3 cubed = lms * lms * lms;

    float3 fwdB_c0 = float3(4.0767245293, -1.2681437731, -0.0041119885);
    float3 fwdB_c1 = float3(-3.3072168827, 2.6093323231, -0.7034763098);
    float3 fwdB_c2 = float3(0.2307590544, -0.3411344290, 1.7068625689);
    return fwdB_c0 * cubed.x + fwdB_c1 * cubed.y + fwdB_c2 * cubed.z;
}

float3 nm_adj_linearToSrgb(float3 lin)
{
    float3 srgb;
    [unroll]
    for (int i = 0; i < 3; i = i + 1)
    {
        if (lin[i] <= 0.0031308)
        {
            srgb[i] = lin[i] * 12.92;
        }
        else
        {
            srgb[i] = 1.055 * pow(lin[i], 1.0 / 2.4) - 0.055;
        }
    }
    return srgb;
}

// =============================================================================
// nm_adjust — core per-pixel evaluation. `color` is the already-sampled input
// RGBA. Mirrors WGSL main() body after the textureSample. Returns RGBA.
// =============================================================================
float4 nm_adjust(float4 color)
{
    // --- Colorspace reinterpretation ---
    if (mode == 1)
    {
        // HSV
        color = float4(nm_adj_hsv2rgb(color.rgb), color.a);
    }
    else if (mode == 2)
    {
        // OKLab
        float3 lab = color.rgb;
        lab.g = lab.g * -0.509 + 0.276;
        lab.b = lab.b * -0.509 + 0.198;
        float3 rgb = nm_adj_linear_srgb_from_oklab(lab);
        rgb = nm_adj_linearToSrgb(rgb);
        color = float4(rgb, color.a);
    }
    else if (mode == 3)
    {
        // OKLCH - interpret RGB as L, C, H
        float L = color.r;
        float C = color.g * 0.4;
        float H = color.b * NM_ADJ_TAU;
        float a = C * cos(H);
        float b = C * sin(H);
        float3 rgb = nm_adj_linear_srgb_from_oklab(float3(L, a, b));
        rgb = nm_adj_linearToSrgb(rgb);
        color = float4(rgb, color.a);
    }

    // --- Hue / Saturation ---
    float3 hsv = nm_adj_rgb2hsv(color.rgb);
    hsv.x = frac(hsv.x * nm_adj_mapVal(hueRange, 0.0, 200.0, 0.0, 2.0) + (rotation / 360.0));
    hsv.y = hsv.y * saturation;
    color = float4(nm_adj_hsv2rgb(hsv), color.a);

    // --- Brightness / Contrast ---
    color = float4(color.rgb * brightness, color.a);
    float contrastFactor = contrast * 2.0;
    color = float4((color.rgb - 0.5) * contrastFactor + 0.5, color.a);

    return color;
}

#endif // NM_EFFECT_ADJUST_INCLUDED
