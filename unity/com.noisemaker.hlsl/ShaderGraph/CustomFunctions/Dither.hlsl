#ifndef NM_DITHER_SG_INCLUDED
#define NM_DITHER_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Dither.hlsl
//
// Shader Graph Custom Function wrapper for filter/dither. Add a Custom Function
// node, point it at this file, select NM_Dither_float, and wire the named inputs
// + InputTex/SS/UV. Outputs RGBA.
//
// The core nm_dither(...) in Shaders/Effects/filter/Dither.hlsl reads its
// parameters from module-scope named uniforms (ditherType/matrixScale/threshold/
// palette/levels/mixAmount) — matching the runtime's individual-named-uniform
// binding model. In a standalone Shader Graph node those globals are not bound by
// the runtime, so this wrapper assigns node inputs to them before calling
// nm_dither, bridging the named inputs into the core function.
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   Type        : ditherType  (0..6),                     default 1
//   MatrixScale : matrixScale (1..8, WGSL f32 scale),     default 2
//   Threshold   : threshold   (-0.5..0.5),                default 0.0
//   Palette     : palette     (0..9),                     default 0
//   Levels      : levels      (2..16),                    default 4
//   Mix         : mixAmount   (0..1),                      default 1.0
//   InputTex    : source surface to dither
//   SS          : sampler state (bilinear, clamp, linear/non-sRGB) for InputTex
//   UV          : 0..1 fragment UV (top-left origin, WGSL convention)
//
// NOTE: nm_dither needs the RAW pixel coordinate (WGSL pos.xy) for the dither
// pattern, not just UV. We recover it as UV * input-texture-size, matching the
// render pass (pixelCoord = NM_FragCoord(i); uv = pixelCoord / texSize). The
// engine global `time` (used only by the noise dither) is read from NMFullscreen
// by the core function; in a standalone node it defaults to 0.
// =============================================================================

#include "../../Shaders/Effects/filter/Dither.hlsl"

void NM_Dither_float(
    int               Type,
    float             MatrixScale,
    float             Threshold,
    int               Palette,
    int               Levels,
    float             Mix,
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    ditherType  = Type;
    matrixScale = MatrixScale;
    threshold   = Threshold;
    palette     = Palette;
    levels      = Levels;
    mixAmount   = Mix;

    // Recover the raw pixel coordinate (WGSL pos.xy) the dither pattern expects.
    uint tw, th;
    InputTex.tex.GetDimensions(tw, th);
    float2 texSize = float2(tw, th);
    float2 pixelCoord = UV * texSize;

    float4 color = InputTex.Sample(SS, UV);
    Out = nm_dither(color, pixelCoord);
}

#endif // NM_DITHER_SG_INCLUDED
