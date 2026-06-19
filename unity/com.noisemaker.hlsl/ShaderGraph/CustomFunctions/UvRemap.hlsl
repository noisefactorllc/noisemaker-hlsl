#ifndef NM_UVREMAP_SG_INCLUDED
#define NM_UVREMAP_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/UvRemap.hlsl
//
// Shader Graph Custom Function wrapper for mixer/uvRemap. Add a Custom Function
// node, point it at this file, select NM_UvRemap_float, and wire the named
// inputs. Outputs RGBA.
//
// The core nm_uvRemap(...) in Shaders/Effects/mixer/UvRemap.hlsl reads its
// scalar parameters from module-scope named uniforms (mapSource/channel/scale/
// offset/wrap). This wrapper assigns the node inputs to them before calling
// nm_uvRemap, bridging named inputs into the core function.
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   MapSource : mapSource  (0=sourceA, 1=sourceB), default 0
//   Channel   : channel    (0=redGreen, 1=redBlue, 2=greenBlue), default 0
//   Scale     : scale      (0..200), default 100.0
//   Offset    : offset     (-1..1), default 0.0
//   Wrap      : wrap       (0=clamp, 1=mirror, 2=repeat), default 1
//   InputTex  : inputTex   (source A)
//   Tex       : tex        (source B)
//   SS        : sampler state (bilinear, clamp, linear/non-sRGB)
//   UV        : 0..1 fragment UV (top-left origin, WGSL convention)
//
// NOTE: This wrapper samples both inputs at the supplied UV (equal-sized-surface
// case). The WGSL derives st from inputTex's own dims; for equal-sized render
// targets (the runtime allocates outputTex == input size) these coincide.
// =============================================================================

#include "../../Shaders/Effects/mixer/UvRemap.hlsl"

void NM_UvRemap_float(
    int               MapSource,
    int               Channel,
    float             Scale,
    float             Offset,
    int               Wrap,
    UnityTexture2D    InputTex,
    UnityTexture2D    Tex,
    UnitySamplerState SS,
    float2            UV,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    mapSource = MapSource;
    channel   = Channel;
    scale     = Scale;
    offset    = Offset;
    wrap      = Wrap;

    float4 colorA = InputTex.Sample(SS, UV);
    float4 colorB = Tex.Sample(SS, UV);

    Out = nm_uvRemap(
        colorA, colorB,
        InputTex.tex, SS.samplerstate,
        Tex.tex,      SS.samplerstate);
}

#endif // NM_UVREMAP_SG_INCLUDED
