#ifndef NM_TETRACOSINE_INCLUDED
#define NM_TETRACOSINE_INCLUDED

// =============================================================================
// TetraCosine.hlsl — filter/tetraCosine, ported PIXEL-IDENTICALLY from the
//   canonical WGSL: shaders/effects/filter/tetraCosine/wgsl/tetraCosine.wgsl
//
// Applies a cosine palette to an input image based on luminance.
// Inigo Quilez formula: color(t) = offset + amp * cos(2π * (freq * t + phase))
// Supports RGB (0), HSV (1), OkLab (2), OKLCH (3) color modes.
//
// PORTING NOTES:
//  * uv = fragCoord / textureDimensions(inputTex) — INPUT texture's own size,
//    NOT fullResolution. NM_FragCoord(i) is the top-left +0.5 HLSL analog.
//  * Per-effect helpers (hsv2rgb, oklab2linear, linear2srgb, oklab2rgb,
//    oklch2rgb, cosinePalette) copied verbatim from WGSL. These differ from
//    any generic versions.
//  * colorMode and rotation are int uniforms; [branch] at runtime.
//  * WGSL select(b, a, cond) maps to (cond ? a : b) in HLSL (reversed order).
//  * nm_mod not fmod. TAU literal preserved exactly.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---------------------------------------------------------------------------
// Per-effect uniforms (one per definition.js globals[*].uniform)
// ---------------------------------------------------------------------------
int   colorMode;   // 0=rgb, 1=hsv, 2=oklab, 3=oklch
float offsetR;
float offsetG;
float offsetB;
float ampR;
float ampG;
float ampB;
int   freqR;       // definition.js: type "int"
int   freqG;
int   freqB;
float phaseR;
float phaseG;
float phaseB;
int   rotation;    // choices: none=0, fwd=1, back=-1
float repeat;
float offset;      // mapping offset (uniform name "offset" in definition.js)
float alpha;
// time is provided by NMFullscreen.hlsl as the engine global `time`

// ---------------------------------------------------------------------------
// Helpers — verbatim from WGSL (this effect's own versions)
// ---------------------------------------------------------------------------


// HSV to RGB
float3 nm_tc_hsv2rgb(float3 hsv)
{
    float h = hsv.x;
    float s = hsv.y;
    float v = hsv.z;

    float c  = v * s;
    float hp = h * 6.0;
    float x  = c * (1.0 - abs(nm_mod(hp, 2.0) - 1.0));
    float m  = v - c;

    float3 rgb;
    if (hp < 1.0)
        rgb = float3(c, x, 0.0);
    else if (hp < 2.0)
        rgb = float3(x, c, 0.0);
    else if (hp < 3.0)
        rgb = float3(0.0, c, x);
    else if (hp < 4.0)
        rgb = float3(0.0, x, c);
    else if (hp < 5.0)
        rgb = float3(x, 0.0, c);
    else
        rgb = float3(c, 0.0, x);

    return rgb + float3(m, m, m);
}

// OkLab to linear RGB
float3 nm_tc_oklab2linear(float3 lab)
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

// Linear to sRGB gamma
// WGSL: select(high, low, linear < 0.0031308) → (cond ? low : high) in HLSL
float3 nm_tc_linear2srgb(float3 linearCol)
{
    float3 lo   = linearCol * 12.92;
    float3 hi   = 1.055 * pow(max(linearCol, float3(0.0, 0.0, 0.0)), float3(1.0 / 2.4, 1.0 / 2.4, 1.0 / 2.4)) - 0.055;
    return (linearCol < 0.0031308) ? lo : hi;
}

// OkLab to sRGB (a,b remapped from 0-1 storage to -0.4..0.4)
float3 nm_tc_oklab2rgb(float3 lab)
{
    float L = lab.x;
    float a = (lab.y - 0.5) * 0.8;
    float b = (lab.z - 0.5) * 0.8;

    float3 linear_rgb = nm_tc_oklab2linear(float3(L, a, b));
    return clamp(nm_tc_linear2srgb(linear_rgb), float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

// OKLCH to sRGB
float3 nm_tc_oklch2rgb(float3 lch)
{
    float L = lch.x;
    float C = lch.y * 0.4;
    float H = lch.z * NM_TAU;

    float a = C * cos(H);
    float b = C * sin(H);

    float3 linear_rgb = nm_tc_oklab2linear(float3(L, a, b));
    return clamp(nm_tc_linear2srgb(linear_rgb), float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

// Cosine palette — Inigo Quilez formula
float3 nm_tc_cosinePalette(float t, float3 pal_offset, float3 amp, float3 freq, float3 phase)
{
    return clamp(pal_offset + amp * cos(NM_TAU * (freq * t + phase)), float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

// ---------------------------------------------------------------------------
// Core function — mirrors the WGSL @fragment main() body exactly
// ---------------------------------------------------------------------------
float4 nm_tetraCosine(
    Texture2D    inputTex,
    SamplerState sampler_inputTex,
    float2       fragCoord)
{
    uint tw, th;
    inputTex.GetDimensions(tw, th);
    float2 texSize   = float2(tw, th);
    float2 uv        = fragCoord / texSize;

    float4 inputColor = inputTex.Sample(sampler_inputTex, uv);

    float lum = dot(inputColor.rgb, float3(0.299, 0.587, 0.114));

    float t = lum * repeat + offset;

    [branch]
    if (rotation == -1)
        t = t + time;
    else if (rotation == 1)
        t = t - time;

    t = frac(t);

    float3 pal_offset = float3(offsetR, offsetG, offsetB);
    float3 amp_vec    = float3(ampR, ampG, ampB);
    float3 freq_vec   = float3((float)freqR, (float)freqG, (float)freqB);
    float3 phase_vec  = float3(phaseR, phaseG, phaseB);

    float3 paletteColor = nm_tc_cosinePalette(t, pal_offset, amp_vec, freq_vec, phase_vec);

    float3 finalColor;
    [branch]
    if (colorMode == 1)
        finalColor = nm_tc_hsv2rgb(paletteColor);
    else if (colorMode == 2)
        finalColor = nm_tc_oklab2rgb(paletteColor);
    else if (colorMode == 3)
        finalColor = nm_tc_oklch2rgb(paletteColor);
    else
        finalColor = paletteColor;

    float3 blendedColor = lerp(inputColor.rgb, finalColor, alpha);

    return float4(blendedColor, inputColor.a);
}

#endif // NM_TETRACOSINE_INCLUDED
