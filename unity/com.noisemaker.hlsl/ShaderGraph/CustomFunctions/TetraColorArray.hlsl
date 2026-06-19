#ifndef NM_TETRACOLORARRAY_SG_INCLUDED
#define NM_TETRACOLORARRAY_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/TetraColorArray.hlsl
//
// Shader Graph Custom Function wrapper for filter/tetraColorArray.
// Add a Custom Function node, point it at this file, select NM_TetraColorArray_float,
// and wire the named inputs. Outputs RGBA.
//
// The core nm_tetraColorArray(...) reads parameters from module-scope named
// uniforms. This wrapper assigns node inputs to those globals before calling,
// bridging the named inputs into the core function.
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   ColorMode    : colorMode    (0=rgb,1=hsv,2=oklab,3=oklch), default 0
//   ColorCount   : colorCount   (2..8), default 6
//   PositionMode : positionMode (0=auto,1=manual), default 0
//   Repeat       : repeat       (0..10), default 1
//   Offset       : offset       (0..1), default 0
//   Alpha        : alpha        (0..1), default 1
//   Smoothness   : smoothness   (0..1), default 1
//   Rotation     : rotation     (-1/0/1), default 0
//   Color0..7    : color0..color7 (RGB), defaults: ROYGBVWK rainbow
//   Pos0..7      : pos0..pos7   (0..1 positions for manual mode)
//   InputTex     : source surface
//   SS           : sampler state (bilinear, clamp, linear/non-sRGB)
//   UV           : 0..1 fragment UV (top-left origin)
//   Time         : engine time (use NMFullscreen `time` or pass manually)
// =============================================================================

#include "../../Shaders/Effects/filter/TetraColorArray.hlsl"

void NM_TetraColorArray_float(
    int               ColorMode,
    int               ColorCount,
    int               PositionMode,
    float             Repeat,
    float             Offset,
    float             Alpha,
    float             Smoothness,
    float             Rotation,
    float3            Color0,
    float3            Color1,
    float3            Color2,
    float3            Color3,
    float3            Color4,
    float3            Color5,
    float3            Color6,
    float3            Color7,
    float             Pos0,
    float             Pos1,
    float             Pos2,
    float             Pos3,
    float             Pos4,
    float             Pos5,
    float             Pos6,
    float             Pos7,
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             Time,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    colorMode    = ColorMode;
    colorCount   = ColorCount;
    positionMode = PositionMode;
    repeat       = Repeat;
    offset       = Offset;
    alpha        = Alpha;
    smoothness   = Smoothness;
    rotation     = Rotation;
    color0       = Color0;
    color1       = Color1;
    color2       = Color2;
    color3       = Color3;
    color4       = Color4;
    color5       = Color5;
    color6       = Color6;
    color7       = Color7;
    pos0         = Pos0;
    pos1         = Pos1;
    pos2         = Pos2;
    pos3         = Pos3;
    pos4         = Pos4;
    pos5         = Pos5;
    pos6         = Pos6;
    pos7         = Pos7;

    float4 inputColor = InputTex.Sample(SS, UV);
    Out = nm_tetraColorArray(inputColor, Time);
}

#endif // NM_TETRACOLORARRAY_SG_INCLUDED
