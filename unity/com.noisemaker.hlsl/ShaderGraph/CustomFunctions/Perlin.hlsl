#ifndef NM_SG_PERLIN_INCLUDED
#define NM_SG_PERLIN_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for synth/perlin.
//
// Drops the effect into Shader Graph as a node. Each global param from
// definition.js maps to a named input:
//   Scale          -> scale          (float)
//   Octaves        -> octaves        (int)
//   ColorMode      -> colorMode      (int: 0 mono, 1 rgb)
//   Dimensions     -> dimensions     (int: 2 or 3; DIMENSIONS define)
//   Ridges         -> ridges         (int boolean 0/1)
//   WarpIterations -> warpIterations (int 0..4)
//   WarpScale      -> warpScale      (float)
//   WarpIntensity  -> warpIntensity  (float)
//   Seed           -> seed           (int)
//   Speed          -> speed          (float; UI int 0..5)
// UV (0..1) + Resolution map to the full-resolution pixel coordinate the WGSL
// main() uses (globalCoord = UV*Resolution; tileOffset is 0 in the node case).
// Time supplies the WGSL `time` (0..1 loop position).
//
// Reuses the verbatim core in Shaders/Effects/synth/Perlin.hlsl. That file
// declares the per-effect params as mutable global uniforms which the core
// helpers read; here we assign the node inputs into them before calling
// nm_perlin(). Includable / guarded so it is safe inside a Custom Function node.
// =============================================================================

#include "../../Shaders/Effects/synth/Perlin.hlsl"

void NM_Perlin_float(
    float  Scale,
    int    Octaves,
    int    ColorMode,
    int    Dimensions,
    int    Ridges,
    int    WarpIterations,
    float  WarpScale,
    float  WarpIntensity,
    int    Seed,
    float  Speed,
    float  Time,
    float2 UV,
    float2 Resolution,
    out float4 Out)
{
    // Bind the node inputs into the core's per-effect uniforms.
    scale          = Scale;
    octaves        = Octaves;
    colorMode      = ColorMode;
    dimensions     = Dimensions;
    ridges         = Ridges;
    warpIterations = WarpIterations;
    warpScale      = WarpScale;
    warpIntensity  = WarpIntensity;
    seed           = Seed;
    speed          = Speed;

    // globalCoord = UV * Resolution (pixel coords; node tileOffset == 0).
    float2 globalCoord = UV * Resolution;
    float  aspect      = Resolution.x / Resolution.y;

    Out = nm_perlin(globalCoord, Resolution, aspect, Time);
}

#endif // NM_SG_PERLIN_INCLUDED
