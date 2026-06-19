#ifndef NM_FRACTAL_SG_INCLUDED
#define NM_FRACTAL_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Fractal.hlsl
//
// Shader Graph Custom Function wrapper for classicNoisedeck/fractal.
// Single-pass generator — ShaderGraph node is supported.
//
// Add a Custom Function node, point it at this file, function NM_Fractal_float.
// Wire the named inputs. Outputs RGBA float4.
//
// Engine globals (resolution/time/fullResolution/tileOffset) are passed
// explicitly via UV/Resolution/Time so the node is self-contained.
// =============================================================================

#include "../../Shaders/Effects/classicNoisedeck/Fractal.hlsl"

void NM_Fractal_float(
    // fractal type / transform
    int    Type,
    float  ZoomAmt,
    float  Rotation,
    float  Speed,
    float  OffsetX,
    float  OffsetY,
    float  CenterX,
    float  CenterY,
    // rendering
    int    Mode,
    int    Iterations,
    // coloring
    int    ColorMode,
    int    PaletteMode,
    int    CyclePalette,
    float  RotatePalette,
    float  RepeatPalette,
    float3 PaletteOffset,
    float  HueRange,
    float3 PaletteAmp,
    float  Levels,
    float3 PaletteFreq,
    float  BgAlpha,
    float3 PalettePhase,
    float  Cutoff,
    float3 BgColor,
    int    Symmetry,
    // engine
    float2 UV,
    float2 Resolution,
    float  Time,
    out float4 Out)
{
    // Bridge node inputs -> core named globals.
    type          = Type;
    zoomAmt       = ZoomAmt;
    rotation      = Rotation;
    speed         = Speed;
    offsetX       = OffsetX;
    offsetY       = OffsetY;
    centerX       = CenterX;
    centerY       = CenterY;
    mode          = Mode;
    iterations    = Iterations;
    colorMode     = ColorMode;
    paletteMode   = PaletteMode;
    cyclePalette  = CyclePalette;
    rotatePalette = RotatePalette;
    repeatPalette = RepeatPalette;
    paletteOffset = PaletteOffset;
    hueRange      = HueRange;
    paletteAmp    = PaletteAmp;
    levels        = Levels;
    paletteFreq   = PaletteFreq;
    bgAlpha       = BgAlpha;
    palettePhase  = PalettePhase;
    cutoff        = Cutoff;
    bgColor       = BgColor;
    symmetry      = Symmetry;

    // Seed engine globals from node inputs (tileOffset=0 for standalone use).
    _NM_Resolution     = float4(Resolution, 0.0, 0.0);
    _NM_FullResolution = float4(Resolution, 0.0, 0.0);
    _NM_TileOffset     = float4(0.0, 0.0, 0.0, 0.0);
    _NM_Time           = Time;

    float2 globalCoord = UV * Resolution;
    Out = nm_fractal(globalCoord);
}

#endif // NM_FRACTAL_SG_INCLUDED
