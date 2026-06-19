#ifndef NM_STEP_SG_INCLUDED
#define NM_STEP_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Step.hlsl
//
// Shader Graph Custom Function wrapper for filter/step. Add a Custom Function
// node, point it at this file, select NM_Step_float, and wire the inputs.
//
// Inputs:
//   InputTex  — source surface to threshold
//   SS        — sampler state (bilinear, clamp, linear/non-sRGB)
//   UV        — 0..1 fragment UV (top-left origin, WGSL convention)
//   Threshold — hard-edge threshold value (float, default 0.5)
//   Antialias — boolean as int (1 = smoothstep AA, 0 = hard step)
//
// NOTE: nm_step() calls fwidth() which requires a pixel-shader derivative.
// This wrapper is valid in Shader Graph fragment-stage contexts only.
// =============================================================================

#include "../../Shaders/Effects/filter/Step.hlsl"

void NM_Step_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             Threshold,
    int               Antialias,
    out float4        Out)
{
    // Temporarily bind the per-effect uniforms that nm_step() reads as globals.
    // Shader Graph callers supply these as node inputs rather than material props.
    // We shadow the globals by assigning to the module-scope names defined in
    // Step.hlsl. This is valid because Step.hlsl declares them as bare globals
    // and we are in the same HLSL translation unit after #include.
    threshold = Threshold;
    antialias = Antialias;

    float4 color = InputTex.Sample(SS, UV);
    Out = nm_step(color); // TODO(verify): confirm global-shadow pattern compiles in SG HLSL context
}

#endif // NM_STEP_SG_INCLUDED
