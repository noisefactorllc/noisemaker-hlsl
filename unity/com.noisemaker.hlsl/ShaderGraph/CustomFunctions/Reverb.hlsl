#ifndef NM_REVERB_SG_INCLUDED
#define NM_REVERB_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Reverb.hlsl
//
// Shader Graph Custom Function wrapper for filter/reverb. Drops the effect in
// as a node: add a Custom Function node, point it at this file, select
// NM_Reverb_float, and wire the named inputs + InputTex/SS/UV. Outputs RGBA.
//
// The core nm_reverb(...) in Shaders/Effects/filter/Reverb.hlsl reads its
// parameters from module-scope named uniforms (iterations/ridges/alpha/wrap)
// matching the runtime's individual-named-uniform binding model. In a
// standalone Shader Graph node those globals are not bound by the runtime, so
// this wrapper assigns the node inputs to them before calling nm_reverb.
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   Iterations : iterations (int, 1..8),    default 3
//   Ridges     : ridges     (int 0=off,1=on), default 0
//   Alpha      : alpha      (0..1),           default 1.0
//   Wrap       : wrap       (0=mirror,1=repeat,2=clamp), default 0
//   InputTex   : source surface to process
//   SS         : sampler state (bilinear, clamp, linear/non-sRGB)
//   UV         : 0..1 fragment UV (top-left origin, WGSL convention)
// =============================================================================

#include "../../Shaders/Effects/filter/Reverb.hlsl"

void NM_Reverb_float(
    int               Iterations,
    int               Ridges,
    float             Alpha,
    int               Wrap,
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    iterations = Iterations;
    ridges     = Ridges;
    alpha      = Alpha;
    wrap       = Wrap;

    float4 original = InputTex.Sample(SS, UV);
    Out = nm_reverb(original, UV, InputTex, SS);
}

#endif // NM_REVERB_SG_INCLUDED
