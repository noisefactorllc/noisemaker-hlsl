#ifndef NM_SG_CHROMATICABERRATION_INCLUDED
#define NM_SG_CHROMATICABERRATION_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for filter/chromaticAberration.
//
// Drops the effect into Shader Graph as a node. Each global param from
// definition.js maps to a named input:
//   aberration -> AberrationAmt (float, uniform aberrationAmt) [0,100] default 50
//   passthru   -> Passthru      (float)                        [0,100] default 50
//
// UV must be the full-resolution normalized UV:
//   UV = (fragCoord + tileOffset) / fullResolution
// The caller must supply FullResolution (full canvas size) and TileOffset.
// The input texture dimensions are derived internally via GetDimensions.
//
// Self-contained: does NOT include NMFullscreen.hlsl / NMCore.hlsl.
// Helpers are mirrored VERBATIM from ChromaticAberration.hlsl, name-prefixed
// `nmsg_ca_` to avoid symbol clashes with the runtime include.
// =============================================================================

static const float NMSG_CA_PI = 3.14159265359;

// mapVal — verbatim from WGSL mapVal().
float nmsg_ca_mapVal(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

// Shader Graph Custom Function entry.
// UV        : global normalized UV = (fragCoord + tileOffset) / fullResolution
// FragCoord : fragCoord.xy (pixel-centered, top-left)
// FullResolution : full canvas size in pixels
// TileOffset     : tile offset in pixels (0,0 if untiled)
// TODO(verify): SS must be clamp/linear/non-sRGB to match runtime (H7).
void NM_ChromaticAberration_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float2            FragCoord,
    float2            FullResolution,
    float2            TileOffset,
    float             AberrationAmt,
    float             Passthru,
    out float4        Out)
{
    float texW, texH;
    InputTex.tex.GetDimensions(texW, texH);
    float2 texSize = float2(texW, texH);

    // uv is already the global normalized UV passed in
    float2 uv = UV;

    // Aspect-corrected distance from center
    float ar = FullResolution.x / FullResolution.y;
    float2 diff = float2(0.5 * ar, 0.5) - float2(uv.x * ar, uv.y);
    float centerDist = length(diff);

    float aberrationOffset = nmsg_ca_mapVal(AberrationAmt, 0.0, 100.0, 0.0, 0.05)
                             * centerDist * NMSG_CA_PI * 0.5;

    // Red — shifted right
    float redOffset = lerp(clamp(uv.x + aberrationOffset, 0.0, 1.0), uv.x, uv.x);
    float2 redUV    = (float2(redOffset, uv.y) * FullResolution - TileOffset) / texSize;
    float4 red      = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, redUV);

    // Green — unshifted (fragCoord.xy / texSize)
    float4 green = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, FragCoord / texSize);

    // Blue — shifted left
    float blueOffset = lerp(uv.x, clamp(uv.x - aberrationOffset, 0.0, 1.0), uv.x);
    float2 blueUV    = (float2(blueOffset, uv.y) * FullResolution - TileOffset) / texSize;
    float4 blue      = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, blueUV);

    float3 aberrated = float3(red.r, green.g, blue.b);
    float3 edges     = aberrated - green.rgb;
    float3 original  = green.rgb * nmsg_ca_mapVal(Passthru, 0.0, 100.0, 0.0, 2.0);

    Out = float4(min(edges + original, float3(1.0, 1.0, 1.0)), green.a);
}

#endif // NM_SG_CHROMATICABERRATION_INCLUDED
