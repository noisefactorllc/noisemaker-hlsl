#ifndef NM_EMBOSS_SG_INCLUDED
#define NM_EMBOSS_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Emboss.hlsl
//
// Shader Graph Custom Function wrapper for filter/emboss. Add a Custom Function
// node, point it at this file, select NM_Emboss_float, and wire inputs.
//
// Inputs:
//   InputTex — source surface
//   SS       — sampler state (bilinear, clamp, linear/non-sRGB)
//   UV       — 0..1 fragment UV (top-left origin, WGSL convention)
//   Amount   — emboss strength (definition.js globals.amount, default 1.0)
// Output:
//   Out      — RGBA with embossed RGB, original alpha
// =============================================================================

#include "../../Shaders/Effects/filter/Emboss.hlsl"

void NM_Emboss_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             Amount,
    out float4        Out)
{
    // Mirror the WGSL: texelSize = 1.0 / textureDimensions(inputTex)
    uint tw, th;
    InputTex.tex.GetDimensions(tw, th);
    float2 texSize   = float2(tw, th);
    float2 texelSize = 1.0 / texSize;

    float4 origColor = InputTex.Sample(SS, UV);

    // Temporarily override the global uniform so nm_emboss picks up the SG value.
    // TODO(verify): confirm the HLSL compiler resolves the 'amount' global from the
    // enclosing scope when called from a Custom Function node at runtime.
    amount = Amount;

    Out = nm_emboss(InputTex.tex, SS.samplerstate, UV, texelSize, origColor);
}

#endif // NM_EMBOSS_SG_INCLUDED
