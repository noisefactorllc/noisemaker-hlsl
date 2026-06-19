#ifndef NM_NOISE3D_SG_INCLUDED
#define NM_NOISE3D_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Noise3d.hlsl
//
// Shader Graph Custom Function wrapper for classicNoisedeck/noise3d. Drops the
// effect in as a node: add a Custom Function node, point it at this file, select
// NM_Noise3d_float, and wire the named inputs. Outputs RGBA.
//
// The core nm_noise3d(...) in Shaders/Effects/classicNoisedeck/Noise3d.hlsl
// reads the effect parameters from named GLOBAL uniforms (NOISE_TYPE, ridges,
// seed, ...). In a Shader Graph node those globals are unbound, so this wrapper
// COPIES each node input into the corresponding global before calling the core.
//
// Engine globals (resolution/time/fullResolution) are passed explicitly via the
// UV/Resolution/Time inputs so the node is self-contained.
// =============================================================================

#include "../../Shaders/Effects/classicNoisedeck/Noise3d.hlsl"

// Map each global param (definition.js globals[*].uniform) to a named input.
//   NoiseType   : type   (enum; default 12 = simplex)
//   Ridges      : ridges (0/1; only affects simplex)
//   Seed        : seed
//   Speed       : speed
//   Scale       : scale
//   OffsetX     : offsetX
//   OffsetY     : offsetY
//   ColorMode   : colorMode (enum)
//   HueRotation : hueRotation (degrees)
//   HueRange    : hueRange
//   UV          : 0..1 fragment UV (top-left origin, WGSL convention)
//   Resolution  : render-target size in pixels (used as both resolution and
//                 fullResolution; tileOffset assumed 0 for node usage)
//   Time        : normalized animation time
void NM_Noise3d_float(
    int   NoiseType,
    int   Ridges,
    int   Seed,
    int   Speed,
    float Scale,
    float OffsetX,
    float OffsetY,
    int   ColorMode,
    float HueRotation,
    float HueRange,
    float2 UV,
    float2 Resolution,
    float  Time,
    out float4 Out)
{
    // Bridge node inputs -> the core's named global uniforms.
    NOISE_TYPE  = NoiseType;
    ridges      = Ridges;
    seed        = Seed;
    speed       = Speed;
    scale       = Scale;
    offsetX     = OffsetX;
    offsetY     = OffsetY;
    colorMode   = ColorMode;
    hueRotation = HueRotation;
    hueRange    = HueRange;

    // globalCoord = UV * Resolution (pixel-centered when UV hits a texel center).
    // tileOffset = 0 for standalone node usage. fullResolution = Resolution.
    float2 globalCoord = UV * Resolution;
    Out = nm_noise3d(globalCoord, Resolution, Time);
}

#endif // NM_NOISE3D_SG_INCLUDED
