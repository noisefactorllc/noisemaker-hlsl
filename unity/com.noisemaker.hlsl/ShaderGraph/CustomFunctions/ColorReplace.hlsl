#ifndef NM_COLOR_REPLACE_SG_INCLUDED
#define NM_COLOR_REPLACE_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/ColorReplace.hlsl
//
// Shader Graph Custom Function wrapper for filter/colorReplace. Add a Custom
// Function node, point it at this file, select NM_ColorReplace_float, and wire
// the inputs. Outputs RGBA.
//
// filter/colorReplace is a single-pass filter: one input texture, no feedback.
// This wrapper is valid for use as a SG node (single pass, stateless per pixel).
// =============================================================================

#include "../../Shaders/Effects/filter/ColorReplace.hlsl"

// InputTex    : source surface to process
// SS          : sampler state (bilinear, clamp, linear/non-sRGB) for InputTex
// UV          : 0..1 fragment UV (top-left origin, WGSL convention)
// TargetColor : RGB color to match (default 0,0,0)
// ReplaceColor: RGB color to replace matched pixels with (default 1,1,1)
// Sensitivity : match radius in normalized RGB space (default 0.3)
// Smoothing   : soft edge width around match radius (default 0.1)
// ColorMix    : blend factor toward replaceColor (default 1.0)
// ReplaceAlpha: alpha value for matched pixels (default 1.0)
// KeepAlpha   : alpha scale for unmatched pixels (default 1.0)
void NM_ColorReplace_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float3            TargetColor,
    float3            ReplaceColor,
    float             Sensitivity,
    float             Smoothing,
    float             ColorMix,
    float             ReplaceAlpha,
    float             KeepAlpha,
    out float4        Out)
{
    // Bind SG inputs into the module-level uniforms that nm_colorReplace reads.
    targetColor  = TargetColor;
    replaceColor = ReplaceColor;
    sensitivity  = Sensitivity;
    smoothing    = Smoothing;
    colorMix     = ColorMix;
    replaceAlpha = ReplaceAlpha;
    keepAlpha    = KeepAlpha;

    float4 src = InputTex.Sample(SS, UV);
    Out = nm_colorReplace(src);
}

#endif // NM_COLOR_REPLACE_SG_INCLUDED
