#ifndef NM_SINE_SG_INCLUDED
#define NM_SINE_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Sine.hlsl
//
// Shader Graph Custom Function wrapper for filter/sine. Add a Custom Function
// node, point it at this file, select NM_Sine_float, and wire the inputs.
//
// Inputs:
//   InputTex  — source surface
//   SS        — sampler state (bilinear, clamp, linear/non-sRGB)
//   UV        — 0..1 fragment UV (top-left origin, WGSL convention)
//   Amount    — sine frequency, default 7, range [0, 20]
//   ColorMode — 0 = mono (luminance), 1 = rgb (per-channel); compared > 0.5
// =============================================================================

#include "../../Shaders/Effects/filter/Sine.hlsl"

void NM_Sine_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             Amount,
    float             ColorMode,
    out float4        Out)
{
    // Bind the per-effect uniforms that nm_sine() reads as globals.
    // In a Shader Graph context the globals are set here before calling the core fn.
    amount    = Amount;
    colorMode = ColorMode;

    float4 color = InputTex.Sample(SS, UV);
    Out = nm_sine(color);
}

#endif // NM_SINE_SG_INCLUDED
