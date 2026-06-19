#ifndef NM_SACREDGEOMETRY_SG_INCLUDED
#define NM_SACREDGEOMETRY_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/SacredGeometry.hlsl
//
// Shader Graph Custom Function wrapper for synth/sacredGeometry.
// Add a Custom Function node, point it at this file, select
// NM_SacredGeometry_float, and wire the named inputs. Outputs RGBA.
//
// The core nm_sacredGeometry() reads effect parameters from named global
// uniforms. This wrapper bridges node inputs to those globals before calling.
// Engine globals (resolution/aspectRatio/time) are seeded from the
// Resolution/Time inputs so the node is self-contained.
// =============================================================================

#include "../../Shaders/Effects/synth/SacredGeometry.hlsl"

void NM_SacredGeometry_float(
    float2  UV,
    float2  Resolution,
    float   Time,
    int     Geometry,
    float   Scale,
    int     Rings,
    int     StarPoints,
    float   Rotation,
    float   Thickness,
    float   Smoothness,
    float3  FgColor,
    float3  BgColor,
    int     Animation,
    int     Speed,
    float   PulseDepth,
    out float4 Out)
{
    // Bridge node inputs -> the core's named global uniforms.
    geometry   = Geometry;
    scale      = Scale;
    rings      = Rings;
    starPoints = StarPoints;
    rotation   = Rotation;
    thickness  = Thickness;
    smoothness = Smoothness;
    fgColor    = FgColor;
    bgColor    = BgColor;
    animation  = Animation;
    speed      = Speed;
    pulseDepth = PulseDepth;

    // Seed engine globals so aspectRatio/resolution/time resolve correctly.
    _NM_Resolution     = float4(Resolution, 0.0, 0.0);
    _NM_FullResolution = float4(Resolution, 0.0, 0.0);
    _NM_Time           = Time;

    // globalCoord = UV * resolution (pixel-centered texel coordinates).
    float2 globalCoord = UV * Resolution;
    Out = nm_sacredGeometry(globalCoord);
}

#endif // NM_SACREDGEOMETRY_SG_INCLUDED
