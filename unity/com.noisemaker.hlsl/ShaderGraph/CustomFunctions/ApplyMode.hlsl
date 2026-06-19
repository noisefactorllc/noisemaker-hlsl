#ifndef NM_APPLYMODE_SG_INCLUDED
#define NM_APPLYMODE_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/ApplyMode.hlsl
//
// Shader Graph Custom Function wrapper for mixer/applyMode. Add a Custom
// Function node, point it at this file, select NM_ApplyMode_float, and wire
// the named inputs + the two textures/SS/UV.
//
// The core nm_applyMode(...) in Shaders/Effects/mixer/ApplyMode.hlsl reads its
// scalar parameters from module-scope named uniforms (mode/mixAmt) — matching
// the runtime's individual-named-uniform binding model. In a standalone Shader
// Graph node those globals are not bound by the runtime, so this wrapper
// assigns the node inputs to them before calling nm_applyMode.
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   Mode     : mode   (0 brightness, 1 hue, 2 saturation), default 0
//   MixAmt   : mixAmt (-100..100), default 0  (definition.js key "mix")
//   InputTex : source A -> inputTex  (color1)
//   Tex      : source B -> tex       (color2)
//   SS       : sampler state (bilinear, clamp, linear/non-sRGB) for both
//   UV       : 0..1 fragment UV (top-left origin, WGSL convention)
//
// The WGSL samples both textures at the SAME st (derived from inputTex's
// size); here we sample both at the supplied UV with one shared sampler,
// matching the equal-sized-surface case the runtime uses.
// =============================================================================

#include "../../Shaders/Effects/mixer/ApplyMode.hlsl"

void NM_ApplyMode_float(
    int               Mode,
    float             MixAmt,
    UnityTexture2D    InputTex,
    UnityTexture2D    Tex,
    UnitySamplerState SS,
    float2            UV,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    mode   = Mode;
    mixAmt = MixAmt;

    float4 color1 = InputTex.Sample(SS, UV);
    float4 color2 = Tex.Sample(SS, UV);
    Out = nm_applyMode(color1, color2);
}

#endif // NM_APPLYMODE_SG_INCLUDED
