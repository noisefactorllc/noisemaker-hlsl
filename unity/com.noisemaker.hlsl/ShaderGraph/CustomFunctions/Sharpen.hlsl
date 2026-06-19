#ifndef NM_SHARPEN_SG_INCLUDED
#define NM_SHARPEN_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Sharpen.hlsl
//
// Shader Graph Custom Function wrapper for filter/sharpen. Add a Custom Function
// node, point it at this file, select NM_Sharpen_float, and wire inputs.
//
// filter/sharpen has one per-effect parameter (definition.js globals: {amount}).
// Inputs: InputTex, SS (sampler), UV, Amount.
// The node samples InputTex at UV (must match the input texture's own pixel
// space — i.e. UV = fragCoord / textureDimensions(InputTex)) and returns the
// convolution result with alpha preserved from the center sample.
// =============================================================================

#include "../../Shaders/Effects/filter/Sharpen.hlsl"

// InputTex : source surface to sharpen
// SS       : sampler state (bilinear, clamp, linear/non-sRGB) for InputTex
// UV       : fragCoord / InputTex dimensions (top-left origin, WGSL convention)
// Amount   : kernel spread scalar (definition.js default 1.0, range [0.1, 5])
void NM_Sharpen_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             Amount,
    out float4        Out)
{
    // Resolve the texture dimensions so nm_sharpen can compute texelSize.
    uint tw, th;
    InputTex.tex.GetDimensions(tw, th);
    float2 texSize = float2(tw, th);

    // Temporarily write to the global uniform that nm_sharpen reads.
    // NOTE: in a Shader Graph context the global 'amount' uniform is set here
    // directly; the wrapper is single-pass so this is safe.
    amount = Amount;

    Out = nm_sharpen(InputTex.tex, SS.samplerstate, UV, texSize);
}

#endif // NM_SHARPEN_SG_INCLUDED
