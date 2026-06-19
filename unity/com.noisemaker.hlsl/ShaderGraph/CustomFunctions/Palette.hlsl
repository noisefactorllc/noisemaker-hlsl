#ifndef NM_PALETTE_SG_INCLUDED
#define NM_PALETTE_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Palette.hlsl
//
// Shader Graph Custom Function wrapper for filter/palette. Add a Custom Function
// node, point it at this file, select NM_Palette_float, and wire the inputs.
// Outputs RGBA.
//
// Inputs:
//   InputTex     — source surface (UnityTexture2D)
//   SS           — sampler state (bilinear, clamp, linear/non-sRGB)
//   UV           — 0..1 fragment UV (top-left origin, WGSL convention)
//   PaletteIndex — int index 0-55 (0 = passthrough, 7 = brushedMetal default)
//   Rotation     — int -1/0/1 (back/none/fwd animation)
//   Offset       — float 0..100 palette phase offset
//   Repeat       — float 1..10 luminance repeat count
//   Alpha        — float 0..1 blend from original to palette color
//   EngineTime   — float current time (wire from Time node)
//
// The wrapper sets the named uniforms expected by nm_palette(), then calls it.
// =============================================================================

#include "../../Shaders/Effects/filter/Palette.hlsl"

void NM_Palette_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    int               PaletteIndex,
    int               Rotation,
    float             Offset,
    float             Repeat,
    float             Alpha,
    float             EngineTime,
    out float4        Out)
{
    // Set the named uniforms that nm_palette() reads as shader globals.
    // In a Shader Graph context these are passed as local variables instead.
    paletteIndex = PaletteIndex;
    rotation     = Rotation;
    offset       = Offset;
    repeat       = Repeat;
    alpha        = Alpha;

    float4 color = InputTex.Sample(SS, UV);
    Out = nm_palette(color, EngineTime);
}

#endif // NM_PALETTE_SG_INCLUDED
