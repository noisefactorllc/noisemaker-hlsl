#ifndef NM_SKEW_SG_INCLUDED
#define NM_SKEW_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Skew.hlsl
//
// Shader Graph Custom Function wrapper for filter/skew. Add a Custom Function
// node, point it at this file, select NM_Skew_float, and wire the inputs.
//
// InputTex : source surface to transform
// SS       : sampler state (bilinear, clamp, linear/non-sRGB)
// UV       : 0..1 fragment UV (top-left origin, WGSL convention)
// SkewAmt  : skew amount (default 0.25, range [-1, 1])
// Rotation : rotation in degrees (default 0, range [-180, 180])
// Wrap     : wrap mode — 0=clamp, 1=mirror, 2=repeat (default 1)
//
// NOTE: The Shader Graph wrapper samples at `UV * texSize` to produce the
// pixel-center fragCoord expected by nm_skew. Wrap and rotation operate in
// the INPUT TEXTURE's own UV space, matching the WGSL exactly.
// =============================================================================

#include "../../Shaders/Effects/filter/Skew.hlsl"

void NM_Skew_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             SkewAmt,
    float             Rotation,
    int               Wrap,
    out float4        Out)
{
    // Map the Shader Graph parameters to the uniforms nm_skew reads.
    skewAmt  = SkewAmt;
    rotation = Rotation;
    wrap     = Wrap;

    // Reconstruct pixel-center fragCoord from UV and texture dimensions.
    uint tw, th;
    InputTex.tex.GetDimensions(tw, th);
    float2 fragCoord = UV * float2(tw, th);

    Out = nm_skew(fragCoord, InputTex.tex, SS.samplerstate);
}

#endif // NM_SKEW_SG_INCLUDED
