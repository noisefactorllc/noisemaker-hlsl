#ifndef NM_BITWISE_SG_INCLUDED
#define NM_BITWISE_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Bitwise.hlsl
//
// Shader Graph Custom Function wrapper for synth/bitwise. Add a Custom Function
// node, point it at this file, select NM_Bitwise_float, and wire the named
// inputs. Outputs RGBA.
//
// The core nm_bitwise() in Shaders/Effects/synth/Bitwise.hlsl reads params from
// named global uniforms. This wrapper bridges node inputs -> globals, then calls
// the core. Engine globals (resolution/fullResolution/renderScale/time/
// tileOffset) are set from the UV/Resolution/Time inputs for self-contained use.
// =============================================================================

#include "../../Shaders/Effects/synth/Bitwise.hlsl"

void NM_Bitwise_float(
    int    Operation,
    int    Mask,
    float  Scale,
    float  Rotation,
    int    OffsetX,
    int    OffsetY,
    int    Seed,
    int    Speed,
    int    ColorMode,
    int    ColorOffset,
    float2 UV,
    float2 Resolution,
    float  Time,
    out float4 Out)
{
    // Bridge node inputs -> the core's named global uniforms.
    operation   = Operation;
    mask        = Mask;
    scale       = Scale;
    rotation    = Rotation;
    offsetX     = OffsetX;
    offsetY     = OffsetY;
    seed        = Seed;
    speed       = Speed;
    colorMode   = ColorMode;
    colorOffset = ColorOffset;

    // Set engine globals so NMFullscreen aliases resolve correctly.
    _NM_Resolution     = float4(Resolution, 0.0, 0.0);
    _NM_FullResolution = float4(Resolution, 0.0, 0.0);
    _NM_TileOffset     = float4(0.0, 0.0, 0.0, 0.0);
    _NM_Time           = Time;
    _NM_RenderScale    = 1.0;

    // globalCoord = UV * resolution (pixel-centered at texel centers).
    // tileOffset = 0 for standalone node use.
    float2 globalCoord = UV * Resolution;
    Out = nm_bitwise(globalCoord);
}

#endif // NM_BITWISE_SG_INCLUDED
