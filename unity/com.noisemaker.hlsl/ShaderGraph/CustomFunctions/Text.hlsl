#ifndef NM_TEXT_SG_INCLUDED
#define NM_TEXT_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Text.hlsl
//
// Shader Graph Custom Function wrapper for filter/text. Add a Custom Function
// node, point it at this file, select NM_Text_float, and wire the inputs.
//
// NOTE: filter/text relies on an externalTexture ("textTex") that the runtime
// renders on the CPU (HTML Canvas / font rasteriser) before each frame. In a
// Shader Graph context TextTex must be supplied as a pre-rendered Texture2D
// from a RenderTexture updated by equivalent CPU-side logic. The blend math
// here is pixel-identical to the WGSL; the CPU text rendering is the caller's
// responsibility. // TODO(verify) confirm CPU text pipeline feeds TextTex in SG.
// =============================================================================

#include "../../Shaders/Effects/filter/Text.hlsl"

// InputTex  : scene input surface
// TextTex   : CPU-rendered text surface (RGBA, alpha = text presence)
// SS        : shared sampler state (bilinear, clamp, linear/non-sRGB)
// UV        : 0..1 fragment UV (top-left origin, WGSL convention)
// MatteColor   : background fill color (rgb)
// MatteOpacity : background opacity [0..1]
void NM_Text_float(
    UnityTexture2D    InputTex,
    UnityTexture2D    TextTex,
    UnitySamplerState SS,
    float2            UV,
    float3            MatteColor,
    float             MatteOpacity,
    out float4        Out)
{
    float4 inputColor = InputTex.Sample(SS, UV);
    float4 text       = TextTex.Sample(SS, UV);
    Out = nm_text(inputColor, text, MatteColor, MatteOpacity);
}

#endif // NM_TEXT_SG_INCLUDED
