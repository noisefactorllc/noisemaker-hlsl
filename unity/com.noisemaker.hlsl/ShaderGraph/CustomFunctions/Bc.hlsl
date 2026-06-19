#ifndef NM_BC_SG_INCLUDED
#define NM_BC_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Bc.hlsl
//
// Shader Graph Custom Function wrapper for filter/bc. Add a Custom Function
// node, point it at this file, select NM_Bc_float, and wire inputs. Outputs RGBA.
//
// Inputs:
//   InputTex  — source surface (Texture2D)
//   SS        — sampler state (bilinear, clamp, linear/non-sRGB)
//   UV        — 0..1 fragment UV (top-left origin, WGSL convention)
//   Brightness— float, default 1, range [0,10]
//   Contrast  — float, default 0.5, range [0,1]
// =============================================================================

#include "../../Shaders/Effects/filter/Bc.hlsl"

void NM_Bc_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             Brightness,
    float             Contrast,
    out float4        Out)
{
    // Bind uniforms to the names expected by nm_bc().
    brightness = Brightness;
    contrast   = Contrast;

    float4 color = InputTex.Sample(SS, UV);
    Out = nm_bc(color);
}

#endif // NM_BC_SG_INCLUDED
