#ifndef NM_SMOOTHSTEP_SG_INCLUDED
#define NM_SMOOTHSTEP_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Smoothstep.hlsl
//
// Shader Graph Custom Function wrapper for filter/smoothstep. Add a Custom
// Function node, point it at this file, select NM_Smoothstep_float, and wire
// the InputTex/SS/UV/Edge0/Edge1 inputs. Outputs RGBA.
//
// Samples InputTex at UV then applies smoothstep(edge0, edge1, rgb) per channel,
// alpha passed through — matching the WGSL exactly.
// =============================================================================

#include "../../Shaders/Effects/filter/Smoothstep.hlsl"

// InputTex : source surface
// SS       : sampler state (bilinear, clamp, linear/non-sRGB) for InputTex
// UV       : 0..1 fragment UV (top-left origin, WGSL convention)
// Edge0    : lower smoothstep threshold (default 0.0)
// Edge1    : upper smoothstep threshold (default 1.0)
void NM_Smoothstep_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             Edge0,
    float             Edge1,
    out float4        Out)
{
    // Drive the module-level uniforms so nm_smoothstep() picks them up.
    edge0 = Edge0;
    edge1 = Edge1;
    float4 color = InputTex.Sample(SS, UV);
    Out = nm_smoothstep(color);
}

#endif // NM_SMOOTHSTEP_SG_INCLUDED
