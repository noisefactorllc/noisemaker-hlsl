#ifndef NM_DERIV_SG_INCLUDED
#define NM_DERIV_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Deriv.hlsl
//
// Shader Graph Custom Function wrapper for filter/deriv. Add a Custom Function
// node, point it at this file, select NM_Deriv_float, and wire the inputs.
//
// filter/deriv is SINGLE-PASS, so this SG wrapper is provided.
//
// InputTex : source surface
// SS       : sampler state (bilinear, clamp, linear/non-sRGB)
// UV       : 0..1 fragment UV (top-left origin, WGSL convention)
// Amount   : texel offset scale for derivative sampling (default 2.0)
// =============================================================================

#include "../../Shaders/Effects/filter/Deriv.hlsl"

void NM_Deriv_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             Amount,
    out float4        Out)
{
    // Override the uniform so nm_deriv picks it up.
    // (amount is a global uniform declared in Deriv.hlsl; in SG context we
    //  shadow it with the local assignment.)
    amount = Amount; // TODO(verify): confirm SG assigns the global before call
    uint tw, th;
    InputTex.tex.GetDimensions(tw, th);
    float2 texSize = float2(tw, th);
    Out = nm_deriv(InputTex.tex, SS.samplerstate, UV, texSize);
}

#endif // NM_DERIV_SG_INCLUDED
