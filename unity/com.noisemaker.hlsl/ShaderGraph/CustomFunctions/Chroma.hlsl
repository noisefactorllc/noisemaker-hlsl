#ifndef NM_CHROMA_SG_INCLUDED
#define NM_CHROMA_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Chroma.hlsl
//
// Shader Graph Custom Function wrapper for filter/chroma. Add a Custom Function
// node, point it at this file, select NM_Chroma_float, and wire the inputs.
// Outputs RGBA mono mask (rgb = chroma mask, alpha kept).
//
// Inputs:
//   InputTex  — source surface to isolate hue from
//   SS        — sampler state (bilinear, clamp, linear/non-sRGB) for InputTex
//   UV        — 0..1 fragment UV (top-left origin, WGSL convention)
//   TargetHue — target hue in [0,1], default 0.33
//   Range     — hue acceptance half-width in [0,0.5], default 0.25
//   Feather   — feathering width in [0,0.25], default 0.05
// =============================================================================

#include "../../Shaders/Effects/filter/Chroma.hlsl"

void NM_Chroma_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             TargetHue,
    float             Range,
    float             Feather,
    out float4        Out)
{
    // Map Shader Graph inputs to the effect's globals so nm_chroma() can read them.
    targetHue = TargetHue;
    range     = Range;
    feather   = Feather;

    float4 color = InputTex.Sample(SS, UV);
    Out = nm_chroma(color);
}

#endif // NM_CHROMA_SG_INCLUDED
