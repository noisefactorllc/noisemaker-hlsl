#ifndef NM_ALPHAMASK_SG_INCLUDED
#define NM_ALPHAMASK_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/AlphaMask.hlsl
//
// Shader Graph Custom Function wrapper for mixer/alphaMask. Add a Custom
// Function node, point it at this file, select NM_AlphaMask_float, and wire
// the named inputs + the two textures/SS/UV.  Outputs RGBA.
//
// The core nm_alphaMask(...) in Shaders/Effects/mixer/AlphaMask.hlsl reads its
// scalar parameters from module-scope named uniforms (mixAmt/maskMode) — matching
// the runtime's individual-named-uniform binding model. In a standalone Shader
// Graph node those globals are not bound by the runtime, so this wrapper assigns
// the node inputs to them before calling nm_alphaMask, bridging the named inputs
// into the core function.
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   MixAmt   : mixAmt (-100..100), default 0   (definition.js key "mix")
//   MaskMode : maskMode (0=off, 1=grayscale mask), default 0
//   BaseTex  : base surface  -> inputTex  (color1)
//   LayerTex : layer surface -> tex       (color2)
//   SS       : sampler state (bilinear, clamp, linear/non-sRGB) for both textures
//   UV       : 0..1 fragment UV (top-left origin, WGSL convention)
//
// The WGSL samples both textures at the SAME st (derived from inputTex's size);
// here we sample both at the supplied UV with one shared sampler, matching the
// equal-sized-surface case the runtime uses.
// =============================================================================

#include "../../Shaders/Effects/mixer/AlphaMask.hlsl"

void NM_AlphaMask_float(
    float             MixAmt,
    int               MaskMode,
    UnityTexture2D    BaseTex,
    UnityTexture2D    LayerTex,
    UnitySamplerState SS,
    float2            UV,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    mixAmt   = MixAmt;
    maskMode = MaskMode;

    float4 color1 = BaseTex.Sample(SS, UV);
    float4 color2 = LayerTex.Sample(SS, UV);
    Out = nm_alphaMask(color1, color2);
}

#endif // NM_ALPHAMASK_SG_INCLUDED
