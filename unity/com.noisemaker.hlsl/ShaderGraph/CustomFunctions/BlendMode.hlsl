#ifndef NM_BLENDMODE_SG_INCLUDED
#define NM_BLENDMODE_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/BlendMode.hlsl
//
// Shader Graph Custom Function wrapper for mixer/blendMode. Drops the effect in
// as a node: add a Custom Function node, point it at this file, select
// NM_BlendMode_float, and wire the named inputs + the two textures/SS/UV.
// Outputs RGBA.
//
// The core nm_blendMode(...) in Shaders/Effects/mixer/BlendMode.hlsl reads its
// scalar parameters from module-scope named uniforms (mode/mixAmt) — matching the
// runtime's individual-named-uniform binding model. In a standalone Shader Graph
// node those globals are not bound by the runtime, so this wrapper assigns the
// node inputs to them before calling nm_blendMode, bridging the named inputs into
// the core function.
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   Mode     : mode   (0 add,1 burn,2 darken,3 diff,4 dodge,5 exclusion,
//                       6 hardLight,7 lighten,8 mix,9 multiply,10 negation,
//                       11 overlay,12 phoenix,13 screen,14 softLight,15 subtract),
//              default 0
//   MixAmt   : mixAmt (-100..100), default 0   (definition.js key "mix")
//   BaseTex  : base surface  -> inputTex   (color1)
//   LayerTex : layer surface -> tex        (color2)
//   SS       : sampler state (bilinear, clamp, linear/non-sRGB) for both textures
//   UV       : 0..1 fragment UV (top-left origin, WGSL convention)
//
// The WGSL samples both textures at the SAME st (derived from inputTex's size);
// here we sample both at the supplied UV with one shared sampler, matching the
// equal-sized-surface case the runtime uses.
// =============================================================================

#include "../../Shaders/Effects/mixer/BlendMode.hlsl"

void NM_BlendMode_float(
    int               Mode,
    float             MixAmt,
    UnityTexture2D    BaseTex,
    UnityTexture2D    LayerTex,
    UnitySamplerState SS,
    float2            UV,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    mode   = Mode;
    mixAmt = MixAmt;

    float4 color1 = BaseTex.Sample(SS, UV);
    float4 color2 = LayerTex.Sample(SS, UV);
    Out = nm_blendMode(color1, color2);
}

#endif // NM_BLENDMODE_SG_INCLUDED
