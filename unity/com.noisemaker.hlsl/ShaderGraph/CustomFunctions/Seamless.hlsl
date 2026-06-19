#ifndef NM_SEAMLESS_SG_INCLUDED
#define NM_SEAMLESS_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Seamless.hlsl
//
// Shader Graph Custom Function wrapper for filter/seamless. Add a Custom
// Function node, point it at this file, select NM_Seamless_float, and wire
// the inputs. Outputs RGBA.
//
// filter/seamless is single-pass, so a SG wrapper is provided.
//
// Inputs:
//   InputTex  — source texture (UnityTexture2D)
//   SS        — sampler state (bilinear, clamp, linear/non-sRGB)
//   UV        — 0..1 fragment UV (top-left origin, WGSL convention)
//   Blend     — blend region width [0, 0.5], default 0.25
//   Repeat    — tile repetition count [1, 10], default 2
//   Curve     — curve mode: 0=linear, 1=smooth, 2=sharp; default 1
// Output:
//   Out       — RGBA float4
//
// NOTE: This wrapper samples at the UV provided by Shader Graph. In the
// fullscreen pass the runtime derives UV = NM_FragCoord(i) / texDimensions,
// which equals the standard 0..1 UV for a render-target of the same size.
// In a Shader Graph context you should supply the equivalent UV (e.g. from
// a Screen Position node in Raw mode divided by the texture resolution).
// =============================================================================

#include "../../Shaders/Effects/filter/Seamless.hlsl"

void NM_Seamless_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             Blend,
    float             Repeat,
    int               Curve,
    out float4        Out)
{
    float2 st = nm_seamless_fract2(UV * Repeat);

    float wx = nm_seamless_edgeWeight(st.x, Blend, Curve);
    float wy = nm_seamless_edgeWeight(st.y, Blend, Curve);

    // textureSampleLevel lod 0 for c00
    float4 c00 = InputTex.tex.SampleLevel(SS.samplerstate, st, 0);
    float4 c10 = InputTex.Sample(SS, nm_seamless_fract2(st + float2(0.5, 0.0)));
    float4 c01 = InputTex.Sample(SS, nm_seamless_fract2(st + float2(0.0, 0.5)));
    float4 c11 = InputTex.Sample(SS, nm_seamless_fract2(st + float2(0.5, 0.5)));

    float4 mx0    = lerp(c00, c10, wx);
    float4 mx1    = lerp(c01, c11, wx);
    float4 result = lerp(mx0, mx1, wy);

    Out = float4(result.rgb, 1.0);
}

#endif // NM_SEAMLESS_SG_INCLUDED
