#ifndef NM_THRESHOLDMIX_SG_INCLUDED
#define NM_THRESHOLDMIX_SG_INCLUDED

// =============================================================================
// ThresholdMix.hlsl — Shader Graph Custom Function wrapper for mixer/thresholdMix.
//
// NOTE: This wrapper is provided for single-pixel / SG use. For full-texture
// effects the runtime ThresholdMix.shader + C# pipeline is the canonical path.
//
// All threshold/blend logic is reproduced inline here (no dependency on the
// render-pass .hlsl which declares global uniforms incompatible with SG).
// =============================================================================

void NM_ThresholdMix_float(
    UnityTexture2D  InputTex,
    UnitySamplerState SS,
    UnityTexture2D  Tex,
    float2          UV,
    int             Mode,
    int             Quantize,
    int             MapSource,
    float           Threshold,
    float           Range,
    float           ThresholdR,
    float           RangeR,
    float           ThresholdG,
    float           RangeG,
    float           ThresholdB,
    float           RangeB,
    out float4      Out)
{
    float4 colorA = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, UV);
    float4 colorB = SAMPLE_TEXTURE2D(Tex.tex,      SS.samplerstate, UV);

    // Get map color based on MapSource
    float3 mapColor;
    if (MapSource == 0) {
        mapColor = colorA.rgb;
    } else {
        mapColor = colorB.rgb;
    }

    // Apply quantization to map values if enabled
    if (Quantize > 0) {
        // quantizeValue inlined
        float numBands = (float)Quantize;
        mapColor.x = floor(mapColor.x * numBands) / numBands;
        mapColor.y = floor(mapColor.y * numBands) / numBands;
        mapColor.z = floor(mapColor.z * numBands) / numBands;
    }

    float4 result;

    if (Mode == 0) {
        // Luminance mode
        float lum = dot(mapColor, float3(0.299, 0.587, 0.114));
        float blendFactor;
        if (Range <= 0.0) {
            blendFactor = step(Threshold, lum);
        } else {
            blendFactor = smoothstep(Threshold, Threshold + Range, lum);
        }
        result = lerp(colorA, colorB, blendFactor);
    } else {
        // RGB mode
        float blendR, blendG, blendB;
        if (RangeR <= 0.0) { blendR = step(ThresholdR, mapColor.x); }
        else                { blendR = smoothstep(ThresholdR, ThresholdR + RangeR, mapColor.x); }
        if (RangeG <= 0.0) { blendG = step(ThresholdG, mapColor.y); }
        else                { blendG = smoothstep(ThresholdG, ThresholdG + RangeG, mapColor.y); }
        if (RangeB <= 0.0) { blendB = step(ThresholdB, mapColor.z); }
        else                { blendB = smoothstep(ThresholdB, ThresholdB + RangeB, mapColor.z); }

        result.x = lerp(colorA.x, colorB.x, blendR);
        result.y = lerp(colorA.y, colorB.y, blendG);
        result.z = lerp(colorA.z, colorB.z, blendB);
        result.w = lerp(colorA.w, colorB.w, (blendR + blendG + blendB) / 3.0);
    }

    Out = result;
}

#endif // NM_THRESHOLDMIX_SG_INCLUDED
