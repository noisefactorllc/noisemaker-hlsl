#ifndef NM_SIMPLEABERRATION_SG_INCLUDED
#define NM_SIMPLEABERRATION_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/SimpleAberration.hlsl
//
// Shader Graph Custom Function wrapper for filter/simpleAberration.
// Add a Custom Function node, point it at this file, select
// NM_SimpleAberration_float, and wire the inputs. Outputs RGBA float4.
//
// Inputs:
//   InputTex     — source texture (UnityTexture2D)
//   SS           — sampler state (bilinear, clamp, linear/non-sRGB)
//   UV           — 0..1 screen UV (top-left origin, WGSL convention)
//   Displacement — chromatic offset in UV space (default 0.02, range 0..0.1)
//
// NOTE: The `displacement` uniform in SimpleAberration.hlsl must be set to the
// Displacement parameter value before calling this function. In a Shader Graph
// context, set the global via Graph keywords or assign before the node evaluates.
// =============================================================================

#include "../../Shaders/Effects/filter/SimpleAberration.hlsl"

// InputTex     : source surface
// SS           : sampler state (bilinear, clamp, linear/non-sRGB)
// UV           : normalised screen UV (top-left, 0..1)
// Displacement : chromatic aberration offset in UV space
void NM_SimpleAberration_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             Displacement,
    out float4        Out)
{
    displacement = Displacement; // write the module-scope uniform before sampling
    Out = nm_simpleAberration(InputTex.tex, SS.samplerstate, UV);
}

#endif // NM_SIMPLEABERRATION_SG_INCLUDED
