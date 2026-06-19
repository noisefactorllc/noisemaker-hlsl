#ifndef NM_INVERT_SG_INCLUDED
#define NM_INVERT_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Invert.hlsl
//
// Shader Graph Custom Function wrapper for filter/invert. Drops the effect in as
// a node: add a Custom Function node, point it at this file, select
// NM_Invert_float, and wire the InputTex/SS/UV inputs. Outputs RGBA.
//
// filter/invert has NO per-effect parameters (definition.js globals: {}), so the
// only inputs are the source texture + sampler + UV. The node samples InputTex at
// UV and returns the inverted color (1 - rgb, alpha kept), matching the WGSL.
// =============================================================================

#include "../../Shaders/Effects/filter/Invert.hlsl"

// InputTex : source surface to invert
// SS       : sampler state (bilinear, clamp, linear/non-sRGB) for InputTex
// UV       : 0..1 fragment UV (top-left origin, WGSL convention)
void NM_Invert_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    out float4        Out)
{
    float4 color = InputTex.Sample(SS, UV);
    Out = nm_invert(color);
}

#endif // NM_INVERT_SG_INCLUDED
