#ifndef NM_SHAPEMIXER_SG_INCLUDED
#define NM_SHAPEMIXER_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/ShapeMixer.hlsl
//
// Shader Graph Custom Function wrapper for classicNoisedeck/shapeMixer. Add a
// Custom Function node, point it at this file, select NM_ShapeMixer_float, and
// wire the named inputs + the two textures/SS/UV. Outputs RGBA.
//
// Single render pass -> a wrapper is provided. The core nm_shapeMixer(...) in
// Shaders/Effects/classicNoisedeck/ShapeMixer.hlsl reads its scalar parameters
// from module-scope named uniforms (matching the runtime's individual-named-
// uniform binding model). In a standalone node those globals are not bound, so
// this wrapper assigns the node inputs to them before calling nm_shapeMixer.
//
// Param mapping (definition.js globals[*].uniform / define -> node input):
//   BlendMode     : blendMode (0 add..9 subtract), default 2 (max)
//   LoopOffset    : LOOP_OFFSET shape selector, default 10 (circle)
//   LoopScale     : loopScale (1..100), default 80
//   Wrap          : wrap (0/1), default 1
//   Seed          : seed (1..100), default 1
//   Animate       : animate (-1/0/1), default 1
//   Palette       : palette (UI-only id; unused in body), default 41
//   PaletteMode   : paletteMode, default 0
//   PaletteOffset : paletteOffset, default (0.83,0.6,0.63)
//   PaletteAmp    : paletteAmp, default (0.5,0.5,0.5)
//   PaletteFreq   : paletteFreq, default (1,1,1)
//   PalettePhase  : palettePhase, default (0.3,0.1,0)
//   CyclePalette  : cyclePalette (-1/0/1), default 1
//   RotatePalette : rotatePalette (0..100), default 0
//   RepeatPalette : repeatPalette (1..10), default 1
//   Levels        : levels (0..32), default 0
//   InputTex      : source A surface -> inputTex (color1)
//   Tex           : source B surface -> tex      (color2)
//   SS            : sampler state (bilinear, clamp, linear/non-sRGB) for both
//   UV            : 0..1 fragment UV (top-left origin, WGSL convention)
//
// The WGSL samples both textures at the SAME st (= fragCoord/resolution) and uses
// that same st for the procedural shape field. Here we sample both at the supplied
// UV with one shared sampler and pass UV as `st`, matching the equal-sized-surface
// case the runtime uses.
// =============================================================================

#include "../../Shaders/Effects/classicNoisedeck/ShapeMixer.hlsl"

void NM_ShapeMixer_float(
    int               BlendMode,
    int               LoopOffset,
    float             LoopScale,
    int               Wrap,
    int               Seed,
    int               Animate,
    int               Palette,
    int               PaletteMode,
    float3            PaletteOffset,
    float3            PaletteAmp,
    float3            PaletteFreq,
    float3            PalettePhase,
    int               CyclePalette,
    float             RotatePalette,
    int               RepeatPalette,
    int               Levels,
    UnityTexture2D    InputTex,
    UnityTexture2D    Tex,
    UnitySamplerState SS,
    float2            UV,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    blendMode     = BlendMode;
    LOOP_OFFSET   = LoopOffset;
    loopScale     = LoopScale;
    wrap          = Wrap;
    seed          = Seed;
    animate       = Animate;
    palette       = Palette;
    paletteMode   = PaletteMode;
    paletteOffset = PaletteOffset;
    paletteAmp    = PaletteAmp;
    paletteFreq   = PaletteFreq;
    palettePhase  = PalettePhase;
    cyclePalette  = CyclePalette;
    rotatePalette = RotatePalette;
    repeatPalette = RepeatPalette;
    levels        = Levels;

    float4 color1 = InputTex.Sample(SS, UV);
    float4 color2 = Tex.Sample(SS, UV);
    Out = nm_shapeMixer(color1, color2, UV);
}

#endif // NM_SHAPEMIXER_SG_INCLUDED
