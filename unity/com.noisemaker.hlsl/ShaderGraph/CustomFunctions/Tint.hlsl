#ifndef NM_TINT_SG_INCLUDED
#define NM_TINT_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Tint.hlsl
//
// Shader Graph Custom Function wrapper for filter/tint. Drops the effect in as a
// node: add a Custom Function node, point it at this file, select NM_Tint_float,
// and wire the named inputs + InputTex/SS/UV. Outputs RGBA.
//
// The core nm_tint(...) in Shaders/Effects/filter/Tint.hlsl reads its parameters
// from module-scope named uniforms (color/alpha/mode) — matching the runtime's
// individual-named-uniform binding model. In a standalone Shader Graph node those
// globals are not bound by the runtime, so this wrapper assigns the node inputs to
// them before calling nm_tint, bridging the named inputs into the core function.
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   Color : color (RGB, linear/non-sRGB), default (1,1,1)
//   Alpha : alpha (0..1),                  default 0.5
//   Mode  : mode  (0 overlay,1 multiply,2 recolor), default 0
//   InputTex : source surface to tint
//   SS       : sampler state (bilinear, clamp, linear/non-sRGB) for InputTex
//   UV       : 0..1 fragment UV (top-left origin, WGSL convention)
// =============================================================================

#include "../../Shaders/Effects/filter/Tint.hlsl"

void NM_Tint_float(
    float3            Color,
    float             Alpha,
    int               Mode,
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    color = Color;
    alpha = Alpha;
    mode  = Mode;

    float4 base = InputTex.Sample(SS, UV);
    Out = nm_tint(base);
}

#endif // NM_TINT_SG_INCLUDED
