#ifndef NM_EFFECT_GRADE_INCLUDED
#define NM_EFFECT_GRADE_INCLUDED

// =============================================================================
// Grade.hlsl — filter/grade (func: "grade")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL sources:
//   shaders/effects/filter/grade/wgsl/primary.wgsl       (progName "primary")
//   shaders/effects/filter/grade/wgsl/creative.wgsl      (progName "creative")
//   shaders/effects/filter/grade/wgsl/wheels.wgsl        (progName "wheels")
//   shaders/effects/filter/grade/wgsl/hslSecondary.wgsl  (progName "hslSecondary")
//   shaders/effects/filter/grade/wgsl/lut.wgsl           (progName "lut")
//   shaders/effects/filter/grade/wgsl/vignette.wgsl      (progName "vignette")
//
// SIX-pass linear color-grading chain. Each pass reads its predecessor's
// persistent intermediate target and writes the next:
//   primary:      inputTex      -> _primaryTex
//   creative:     _primaryTex   -> _creativeTex
//   wheels:       _creativeTex  -> _wheelsTex
//   hslSecondary: _wheelsTex    -> _hslTex
//   lut:          _hslTex       -> _lutTex
//   vignette:     _lutTex       -> outputTex
//
// NO MRT, NO repeat:, NO feedback (no pass samples its OWN previous output).
// The "_"-prefixed textures are persistent intermediate buffers, not feedback
// state; each is written by exactly one pass and read by the next. Every pass
// binds the same HLSL sampler name `inputTex`; the C# runtime rebinds it per
// pass to the correct intermediate. NMVertFullscreen drives every pass.
//
// NOTE: this effect is multi-pass and ships as a runtime-rendered Texture2D.
// No Shader Graph Custom Function wrapper is provided (per PORTING-GUIDE: only
// single-pass generators get one).
//
// PORTING-GUIDE notes / hazards handled:
//  * Ported from WGSL (top-left, canonical) — no per-effect Y flip (H8).
//  * primary/creative/wheels/hslSecondary/vignette: texSize = textureDimensions(
//    inputTex); uv = pos.xy / texSize. We mirror exactly: NM_FragCoord(i) /
//    float2(w,h) using the bound input's OWN dimensions (NOT fullResolution).
//  * lut: uses textureLoad(inputTex, vec2i(fragCoord.xy), 0) — an integer-coord
//    fetch with NO sampler. Ported as inputTex.Load(int3((int2)fragCoord, 0)).
//    floor-toward-zero of the +0.5-centered fragCoord matches WGSL vec2i().
//  * pow(2.0, exposure) -> pow(2.0, exposure) (exact; not exp2 of an int).
//  * select(b,a,cond) (WGSL, reversed) -> cond ? a : b (HLSL). Applied in the
//    lut rgbToHsl/hslToRgb and lutHardLight/lutSolarize branches.
//  * Each pass's color helpers (srgbToLinear/linearToSrgb/rgbToHsl/hslToRgb/
//    luma/...) are copied inline per-pass-family; despite identical names they
//    are reproduced verbatim from each source file (PORTING-GUIDE rule 2). The
//    hslSecondary hslToRgb differs from the lut hslToRgb (loop form vs hue2rgb)
//    — both are kept distinct.
//  * No reassociation / no fast-math simplification (rule 3). Full 32-bit float.
//  * Linear, clamp-to-edge, non-sRGB sampler (H7) — set on SamplerState below.
//  * `_padN` WGSL struct members are alignment padding only; not bound.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (reference binding: sampler@0, inputTex@1) ------
// All passes use the same HLSL name `inputTex`; the runtime rebinds it per pass
// (inputTex -> _primaryTex -> _creativeTex -> _wheelsTex -> _hslTex -> _lutTex).
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
// primary
float temperature;     // default 0
float tint;            // default 0
float exposure;        // default 0
float contrast;        // default 0
float highlights;      // default 0
float shadows;         // default 0
float whites;          // default 0
float blacks;          // default 0
float saturation;      // default 1
float curveShadows;    // default 0
float curveMidtones;   // default 0
float curveHighlights; // default 0
// creative
float vibrance;          // default 0
float fadedFilm;         // default 0
float splitToneBalance;  // default 0
float3 shadowTint;       // default (0.5,0.5,0.5)
float3 highlightTint;    // default (0.5,0.5,0.5)
// wheels
float wheelBalance;      // default 0
float3 wheelShadows;     // default (0.5,0.5,0.5)
float3 wheelMidtones;    // default (0.5,0.5,0.5)
float3 wheelHighlights;  // default (0.5,0.5,0.5)
// hslSecondary
int   hslEnable;       // default 0
float hslHueCenter;    // default 0
float hslHueRange;     // default 0.1
float hslSatMin;       // default 0
float hslSatMax;       // default 1
float hslLumMin;       // default 0
float hslLumMax;       // default 1
float hslFeather;      // default 0.1
float hslHueShift;     // default 0
float hslSatAdjust;    // default 0
float hslLumAdjust;    // default 0
// lut
int   preset;          // default 0
float alpha;           // default 1
// vignette
float vignetteAmount;     // default 0
float vignetteMidpoint;   // default 0.5
float vignetteRoundness;  // default 0
float vignetteFeather;    // default 0.5
float vigHiProtect;       // default 0 (alias: vignetteHighlightProtect)

static const float3 LUMA_WEIGHTS = float3(0.2126, 0.7152, 0.0722);

// =============================================================================
// PASS 1: "primary" — verbatim from primary.wgsl
// =============================================================================

float3 primary_srgbToLinear(float3 srgb)
{
    float3 lin;
    for (int i = 0; i < 3; i++)
    {
        if (srgb[i] <= 0.04045)
        {
            lin[i] = srgb[i] / 12.92;
        }
        else
        {
            lin[i] = pow((srgb[i] + 0.055) / 1.055, 2.4);
        }
    }
    return lin;
}

float3 primary_linearToSrgb(float3 lin)
{
    float3 srgb;
    for (int i = 0; i < 3; i++)
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

float3 primary_applyWhiteBalance(float3 rgb, float temp, float tnt)
{
    float3 shift = float3(
        1.0 + temp * 0.5,
        1.0 - tnt * 0.5,
        1.0 - temp * 0.5
    );
    return rgb * shift;
}

float primary_shadowWeight(float luma)    { return 1.0 - smoothstep(0.0, 0.5, luma); }
float primary_highlightWeight(float luma) { return smoothstep(0.5, 1.0, luma); }
float primary_midtoneWeight(float luma)   { return 1.0 - abs(luma - 0.5) * 2.0; }
float primary_whitesWeight(float luma)    { return smoothstep(0.7, 1.0, luma); }
float primary_blacksWeight(float luma)    { return 1.0 - smoothstep(0.0, 0.3, luma); }

float3 primary_applyTonalRanges(float3 rgb, float hi, float sh, float wh, float bl)
{
    float luma = dot(rgb, LUMA_WEIGHTS);
    float3 chroma = rgb - luma;

    float hWeight = primary_highlightWeight(luma);
    float sWeight = primary_shadowWeight(luma);
    float wWeight = primary_whitesWeight(luma);
    float bWeight = primary_blacksWeight(luma);

    float lumaAdjust = 0.0;
    lumaAdjust += hi * hWeight * 0.5;
    lumaAdjust += sh * sWeight * 0.5;
    lumaAdjust += wh * wWeight * 0.3;
    lumaAdjust += bl * bWeight * 0.3;

    float newLuma = max(luma + lumaAdjust, 0.0);

    return newLuma + chroma;
}

float3 primary_applyContrast(float3 rgb, float contrastV)
{
    if (abs(contrastV) < 0.001) { return rgb; }

    float luma = dot(rgb, LUMA_WEIGHTS);
    float3 chroma = rgb - luma;

    float pivot = 0.5;
    float factor = 1.0 + contrastV;

    float newLuma = clamp((luma - pivot) * factor + pivot, 0.0, 1.5);

    return newLuma + chroma;
}

float3 primary_applyCurve(float3 rgb, float shadowLift, float midGamma, float highGain)
{
    float luma = dot(rgb, LUMA_WEIGHTS);
    float3 chroma = rgb - luma;

    float sW = primary_shadowWeight(luma);
    float mW = primary_midtoneWeight(luma);
    float hW = primary_highlightWeight(luma);

    float lift = shadowLift * sW * 0.2;
    float gamma = 1.0 - midGamma * mW * 0.3;
    float gain = 1.0 + highGain * hW * 0.5;

    float newLuma = luma + lift;
    newLuma = pow(max(newLuma, 0.001), gamma);
    newLuma = newLuma * gain;

    return max(newLuma + chroma, float3(0.0, 0.0, 0.0));
}

float3 primary_applySaturation(float3 rgb, float satAmount)
{
    float luma = dot(rgb, LUMA_WEIGHTS);
    float3 chroma = rgb - luma;
    return luma + chroma * satAmount;
}

float4 frag_primary(NMVaryings i) : SV_Target
{
    uint w, h;
    inputTex.GetDimensions(w, h);
    float2 texSize = float2((float)w, (float)h);
    float2 uv = NM_FragCoord(i) / texSize;
    float4 color = inputTex.Sample(sampler_inputTex, uv);

    float3 rgb = primary_srgbToLinear(color.rgb);

    rgb = primary_applyWhiteBalance(rgb, temperature, tint);
    rgb = rgb * pow(2.0, exposure);
    rgb = primary_applyContrast(rgb, contrast);
    rgb = primary_applyTonalRanges(rgb, highlights, shadows, whites, blacks);
    rgb = primary_applyCurve(rgb, curveShadows, curveMidtones, curveHighlights);
    rgb = primary_applySaturation(rgb, saturation);

    rgb = primary_linearToSrgb(max(rgb, float3(0.0, 0.0, 0.0)));

    return float4(rgb, color.a);
}

// =============================================================================
// PASS 2: "creative" — verbatim from creative.wgsl
// =============================================================================

float3 creative_srgbToLinear(float3 srgb)
{
    float3 lin;
    for (int i = 0; i < 3; i++)
    {
        if (srgb[i] <= 0.04045) { lin[i] = srgb[i] / 12.92; }
        else { lin[i] = pow((srgb[i] + 0.055) / 1.055, 2.4); }
    }
    return lin;
}

float3 creative_linearToSrgb(float3 lin)
{
    float3 srgb;
    for (int i = 0; i < 3; i++)
    {
        if (lin[i] <= 0.0031308) { srgb[i] = lin[i] * 12.92; }
        else { srgb[i] = 1.055 * pow(lin[i], 1.0 / 2.4) - 0.055; }
    }
    return srgb;
}

float3 creative_applyVibrance(float3 rgb, float vibranceV)
{
    if (abs(vibranceV) < 0.001) { return rgb; }

    float luma = dot(rgb, LUMA_WEIGHTS);
    float3 chroma = rgb - luma;

    float maxC = max(max(rgb.r, rgb.g), rgb.b);
    float minC = min(min(rgb.r, rgb.g), rgb.b);
    float sat;
    if (maxC > 0.001) { sat = (maxC - minC) / maxC; }
    else { sat = 0.0; }

    float vibranceGain = 1.0 + vibranceV * (1.0 - sat);

    float skinFactor = 1.0;
    if (rgb.r > rgb.g && rgb.g > rgb.b)
    {
        skinFactor = smoothstep(0.3, 0.7, sat) * 0.5 + 0.5;
    }

    float finalGain = lerp(1.0, vibranceGain, skinFactor);

    return luma + chroma * finalGain;
}

float3 creative_applyFadedFilm(float3 rgb, float amount)
{
    if (amount < 0.001) { return rgb; }

    float3 lifted = lerp(rgb, float3(0.2, 0.2, 0.2), amount * 0.5);

    float luma = dot(lifted, LUMA_WEIGHTS);
    float3 chroma = lifted - luma;

    float pivot = 0.5;
    float contrastFactor = 1.0 - amount * 0.3;
    float newLuma = (luma - pivot) * contrastFactor + pivot;

    return newLuma + chroma * (1.0 - amount * 0.2);
}

float3 creative_applySplitTone(float3 rgb, float3 shadowTintV, float3 highlightTintV, float balance)
{
    float3 shadowShift = (shadowTintV - 0.5) * 2.0;
    float3 highlightShift = (highlightTintV - 0.5) * 2.0;

    if (length(shadowShift) < 0.01 && length(highlightShift) < 0.01)
    {
        return rgb;
    }

    float luma = dot(rgb, LUMA_WEIGHTS);
    float balancePoint = 0.5 + balance * 0.3;

    float shadowW = 1.0 - smoothstep(0.0, balancePoint, luma);
    float highlightW = smoothstep(balancePoint, 1.0, luma);

    float3 tintedRgb = rgb;
    tintedRgb += shadowShift * shadowW * 0.3;
    tintedRgb += highlightShift * highlightW * 0.3;

    return tintedRgb;
}

float4 frag_creative(NMVaryings i) : SV_Target
{
    uint w, h;
    inputTex.GetDimensions(w, h);
    float2 texSize = float2((float)w, (float)h);
    float2 uv = NM_FragCoord(i) / texSize;
    float4 color = inputTex.Sample(sampler_inputTex, uv);

    float3 rgb = creative_srgbToLinear(color.rgb);

    rgb = creative_applyVibrance(rgb, vibrance);
    rgb = creative_applyFadedFilm(rgb, fadedFilm);
    rgb = creative_applySplitTone(rgb, shadowTint, highlightTint, splitToneBalance);

    rgb = creative_linearToSrgb(max(rgb, float3(0.0, 0.0, 0.0)));

    return float4(rgb, color.a);
}

// =============================================================================
// PASS 3: "wheels" — verbatim from wheels.wgsl
// =============================================================================

float3 wheels_srgbToLinear(float3 srgb)
{
    float3 lin;
    for (int i = 0; i < 3; i++)
    {
        if (srgb[i] <= 0.04045) { lin[i] = srgb[i] / 12.92; }
        else { lin[i] = pow((srgb[i] + 0.055) / 1.055, 2.4); }
    }
    return lin;
}

float3 wheels_linearToSrgb(float3 lin)
{
    float3 srgb;
    for (int i = 0; i < 3; i++)
    {
        if (lin[i] <= 0.0031308) { srgb[i] = lin[i] * 12.92; }
        else { srgb[i] = 1.055 * pow(lin[i], 1.0 / 2.4) - 0.055; }
    }
    return srgb;
}

float wheels_shadowWeight(float luma, float balance)
{
    float boundary = 0.33 - balance * 0.15;
    return 1.0 - smoothstep(0.0, boundary * 2.0, luma);
}

float wheels_midtoneWeight(float luma, float balance)
{
    float center = 0.5;
    float spread = 0.4 - abs(balance) * 0.1;
    float dist = abs(luma - center) / spread;
    return max(0.0, 1.0 - dist);
}

float wheels_highlightWeight(float luma, float balance)
{
    float boundary = 0.67 + balance * 0.15;
    return smoothstep(boundary - 0.33, 1.0, luma);
}

float3 wheels_applyWheels(float3 rgb, float3 shadowWheel, float3 midWheel,
                          float3 highWheel, float balance)
{
    float3 shadowOffset = (shadowWheel - 0.5) * 2.0;
    float3 midOffset = (midWheel - 0.5) * 2.0;
    float3 highOffset = (highWheel - 0.5) * 2.0;

    if (length(shadowOffset) < 0.01 && length(midOffset) < 0.01 && length(highOffset) < 0.01)
    {
        return rgb;
    }

    float luma = dot(rgb, LUMA_WEIGHTS);

    float sW = wheels_shadowWeight(luma, balance);
    float mW = wheels_midtoneWeight(luma, balance);
    float hW = wheels_highlightWeight(luma, balance);

    float totalWeight = sW + mW + hW + 0.001;
    sW /= totalWeight;
    mW /= totalWeight;
    hW /= totalWeight;

    float3 colorShift = float3(0.0, 0.0, 0.0);
    colorShift += shadowOffset * sW * 0.5;
    colorShift += midOffset * mW * 0.5;
    colorShift += highOffset * hW * 0.5;

    float3 result = rgb + colorShift;

    float newLuma = dot(result, LUMA_WEIGHTS);
    float lumaDiff = luma - newLuma;
    result += lumaDiff * 0.3;

    return result;
}

float4 frag_wheels(NMVaryings i) : SV_Target
{
    uint w, h;
    inputTex.GetDimensions(w, h);
    float2 texSize = float2((float)w, (float)h);
    float2 uv = NM_FragCoord(i) / texSize;
    float4 color = inputTex.Sample(sampler_inputTex, uv);

    float3 rgb = wheels_srgbToLinear(color.rgb);

    rgb = wheels_applyWheels(rgb, wheelShadows, wheelMidtones, wheelHighlights, wheelBalance);

    rgb = wheels_linearToSrgb(max(rgb, float3(0.0, 0.0, 0.0)));

    return float4(rgb, color.a);
}

// =============================================================================
// PASS 4: "hslSecondary" — verbatim from hslSecondary.wgsl
// =============================================================================

float3 hslSecondary_srgbToLinear(float3 srgb)
{
    float3 lin;
    for (int i = 0; i < 3; i++)
    {
        if (srgb[i] <= 0.04045) { lin[i] = srgb[i] / 12.92; }
        else { lin[i] = pow((srgb[i] + 0.055) / 1.055, 2.4); }
    }
    return lin;
}

float3 hslSecondary_linearToSrgb(float3 lin)
{
    float3 srgb;
    for (int i = 0; i < 3; i++)
    {
        if (lin[i] <= 0.0031308) { srgb[i] = lin[i] * 12.92; }
        else { srgb[i] = 1.055 * pow(lin[i], 1.0 / 2.4) - 0.055; }
    }
    return srgb;
}

float3 hslSecondary_rgbToHsl(float3 rgb)
{
    float maxC = max(max(rgb.r, rgb.g), rgb.b);
    float minC = min(min(rgb.r, rgb.g), rgb.b);
    float delta = maxC - minC;

    float l = (maxC + minC) * 0.5;

    float h = 0.0;
    float s = 0.0;

    if (delta > 0.001)
    {
        if (l > 0.5) { s = delta / (2.0 - maxC - minC); }
        else { s = delta / (maxC + minC); }

        if (maxC == rgb.r)
        {
            h = (rgb.g - rgb.b) / delta;
            if (rgb.g < rgb.b) { h += 6.0; }
        }
        else if (maxC == rgb.g)
        {
            h = (rgb.b - rgb.r) / delta + 2.0;
        }
        else
        {
            h = (rgb.r - rgb.g) / delta + 4.0;
        }
        h /= 6.0;
    }

    return float3(h, s, l);
}

float3 hslSecondary_hslToRgb(float3 hsl)
{
    float h = hsl.x;
    float s = hsl.y;
    float l = hsl.z;

    if (s < 0.001) { return float3(l, l, l); }

    float q;
    if (l < 0.5) { q = l * (1.0 + s); }
    else { q = l + s - l * s; }
    float p = 2.0 * l - q;

    float3 rgb;
    for (int i = 0; i < 3; i++)
    {
        float t = h + (1.0 - (float)i) / 3.0;
        t = frac(t);

        if (t < 1.0 / 6.0) { rgb[i] = p + (q - p) * 6.0 * t; }
        else if (t < 0.5) { rgb[i] = q; }
        else if (t < 2.0 / 3.0) { rgb[i] = p + (q - p) * (2.0 / 3.0 - t) * 6.0; }
        else { rgb[i] = p; }
    }

    return rgb;
}

float hslSecondary_computeHslKey(float3 hsl, float hueCenter, float hueRange,
                                 float satMin, float satMax, float lumMin, float lumMax, float feather)
{
    float hueDist = abs(hsl.x - hueCenter);
    hueDist = min(hueDist, 1.0 - hueDist);

    float hueKey = 1.0 - smoothstep(hueRange - feather, hueRange + feather, hueDist);

    float satKey = smoothstep(satMin - feather, satMin + feather, hsl.y) *
                   (1.0 - smoothstep(satMax - feather, satMax + feather, hsl.y));

    float lumKey = smoothstep(lumMin - feather, lumMin + feather, hsl.z) *
                   (1.0 - smoothstep(lumMax - feather, lumMax + feather, hsl.z));

    return hueKey * satKey * lumKey;
}

float3 hslSecondary_applyHslCorrection(float3 hsl, float hueShift, float satAdjust, float lumAdjust)
{
    float3 corrected = hsl;
    corrected.x = frac(corrected.x + hueShift);
    corrected.y = clamp(corrected.y + satAdjust, 0.0, 1.0);
    corrected.z = clamp(corrected.z + lumAdjust * 0.5, 0.0, 1.0);
    return corrected;
}

float4 frag_hslSecondary(NMVaryings i) : SV_Target
{
    uint w, h;
    inputTex.GetDimensions(w, h);
    float2 texSize = float2((float)w, (float)h);
    float2 uv = NM_FragCoord(i) / texSize;
    float4 color = inputTex.Sample(sampler_inputTex, uv);

    if (hslEnable == 0)
    {
        return color;
    }

    float3 rgb = hslSecondary_srgbToLinear(color.rgb);
    float3 hsl = hslSecondary_rgbToHsl(rgb);

    float matte = hslSecondary_computeHslKey(hsl, hslHueCenter, hslHueRange,
                                             hslSatMin, hslSatMax,
                                             hslLumMin, hslLumMax,
                                             hslFeather);

    float3 correctedHsl = hslSecondary_applyHslCorrection(hsl, hslHueShift,
                                                          hslSatAdjust, hslLumAdjust);
    float3 correctedRgb = hslSecondary_hslToRgb(correctedHsl);

    rgb = lerp(rgb, correctedRgb, matte);

    rgb = hslSecondary_linearToSrgb(max(rgb, float3(0.0, 0.0, 0.0)));

    return float4(rgb, color.a);
}

// =============================================================================
// PASS 5: "lut" — verbatim from lut.wgsl
// (textureLoad: integer-coord fetch, NO sampler — uses inputTex.Load)
// =============================================================================

float3 lut_srgbToLinear(float3 srgb)
{
    float3 lin;
    for (int i = 0; i < 3; i++)
    {
        if (srgb[i] <= 0.04045) { lin[i] = srgb[i] / 12.92; }
        else { lin[i] = pow((srgb[i] + 0.055) / 1.055, 2.4); }
    }
    return lin;
}

float3 lut_linearToSrgb(float3 lin)
{
    float3 srgb;
    for (int i = 0; i < 3; i++)
    {
        if (lin[i] <= 0.0031308) { srgb[i] = lin[i] * 12.92; }
        else { srgb[i] = 1.055 * pow(lin[i], 1.0 / 2.4) - 0.055; }
    }
    return srgb;
}

float3 lut_rgbToHsl(float3 rgb)
{
    float maxC = max(max(rgb.r, rgb.g), rgb.b);
    float minC = min(min(rgb.r, rgb.g), rgb.b);
    float delta = maxC - minC;
    float l = (maxC + minC) * 0.5;
    float h = 0.0;
    float s = 0.0;
    if (delta > 0.001)
    {
        // select(delta/(maxC+minC), delta/(2-maxC-minC), l>0.5)
        s = (l > 0.5) ? (delta / (2.0 - maxC - minC)) : (delta / (maxC + minC));
        if (maxC == rgb.r)
        {
            // select(0.0, 6.0, rgb.g < rgb.b)
            h = (rgb.g - rgb.b) / delta + ((rgb.g < rgb.b) ? 6.0 : 0.0);
        }
        else if (maxC == rgb.g)
        {
            h = (rgb.b - rgb.r) / delta + 2.0;
        }
        else
        {
            h = (rgb.r - rgb.g) / delta + 4.0;
        }
        h /= 6.0;
    }
    return float3(h, s, l);
}

float lut_hue2rgb(float p, float q, float t_in)
{
    float t = t_in;
    if (t < 0.0) { t += 1.0; }
    if (t > 1.0) { t -= 1.0; }
    if (t < 1.0 / 6.0) { return p + (q - p) * 6.0 * t; }
    if (t < 1.0 / 2.0) { return q; }
    if (t < 2.0 / 3.0) { return p + (q - p) * (2.0 / 3.0 - t) * 6.0; }
    return p;
}

float3 lut_hslToRgb(float3 hsl)
{
    if (hsl.y == 0.0) { return float3(hsl.z, hsl.z, hsl.z); }
    // select(z+y-z*y, z*(1+y), z<0.5)
    float q = (hsl.z < 0.5) ? (hsl.z * (1.0 + hsl.y)) : (hsl.z + hsl.y - hsl.z * hsl.y);
    float p = 2.0 * hsl.z - q;
    return float3(
        lut_hue2rgb(p, q, hsl.x + 1.0 / 3.0),
        lut_hue2rgb(p, q, hsl.x),
        lut_hue2rgb(p, q, hsl.x - 1.0 / 3.0)
    );
}

float lut_luma(float3 rgb) { return dot(rgb, float3(0.2126, 0.7152, 0.0722)); }

float3 lutTealOrange(float3 rgb)
{
    float l = lut_luma(rgb);
    float3 teal = float3(0.0, 0.5, 0.6);
    float3 orange = float3(1.0, 0.6, 0.3);
    float3 graded = lerp(teal, orange, l);
    float3 hsl = lut_rgbToHsl(rgb);
    float3 gradedHsl = lut_rgbToHsl(graded);
    gradedHsl.y = lerp(gradedHsl.y, hsl.y, 0.5);
    return lut_hslToRgb(gradedHsl);
}

float3 lutWarmFilm(float3 rgb_in)
{
    float3 rgb = rgb_in * 0.95 + 0.05;
    rgb.r = pow(rgb.r, 0.95);
    rgb.b = pow(rgb.b, 1.05);
    float l = lut_luma(rgb);
    rgb.g = lerp(rgb.g * 0.95, rgb.g, l);
    rgb = rgb * rgb * (3.0 - 2.0 * rgb);
    return rgb;
}

float3 lutCoolShadows(float3 rgb_in)
{
    float3 rgb = rgb_in;
    float l = lut_luma(rgb);
    float3 coolBlue = float3(0.4, 0.5, 0.7);
    float shadowMask = 1.0 - smoothstep(0.0, 0.5, l);
    rgb = lerp(rgb, coolBlue * l * 2.0, shadowMask * 0.4);
    return rgb;
}

float3 lutBleachBypass(float3 rgb_in)
{
    float3 rgb = rgb_in;
    float l = lut_luma(rgb);
    float3 desat = float3(l, l, l);
    rgb = lerp(rgb, desat, 0.5);
    rgb = (rgb - 0.5) * 1.3 + 0.5;
    rgb.r *= 1.02;
    rgb.b *= 0.98;
    return clamp(rgb, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

float3 lutCrossProcess(float3 rgb_in)
{
    float3 rgb = rgb_in;
    rgb.r = pow(rgb.r, 0.9);
    rgb.g = pow(rgb.g, 1.0);
    rgb.b = pow(rgb.b, 1.2);
    float l = lut_luma(rgb);
    rgb.r += (1.0 - l) * -0.1 + l * 0.1;
    rgb.g += (1.0 - l) * 0.05;
    rgb.b += (1.0 - l) * 0.1 + l * -0.15;
    float3 hsl = lut_rgbToHsl(rgb);
    hsl.y *= 1.2;
    rgb = lut_hslToRgb(hsl);
    return clamp(rgb, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

float3 lutCinematic(float3 rgb_in)
{
    float3 rgb = rgb_in;
    float l = lut_luma(rgb);
    rgb = rgb * 0.9 + 0.03;
    float3 shadowTintC = float3(0.95, 1.0, 1.05);
    float3 highlightTintC = float3(1.05, 1.0, 0.95);
    rgb *= lerp(shadowTintC, highlightTintC, l);
    rgb = pow(rgb, float3(1.1, 1.1, 1.1));
    return clamp(rgb, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

float3 lutDayForNight(float3 rgb_in)
{
    float3 rgb = rgb_in;
    rgb.r *= 0.5;
    rgb.g *= 0.6;
    rgb.b *= 1.0;
    rgb *= 0.4;
    rgb = lerp(float3(lut_luma(rgb), lut_luma(rgb), lut_luma(rgb)), rgb, 0.7);
    return rgb;
}

float3 lutVintage(float3 rgb_in)
{
    float3 rgb = rgb_in * 0.85 + 0.08;
    rgb.r = pow(rgb.r, 0.95);
    rgb.b = pow(rgb.b, 1.1);
    float3 hsl = lut_rgbToHsl(rgb);
    hsl.y *= 0.7;
    rgb = lut_hslToRgb(hsl);
    return clamp(rgb, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

float3 lutNoir(float3 rgb_in)
{
    float l = lut_luma(rgb_in);
    float contrastV = (l - 0.5) * 1.5 + 0.5;
    float3 blue = float3(0.9, 0.95, 1.0);
    float3 rgb = float3(contrastV, contrastV, contrastV) * lerp(blue, float3(1.0, 1.0, 1.0), contrastV);
    return clamp(rgb, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

float3 lutSepia(float3 rgb_in)
{
    float l = lut_luma(rgb_in);
    float3 sepia = float3(1.0, 0.89, 0.71);
    float3 rgb = l * sepia;
    rgb = rgb * 0.9 + 0.05;
    return clamp(rgb, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

float3 lutInfrared(float3 rgb_in)
{
    float l = lut_luma(rgb_in);
    float3 rgb = rgb_in;
    rgb.r = pow(l, 0.7);
    rgb.g = rgb_in.g * 0.3;
    rgb.b = 1.0 - l;
    float foliage = smoothstep(0.2, 0.6, rgb_in.g) * (1.0 - abs(rgb_in.r - rgb_in.b));
    rgb.r = lerp(rgb.r, 1.0, foliage * 0.7);
    return clamp(rgb, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

float3 lutTechnicolor(float3 rgb_in)
{
    float3 rgb = rgb_in;
    rgb.r = pow(rgb.r, 0.85) * 1.1;
    rgb.g = pow(rgb.g, 1.0) * 0.95;
    rgb.b = pow(rgb.b, 0.9) * 1.05;
    float3 hsl = lut_rgbToHsl(rgb);
    hsl.y = min(hsl.y * 1.4, 1.0);
    rgb = lut_hslToRgb(hsl);
    rgb = (rgb - 0.5) * 1.15 + 0.5;
    return clamp(rgb, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

float3 lutNeon(float3 rgb_in)
{
    float3 rgb = rgb_in;
    float3 hsl = lut_rgbToHsl(rgb);
    hsl.x = frac(hsl.x + 0.05);
    hsl.y = min(hsl.y * 1.8, 1.0);
    rgb = lut_hslToRgb(hsl);
    rgb = (rgb - 0.5) * 1.4 + 0.5;
    rgb.r = pow(max(rgb.r, 0.0), 0.9);
    rgb.b = pow(max(rgb.b, 0.0), 0.85);
    return clamp(rgb, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

float3 lutMatrix(float3 rgb_in)
{
    float l = lut_luma(rgb_in);
    float boosted = pow(l, 0.8);
    float3 rgb = float3(boosted * 0.2, boosted, boosted * 0.15);
    rgb += float3(0.0, 0.02, 0.0);
    return clamp(rgb, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

float3 lutUnderwater(float3 rgb_in)
{
    float3 rgb = rgb_in;
    rgb.r *= 0.5;
    rgb.g = pow(rgb.g, 0.9) * 0.9;
    rgb.b = pow(rgb.b, 0.85) * 1.1;
    float depth = 1.0 - lut_luma(rgb_in) * 0.3;
    rgb = lerp(rgb, rgb * float3(0.4, 0.7, 1.0), 0.3 * depth);
    return clamp(rgb, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

float3 lutSunset(float3 rgb_in)
{
    float3 rgb = rgb_in;
    float l = lut_luma(rgb_in);
    float warmth = smoothstep(0.3, 0.7, l);
    float3 sunset = lerp(float3(1.0, 0.3, 0.5), float3(1.0, 0.8, 0.4), warmth);
    rgb = lerp(rgb * sunset, rgb, 0.4);
    rgb.r = pow(rgb.r, 0.9);
    return clamp(rgb, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

float3 lutMonochrome(float3 rgb_in)
{
    float l = lut_luma(rgb_in);
    float contrastV = (l - 0.5) * 1.2 + 0.5;
    return clamp(float3(contrastV, contrastV, contrastV), float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

float3 lutPsychedelic(float3 rgb_in)
{
    float3 hsl = lut_rgbToHsl(rgb_in);
    hsl.x = frac(hsl.x * 3.0 + hsl.z * 0.5);
    hsl.y = min(hsl.y * 2.0, 1.0);
    hsl.z = (hsl.z - 0.5) * 1.3 + 0.5;
    float3 rgb = lut_hslToRgb(hsl);
    return clamp(rgb, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

float3 lutHardLight(float3 rgb_in)
{
    float l = lut_luma(rgb_in);

    float3 result;
    result.r = (rgb_in.r < 0.5) ? (2.0 * rgb_in.r * l) : (1.0 - 2.0 * (1.0 - rgb_in.r) * (1.0 - l));
    result.g = (rgb_in.g < 0.5) ? (2.0 * rgb_in.g * l) : (1.0 - 2.0 * (1.0 - rgb_in.g) * (1.0 - l));
    result.b = (rgb_in.b < 0.5) ? (2.0 * rgb_in.b * l) : (1.0 - 2.0 * (1.0 - rgb_in.b) * (1.0 - l));

    result = (result - 0.5) * 1.4 + 0.5;

    float highlightMask = smoothstep(0.5, 1.0, l);
    result.b += highlightMask * 0.05;

    return clamp(result, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

float3 lutPosterize(float3 rgb_in)
{
    float l = lut_luma(rgb_in);

    float levels = 6.0;
    float quantized = floor(l * levels + 0.5) / levels;

    float3 ramp;
    if (quantized < 0.2) { ramp = float3(0.1, 0.05, 0.15); }
    else if (quantized < 0.4) { ramp = float3(0.3, 0.2, 0.4); }
    else if (quantized < 0.6) { ramp = float3(0.5, 0.4, 0.6); }
    else if (quantized < 0.8) { ramp = float3(0.8, 0.6, 0.5); }
    else { ramp = float3(1.0, 0.9, 0.8); }

    float3 hsl = lut_rgbToHsl(rgb_in);
    float3 rampHsl = lut_rgbToHsl(ramp);
    rampHsl.x = lerp(rampHsl.x, hsl.x, 0.3);

    return lut_hslToRgb(rampHsl);
}

float3 lutSolarize(float3 rgb_in)
{
    float l = lut_luma(rgb_in);

    float threshold = 0.5;
    float3 result;
    result.r = (rgb_in.r <= threshold) ? (2.0 * rgb_in.r) : (2.0 * (1.0 - rgb_in.r));
    result.g = (rgb_in.g <= threshold) ? (2.0 * rgb_in.g) : (2.0 * (1.0 - rgb_in.g));
    result.b = (rgb_in.b <= threshold) ? (2.0 * rgb_in.b) : (2.0 * (1.0 - rgb_in.b));

    float3 hsl = lut_rgbToHsl(result);
    hsl.y = min(hsl.y * 1.5, 1.0);
    result = lut_hslToRgb(hsl);

    result = (result - 0.5) * 1.1 + 0.5;

    return clamp(result, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

float4 frag_lut(NMVaryings i) : SV_Target
{
    // WGSL: let coord = vec2i(fragCoord.xy); textureLoad(inputTex, coord, 0);
    float2 fragCoord = NM_FragCoord(i);
    int2 coord = (int2)fragCoord;
    float4 color = inputTex.Load(int3(coord, 0));

    if (preset == 0 || alpha <= 0.0)
    {
        return color;
    }

    float3 rgb = lut_srgbToLinear(color.rgb);
    float3 graded = rgb;

    if (preset == 1) { graded = lutTealOrange(rgb); }
    else if (preset == 2) { graded = lutWarmFilm(rgb); }
    else if (preset == 3) { graded = lutCoolShadows(rgb); }
    else if (preset == 4) { graded = lutBleachBypass(rgb); }
    else if (preset == 5) { graded = lutCrossProcess(rgb); }
    else if (preset == 6) { graded = lutCinematic(rgb); }
    else if (preset == 7) { graded = lutDayForNight(rgb); }
    else if (preset == 8) { graded = lutVintage(rgb); }
    else if (preset == 9) { graded = lutNoir(rgb); }
    else if (preset == 10) { graded = lutSepia(rgb); }
    else if (preset == 11) { graded = lutInfrared(rgb); }
    else if (preset == 12) { graded = lutTechnicolor(rgb); }
    else if (preset == 13) { graded = lutNeon(rgb); }
    else if (preset == 14) { graded = lutMatrix(rgb); }
    else if (preset == 15) { graded = lutUnderwater(rgb); }
    else if (preset == 16) { graded = lutSunset(rgb); }
    else if (preset == 17) { graded = lutMonochrome(rgb); }
    else if (preset == 18) { graded = lutPsychedelic(rgb); }
    else if (preset == 20) { graded = lutHardLight(rgb); }
    else if (preset == 21) { graded = lutPosterize(rgb); }
    else if (preset == 22) { graded = lutSolarize(rgb); }

    rgb = lerp(rgb, graded, alpha);
    rgb = lut_linearToSrgb(max(rgb, float3(0.0, 0.0, 0.0)));

    return float4(rgb, color.a);
}

// =============================================================================
// PASS 6: "vignette" — verbatim from vignette.wgsl
// =============================================================================

float3 vignette_srgbToLinear(float3 srgb)
{
    float3 lin;
    for (int i = 0; i < 3; i++)
    {
        if (srgb[i] <= 0.04045) { lin[i] = srgb[i] / 12.92; }
        else { lin[i] = pow((srgb[i] + 0.055) / 1.055, 2.4); }
    }
    return lin;
}

float3 vignette_linearToSrgb(float3 lin)
{
    float3 srgb;
    for (int i = 0; i < 3; i++)
    {
        if (lin[i] <= 0.0031308) { srgb[i] = lin[i] * 12.92; }
        else { srgb[i] = 1.055 * pow(lin[i], 1.0 / 2.4) - 0.055; }
    }
    return srgb;
}

float vignette_computeVignette(float2 uv, float2 aspectRatioV, float midpoint,
                               float roundness, float feather)
{
    float2 centered = uv - 0.5;

    float2 scale;
    if (roundness > 0.0)
    {
        scale = lerp(aspectRatioV, float2(1.0, 1.0), roundness);
    }
    else
    {
        scale = lerp(aspectRatioV, aspectRatioV * float2(1.0 + abs(roundness), 1.0 - abs(roundness) * 0.5), -roundness);
    }

    centered *= scale;

    float dist = length(centered) * 2.0;

    float inner = midpoint - feather * 0.5;
    float outer = midpoint + feather * 0.5;

    return 1.0 - smoothstep(inner, outer, dist);
}

float3 vignette_applyVignette(float3 rgb, float vignetteMask, float amount, float highlightProtect)
{
    if (abs(amount) < 0.001) { return rgb; }

    float darken = 1.0 - (1.0 - vignetteMask) * abs(amount);

    if (highlightProtect > 0.0)
    {
        float luma = dot(rgb, LUMA_WEIGHTS);
        float protection = smoothstep(0.5, 1.0, luma) * highlightProtect;
        darken = lerp(darken, 1.0, protection);
    }

    if (amount > 0.0)
    {
        return rgb * darken;
    }
    else
    {
        return 1.0 - (1.0 - rgb) * darken;
    }
}

float4 frag_vignette(NMVaryings i) : SV_Target
{
    uint w, h;
    inputTex.GetDimensions(w, h);
    float2 texSize = float2((float)w, (float)h);
    float2 uv = NM_FragCoord(i) / texSize;
    float4 color = inputTex.Sample(sampler_inputTex, uv);

    if (abs(vignetteAmount) < 0.001)
    {
        return color;
    }

    float3 rgb = vignette_srgbToLinear(color.rgb);

    float2 aspectRatioV;
    if (texSize.x > texSize.y)
    {
        aspectRatioV = float2(texSize.x / texSize.y, 1.0);
    }
    else
    {
        aspectRatioV = float2(1.0, texSize.y / texSize.x);
    }

    float vignetteMask = vignette_computeVignette(uv, aspectRatioV, vignetteMidpoint,
                                                  vignetteRoundness, vignetteFeather);

    rgb = vignette_applyVignette(rgb, vignetteMask, vignetteAmount, vigHiProtect);

    rgb = vignette_linearToSrgb(max(rgb, float3(0.0, 0.0, 0.0)));

    return float4(rgb, color.a);
}

#endif // NM_EFFECT_GRADE_INCLUDED
