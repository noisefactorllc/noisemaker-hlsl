#ifndef NM_CHANNEL_SG_INCLUDED
#define NM_CHANNEL_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Channel.hlsl
//
// Shader Graph Custom Function wrapper for filter/channel. Add a Custom Function
// node, point it at this file, select NM_Channel_float, and wire the inputs.
//
// Inputs:
//   InputTex  — source surface to sample
//   SS        — sampler state (bilinear, clamp, linear/non-sRGB)
//   UV        — 0..1 fragment UV (top-left origin, WGSL convention)
//   Channel   — int: 0=r, 1=g, 2=b, 3=a  (default 0)
//   Scale     — float multiplier before frac (default 1.0)
//   Offset    — float offset before frac (default 0.0)
// Output:
//   Out       — float4 grayscale: float4(v,v,v,1) where v = frac(ch*scale+offset)
// =============================================================================

#include "../../Shaders/Effects/filter/Channel.hlsl"

void NM_Channel_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    int               Channel,
    float             Scale,
    float             Offset,
    out float4        Out)
{
    // Override the per-effect uniforms with node inputs.
    // Note: Channel.hlsl declares channel/scale/offset as globals; we shadow
    // them via local variables and call the inline logic directly.
    float4 c = InputTex.Sample(SS, UV);

    float v;
    if (Channel == 0) {
        v = c.r;
    } else if (Channel == 1) {
        v = c.g;
    } else if (Channel == 2) {
        v = c.b;
    } else {
        v = c.a;
    }

    v = frac(v * Scale + Offset);
    Out = float4(v, v, v, 1.0);
}

#endif // NM_CHANNEL_SG_INCLUDED
