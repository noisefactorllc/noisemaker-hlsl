#ifndef NM_HS_SG_INCLUDED
#define NM_HS_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Hs.hlsl
//
// Shader Graph Custom Function wrapper for filter/hs. Add a Custom Function
// node, point it at this file, select NM_Hs_float, and wire the inputs.
// Outputs RGBA.
//
// filter/hs parameters (definition.js globals):
//   rotation   : float, hue rotation in degrees, default 0,   range [-180, 180]
//   hueRange   : float, hue range scale,          default 100, range [0, 200]
//   saturation : float, saturation multiplier,    default 1,   range [0, 4]
// =============================================================================

#include "../../Shaders/Effects/filter/Hs.hlsl"

// InputTex  : source surface
// SS        : sampler state (bilinear, clamp, linear/non-sRGB)
// UV        : 0..1 fragment UV (top-left origin, WGSL convention)
// Rotation  : hue rotation degrees
// HueRange  : hue range scale
// Saturation: saturation multiplier
void NM_Hs_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             Rotation,
    float             HueRange,
    float             Saturation,
    out float4        Out)
{
    // Bind wrapper-local values into the uniform names nm_hs() reads.
    rotation   = Rotation;
    hueRange   = HueRange;
    saturation = Saturation;

    float4 color = InputTex.Sample(SS, UV);
    Out = nm_hs(color);
}

#endif // NM_HS_SG_INCLUDED
