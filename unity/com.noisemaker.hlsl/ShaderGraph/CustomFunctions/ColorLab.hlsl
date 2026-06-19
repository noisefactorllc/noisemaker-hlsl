#ifndef NM_COLORLAB_SG_INCLUDED
#define NM_COLORLAB_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/ColorLab.hlsl
//
// Shader Graph Custom Function wrapper for classicNoisedeck/colorLab. Single-pass
// filter, so it ships as a node: add a Custom Function node, point it at this
// file, select NM_ColorLab_float, and wire the named inputs + InputTex/SS/UV.
// Outputs RGBA.
//
// The core nm_colorLab(...) in Shaders/Effects/classicNoisedeck/ColorLab.hlsl
// reads its parameters from module-scope named uniforms (matching the runtime's
// individual-named-uniform binding model). In a standalone Shader Graph node those
// globals are not bound by the runtime, so this wrapper assigns the node inputs to
// them before calling nm_colorLab, bridging the named inputs into the core fn.
//
// NOTE on FragCoord: nm_colorLab needs the WGSL @builtin(position).xy for the
// dither/random/bayer terms. In Shader Graph we reconstruct it as UV * resolution
// (matching NM_FragCoord). `resolution`/`time` are NMFullscreen aliases bound by
// the runtime; supply UV in 0..1 top-left convention.
// =============================================================================

#include "../../Shaders/Effects/classicNoisedeck/ColorLab.hlsl"

void NM_ColorLab_float(
    int               ColorMode,
    int               Palette,
    int               PaletteMode,
    float3            PaletteOffset,
    float3            PaletteAmp,
    float3            PaletteFreq,
    float3            PalettePhase,
    int               CyclePalette,
    float             RotatePalette,
    int               RepeatPalette,
    float             HueRotation,
    float             HueRange,
    float             Saturation,
    int               Invert,
    float             Brightness,
    float             Contrast,
    int               Levels,
    int               Dither,
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    colorMode     = ColorMode;
    palette       = Palette;
    paletteMode   = PaletteMode;
    paletteOffset = PaletteOffset;
    paletteAmp    = PaletteAmp;
    paletteFreq   = PaletteFreq;
    palettePhase  = PalettePhase;
    cyclePalette  = CyclePalette;
    rotatePalette = RotatePalette;
    repeatPalette = RepeatPalette;
    hueRotation   = HueRotation;
    hueRange      = HueRange;
    saturation    = Saturation;
    invert        = Invert;
    brightness    = Brightness;
    contrast      = Contrast;
    levels        = Levels;
    dither        = Dither;

    float2 fragCoord = UV * resolution;
    float4 color = InputTex.Sample(SS, UV);
    Out = nm_colorLab(color, fragCoord);
}

#endif // NM_COLORLAB_SG_INCLUDED
