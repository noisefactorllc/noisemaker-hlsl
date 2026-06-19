#ifndef NM_SG_CELLNOISE_INCLUDED
#define NM_SG_CELLNOISE_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/CellNoise.hlsl
//
// Shader Graph Custom Function wrapper for classicNoisedeck/cellNoise (single
// render pass, so a node wrapper is provided). Add a Custom Function node, point
// it at this file, select NM_CellNoise_float, and wire the named inputs.
// Outputs RGBA.
//
// The core nm_cellNoise(...) in Shaders/Effects/classicNoisedeck/CellNoise.hlsl
// reads the effect parameters from named GLOBAL uniforms (shape, scale, ...). In
// a Shader Graph node those globals are unbound, so this wrapper COPIES each node
// input into the corresponding global before calling the core (the standard
// Custom-Function bridging pattern; see Gradient.hlsl). Engine globals
// (resolution/time/fullResolution/tileOffset) are passed explicitly via the
// UV/Resolution/Time inputs so the node is self-contained.
//
// `Tex` is the OPTIONAL input surface (definition.js inputs: { tex: "tex" }). The
// node always samples it; with TexIntensity = 0 and TexInfluence = warp the
// texture path is inert (matching the runtime default). UV is the input texture's
// own 0..1 UV; the WGSL samples tex at (pos.xy + tileOffset)/fullResolution, which
// equals UV for equal-sized surfaces with tileOffset = 0.
// TODO(verify): SS must be a clamp, non-sRGB (linear) sampler state to match the
// runtime bilinear/clamp/linear path (H7).
// =============================================================================

#include "../../Shaders/Effects/classicNoisedeck/CellNoise.hlsl"

void NM_CellNoise_float(
    UnityTexture2D    Tex,
    UnitySamplerState SS,
    float2            UV,
    float2            Resolution,
    float             Time,
    int               Shape,
    float             Scale,
    float             CellScale,
    float             CellSmooth,
    float             Variation,
    float             Speed,
    int               PaletteMode,
    int               Seed,
    int               ColorMode,
    float3            PaletteOffset,
    int               CyclePalette,
    float3            PaletteAmp,
    float             RotatePalette,
    float3            PaletteFreq,
    float             RepeatPalette,
    float3            PalettePhase,
    int               TexInfluence,
    float             TexIntensity,
    out float4        Out)
{
    // Bridge node inputs -> the core's named global uniforms.
    shape         = Shape;
    scale         = Scale;
    cellScale     = CellScale;
    cellSmooth    = CellSmooth;
    variation     = Variation;
    speed         = Speed;
    paletteMode   = PaletteMode;
    seed          = Seed;
    colorMode     = ColorMode;
    paletteOffset = PaletteOffset;
    cyclePalette  = CyclePalette;
    paletteAmp    = PaletteAmp;
    rotatePalette = RotatePalette;
    paletteFreq   = PaletteFreq;
    repeatPalette = RepeatPalette;
    palettePhase  = PalettePhase;
    texInfluence  = TexInfluence;
    texIntensity  = TexIntensity;

    // Seed engine globals from the Resolution input (used as both resolution and
    // fullResolution; tileOffset = 0 for standalone node usage).
    _NM_Resolution     = float4(Resolution, 0.0, 0.0);
    _NM_FullResolution = float4(Resolution, 0.0, 0.0);

    // globalCoord = UV * resolution (pixel-centered when UV hits a texel center).
    float2 globalCoord = UV * Resolution;
    float4 texel = SAMPLE_TEXTURE2D(Tex.tex, SS.samplerstate, UV);

    Out = nm_cellNoise(globalCoord, Resolution, Resolution, Time, texel);
}

#endif // NM_SG_CELLNOISE_INCLUDED
