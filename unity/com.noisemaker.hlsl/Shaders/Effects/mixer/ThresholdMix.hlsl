#ifndef NM_THRESHOLDMIX_INCLUDED
#define NM_THRESHOLDMIX_INCLUDED

// =============================================================================
// ThresholdMix.hlsl — mixer/thresholdMix, ported PIXEL-IDENTICALLY from the
// canonical WGSL: shaders/effects/mixer/thresholdMix/wgsl/thresholdMix.wgsl
//
// Combines two input textures using threshold masking with optional
// posterization. Supports luminance-based or per-channel RGB thresholding.
//
// Single render pass (definition.js passes[0], program "thresholdMix").
//
// PORTING NOTES:
//  * getLuminosity / quantizeValue / calculateBlendFactor are this effect's OWN
//    helpers, ported VERBATIM inline (golden rule 2). No NMCore substitution.
//  * uv = position.xy / dims where dims = textureDimensions(inputTex, 0).
//    The SAME uv samples BOTH inputTex and tex (the WGSL derives one uv from
//    inputTex's dimensions and uses it for both samples).
//  * mode / quantize: int uniforms, branched with plain if() (WGSL style).
//  * quantize branch: WGSL checks (quantize > 0) before calling quantizeValue,
//    and quantizeValue itself also guards (bands <= 0). Both guards reproduced.
//  * range <= 0.0: hard step(); range > 0: smoothstep(lower, upper, mapValue).
//  * Alpha channel in RGB mode: mix(colorA.w, colorB.w, (blendR+blendG+blendB)/3.0)
//    reproduced VERBATIM (not clamped, not averaged differently).
//  * No PRNG / no atan2 / no nm_mod in this effect — no bit hazards.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) ------------
int   mode;        // globals.mode.uniform      "mode",       default 0 (luminance)
int   quantize;    // globals.quantize.uniform  "quantize",   default 0
int   mapSource;   // globals.mapSource.uniform "mapSource",  default 1 (sourceB)
float threshold;   // globals.threshold.uniform "threshold",  default 0.5
float range;       // globals.range.uniform     "range",      default 0
float thresholdR;  // globals.thresholdR.uniform "thresholdR", default 0.5
float rangeR;      // globals.rangeR.uniform    "rangeR",     default 0
float thresholdG;  // globals.thresholdG.uniform "thresholdG", default 0.5
float rangeG;      // globals.rangeG.uniform    "rangeG",     default 0
float thresholdB;  // globals.thresholdB.uniform "thresholdB", default 0.5
float rangeB;      // globals.rangeB.uniform    "rangeB",     default 0

// -----------------------------------------------------------------------------
// getLuminosity — ported VERBATIM from thresholdMix.wgsl. Per-effect copy.
// WGSL: return dot(color, vec3f(0.299, 0.587, 0.114));
// -----------------------------------------------------------------------------
float getLuminosity(float3 color)
{
    return dot(color, float3(0.299, 0.587, 0.114));
}

// -----------------------------------------------------------------------------
// quantizeValue — ported VERBATIM from thresholdMix.wgsl. Per-effect copy.
// WGSL:
//   if (bands <= 0) { return value; }
//   let numBands = f32(bands);
//   return floor(value * numBands) / numBands;
// -----------------------------------------------------------------------------
float quantizeValue(float value, int bands)
{
    if (bands <= 0) {
        return value;
    }
    float numBands = (float)bands;
    return floor(value * numBands) / numBands;
}

// -----------------------------------------------------------------------------
// calculateBlendFactor — ported VERBATIM from thresholdMix.wgsl. Per-effect copy.
// WGSL:
//   if (rng <= 0.0) { return step(thresh, mapValue); }
//   else {
//     let lower = thresh;
//     let upper = thresh + rng;
//     return smoothstep(lower, upper, mapValue);
//   }
// -----------------------------------------------------------------------------
float calculateBlendFactor(float mapValue, float thresh, float rng)
{
    if (rng <= 0.0) {
        // Hard threshold
        return step(thresh, mapValue);
    } else {
        // Soft threshold with range
        float lower = thresh;
        float upper = thresh + rng;
        return smoothstep(lower, upper, mapValue);
    }
}

// -----------------------------------------------------------------------------
// nm_thresholdMix — core per-pixel evaluation. Takes the two already-sampled
// input colors (colorA = inputTex, colorB = tex) and returns the composited RGBA.
// Ported VERBATIM from thresholdMix.wgsl main() lines 59-91.
// -----------------------------------------------------------------------------
float4 nm_thresholdMix(float4 colorA, float4 colorB)
{
    // Get map color based on mapSource
    float3 mapColor;
    if (mapSource == 0) {
        mapColor = colorA.rgb;
    } else {
        mapColor = colorB.rgb;
    }

    // Apply quantization to map values if enabled
    if (quantize > 0) {
        mapColor.x = quantizeValue(mapColor.x, quantize);
        mapColor.y = quantizeValue(mapColor.y, quantize);
        mapColor.z = quantizeValue(mapColor.z, quantize);
    }

    float4 result;

    if (mode == 0) {
        // Luminance mode - use single threshold for all channels
        float lum = getLuminosity(mapColor);
        float blendFactor = calculateBlendFactor(lum, threshold, range);
        result = lerp(colorA, colorB, blendFactor);
    } else {
        // RGB mode - use separate threshold for each channel
        float blendR = calculateBlendFactor(mapColor.x, thresholdR, rangeR);
        float blendG = calculateBlendFactor(mapColor.y, thresholdG, rangeG);
        float blendB = calculateBlendFactor(mapColor.z, thresholdB, rangeB);

        result.x = lerp(colorA.x, colorB.x, blendR);
        result.y = lerp(colorA.y, colorB.y, blendG);
        result.z = lerp(colorA.z, colorB.z, blendB);
        result.w = lerp(colorA.w, colorB.w, (blendR + blendG + blendB) / 3.0);
    }

    return result;
}

#endif // NM_THRESHOLDMIX_INCLUDED
