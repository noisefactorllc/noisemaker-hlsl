#ifndef NM_SOBEL_SG_INCLUDED
#define NM_SOBEL_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Sobel.hlsl
//
// Shader Graph Custom Function wrapper for filter/sobel. Drops the effect in as a
// node: add a Custom Function node, point it at this file, select NM_Sobel_float,
// and wire the named inputs + InputTex/SS/UV. Outputs RGBA.
//
// The core nm_sobel(...) in Shaders/Effects/filter/Sobel.hlsl reads its parameters
// from module-scope named uniforms (amount/alpha) — matching the runtime's
// individual-named-uniform binding model. In a standalone Shader Graph node those
// globals are not bound by the runtime, so this wrapper assigns the node inputs to
// them before calling nm_sobel, bridging the named inputs into the core function.
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   Amount   : amount (0.1..5), default 1.0  — scales the texel sampling offsets
//   Alpha    : alpha  (0..1),   default 1.0  — original<->edge blend
//   InputTex : source surface to edge-detect
//   SS       : sampler state (bilinear, clamp, linear/non-sRGB) for InputTex
//   UV       : 0..1 fragment UV (top-left origin, WGSL convention)
//
// The core derives texelSize from the input texture's dimensions, which the node
// queries via InputTex.GetDimensions (matching the WGSL textureDimensions path).
// =============================================================================

#include "../../Shaders/Effects/filter/Sobel.hlsl"

void NM_Sobel_float(
    float             Amount,
    float             Alpha,
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    amount = Amount;
    alpha  = Alpha;

    // texSize = input texture's own dimensions (WGSL textureDimensions(inputTex)).
    uint tw, th;
    InputTex.tex.GetDimensions(tw, th);
    float2 texSize = float2(tw, th);

    Out = nm_sobel(InputTex.tex, SS.samplerstate, UV, texSize);
}

#endif // NM_SOBEL_SG_INCLUDED
