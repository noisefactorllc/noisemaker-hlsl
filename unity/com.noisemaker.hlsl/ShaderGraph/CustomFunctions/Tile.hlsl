#ifndef NM_TILE_SG_INCLUDED
#define NM_TILE_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Tile.hlsl
//
// Shader Graph Custom Function wrapper for filter/tile. Add a Custom Function
// node, point it at this file, select NM_Tile_float, and wire the inputs.
//
// Inputs mirror definition.js globals[*].uniform plus the source texture.
//   InputTex   : source surface to tile (UnityTexture2D)
//   SS         : sampler state (bilinear, clamp, linear/non-sRGB)
//   UV         : 0..1 fragment UV (top-left origin, WGSL convention)
//   Resolution : render target pixel size (for NM_FragCoord equivalent:
//                fragCoord = UV * Resolution, then divided by tex dimensions)
//   Symmetry   : int 0=mirrorXY 1=rotate2 2=rotate4 3=rotate6
//   Scale      : float [0.1, 4.0]
//   OffsetX    : float [-1, 1]
//   OffsetY    : float [-1, 1]
//   Angle      : float [0, 360] degrees
//   Repeat     : float [1, 10]
//   AspectLens : int (1 = true)
//
// NOTE: filter/tile is SINGLE-PASS, so a Shader Graph wrapper is valid.
// =============================================================================

#include "../../Shaders/Effects/filter/Tile.hlsl"

void NM_Tile_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float2            Resolution,
    int               Symmetry,
    float             Scale,
    float             OffsetX,
    float             OffsetY,
    float             Angle,
    float             Repeat,
    int               AspectLens,
    out float4        Out)
{
    // Bind uniforms used by nm_tile_frag (declared as globals in Tile.hlsl).
    symmetry   = Symmetry;
    scale      = Scale;
    offsetX    = OffsetX;
    offsetY    = OffsetY;
    angle      = Angle;
    repeat     = Repeat;
    aspectLens = AspectLens;

    // Derive fragCoord and texSize from the UnityTexture2D.
    // fragCoord mirrors NM_FragCoord: pixel-centered = UV * Resolution.
    float2 fragCoord = UV * Resolution;

    uint tw, th;
    InputTex.tex.GetDimensions(tw, th);
    float2 texSize = float2((float)tw, (float)th);

    Out = nm_tile_frag(InputTex.tex, SS.samplerstate, fragCoord, texSize);
}

#endif // NM_TILE_SG_INCLUDED
