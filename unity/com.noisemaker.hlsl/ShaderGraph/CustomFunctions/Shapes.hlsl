#ifndef NM_SHAPES_SG_INCLUDED
#define NM_SHAPES_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Shapes.hlsl
//
// Shader Graph Custom Function wrapper for classicNoisedeck/shapes. Add a Custom
// Function node, point it at this file, select NM_Shapes_float, wire the named
// inputs. Outputs RGBA. Single-pass generator (no texture inputs).
//
// The core nm_shapes(...) in Shaders/Effects/classicNoisedeck/Shapes.hlsl reads
// its params from named GLOBAL uniforms. In a Shader Graph node those globals are
// unbound, so this wrapper COPIES each node input into the corresponding global
// before calling the core. It also seeds the engine globals (_NM_Resolution /
// _NM_FullResolution / _NM_Time) from the node inputs so the body's `time`,
// `aspectRatio`, and the `st = globalCoord / fullResolution.y` denominator are
// self-contained.
//
// UV is the 0..1 fragment UV (top-left origin, WGSL convention). globalCoord =
// UV * Resolution (pixel-centered at texel centers); tileOffset assumed 0.
// =============================================================================

#include "../../Shaders/Effects/classicNoisedeck/Shapes.hlsl"

void NM_Shapes_float(
    int    LoopAOffset,
    int    LoopBOffset,
    float  LoopAScale,
    float  LoopBScale,
    float  SpeedA,
    float  SpeedB,
    int    Seed,
    int    Wrap,
    int    PaletteMode,
    float3 PaletteOffset,
    float3 PaletteAmp,
    float3 PaletteFreq,
    float3 PalettePhase,
    int    CyclePalette,
    float  RotatePalette,
    int    RepeatPalette,
    float2 UV,
    float2 Resolution,
    float  Time,
    out float4 Out)
{
    // Bridge node inputs -> the core's named global uniforms.
    loopAOffset   = LoopAOffset;
    loopBOffset   = LoopBOffset;
    loopAScale    = LoopAScale;
    loopBScale    = LoopBScale;
    speedA        = SpeedA;
    speedB        = SpeedB;
    seed          = Seed;
    wrap          = Wrap;
    paletteMode   = PaletteMode;
    paletteOffset = PaletteOffset;
    paletteAmp    = PaletteAmp;
    paletteFreq   = PaletteFreq;
    palettePhase  = PalettePhase;
    cyclePalette  = CyclePalette;
    rotatePalette = RotatePalette;
    repeatPalette = RepeatPalette;

    // Seed engine globals so nm_shapes' `time`, `aspectRatio`, and the
    // `globalCoord / fullResolution.y` denominator are consistent with inputs.
    _NM_Resolution     = float4(Resolution, 0.0, 0.0);
    _NM_FullResolution = float4(Resolution, 0.0, 0.0);
    _NM_Time           = Time;

    // globalCoord = UV * resolution (pixel-centered at texel centers); tile=0.
    float2 globalCoord = UV * Resolution;
    Out = nm_shapes(globalCoord);
}

#endif // NM_SHAPES_SG_INCLUDED
