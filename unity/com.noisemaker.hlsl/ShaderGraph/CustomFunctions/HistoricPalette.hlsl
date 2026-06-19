#ifndef NM_HISTORICPALETTE_SG_INCLUDED
#define NM_HISTORICPALETTE_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/HistoricPalette.hlsl
//
// Shader Graph Custom Function wrapper for filter/historicPalette. Add a Custom
// Function node, point it at this file, select NM_HistoricPalette_float, and
// wire the named inputs + InputTex/SS/UV. Outputs RGBA.
//
// The core nm_historicPalette() in Shaders/Effects/filter/HistoricPalette.hlsl
// reads parameters from module-scope named uniforms matching definition.js
// globals[*].uniform. This wrapper assigns node inputs to those globals before
// calling the core function.
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   PaletteIndex : paletteIndex (int, 0..20),  default 4
//   Smoothness   : smoothness   (0..1),         default 0
//   Rotation     : rotation     (-1/0/1 float), default 0
//   Offset       : offset       (0..100),       default 0
//   Repeat       : repeat       (1..10 float),  default 1
//   Alpha        : alpha        (0..1),         default 1
//   InputTex     : source surface
//   SS           : sampler state (bilinear, clamp, linear/non-sRGB)
//   UV           : 0..1 fragment UV (top-left origin, WGSL convention)
// =============================================================================

#include "../../Shaders/Effects/filter/HistoricPalette.hlsl"

void NM_HistoricPalette_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    int               PaletteIndex,
    float             Smoothness,
    float             Rotation,
    float             Offset,
    float             Repeat,
    float             Alpha,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    paletteIndex = PaletteIndex;
    smoothness   = Smoothness;
    rotation     = Rotation;
    offset       = Offset;
    repeat       = Repeat;
    alpha        = Alpha;

    float4 inputColor = InputTex.Sample(SS, UV);
    Out = nm_historicPalette(inputColor);
}

#endif // NM_HISTORICPALETTE_SG_INCLUDED
