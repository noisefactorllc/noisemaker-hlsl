#ifndef NM_OSC2D_SG_INCLUDED
#define NM_OSC2D_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Osc2d.hlsl
//
// Shader Graph Custom Function wrapper for synth/osc2d. Drops the effect in as
// a node: add a Custom Function node, point it at this file, select
// NM_Osc2d_float, and wire the named inputs. Outputs RGBA grayscale.
//
// The core nm_osc2d(...) in Shaders/Effects/synth/Osc2d.hlsl reads the effect
// parameters from named GLOBAL uniforms (oscType, frequency, speed, rotation,
// seed). In a Shader Graph node those globals are unbound, so this wrapper
// COPIES each node input into the corresponding global before calling the core.
// HLSL global uniforms declared without `static const` are mutable storage
// assignable from the entry function (standard Custom-Function bridging).
//
// Engine globals (fullResolution / aspect / time) are passed explicitly via the
// UV/Resolution/Time inputs so the node is self-contained and does not depend on
// NMFullscreen's per-frame globals being set.
//
//   OscType    : oscType   (enum 0..6)  -> int
//   Frequency  : freq       [1,32]      -> int
//   Speed      : speed      [0,10]      -> float
//   Rotation   : rotation   degrees     -> float
//   Seed       : seed       [0,1000]    -> int
//   UV         : 0..1 fragment UV (top-left origin, WGSL convention)
//   Resolution : render-target size in pixels (used as fullResolution; tileOffset 0)
//   Time       : normalized animation time
// =============================================================================

#include "../../Shaders/Effects/synth/Osc2d.hlsl"

void NM_Osc2d_float(
    int    OscType,
    int    Frequency,
    float  Speed,
    float  Rotation,
    int    Seed,
    float2 UV,
    float2 Resolution,
    float  Time,
    out float4 Out)
{
    // Bridge node inputs -> the core's named global uniforms.
    oscType   = OscType;
    frequency = Frequency;
    speed     = Speed;
    rotation  = Rotation;
    seed      = Seed;

    // aspect = fullResolution.x / fullResolution.y (the WGSL `aspect` uniform).
    float aspect = Resolution.x / Resolution.y;

    // globalCoord = UV * Resolution (pixel-centered when UV hits a texel center).
    // tileOffset = 0 for standalone node usage. fullResolution = Resolution.
    float2 globalCoord = UV * Resolution;
    Out = nm_osc2d(globalCoord, Resolution, aspect, Time);
}

#endif // NM_OSC2D_SG_INCLUDED
