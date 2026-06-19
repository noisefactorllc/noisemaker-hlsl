#ifndef NM_CAUSTIC_SG_INCLUDED
#define NM_CAUSTIC_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Caustic.hlsl
//
// Shader Graph Custom Function wrapper for classicNoisedeck/caustic. Add a
// Custom Function node, point it at this file, select NM_Caustic_float, and
// wire the named inputs. Outputs RGBA. Single-pass generator.
//
// The core nm_caustic(...) in Shaders/Effects/classicNoisedeck/Caustic.hlsl
// reads effect parameters from named GLOBAL uniforms (noiseScale, speed, wrap,
// seed, hueRotation, hueRange, intensity, NOISE_TYPE) plus the engine `time`
// alias. In a node those globals are unbound, so this wrapper copies each node
// input into the corresponding global before calling the core.
//
//   NoiseType    : interp (enum; 0,1,2,3,4,5,6,10,11) -> NOISE_TYPE
//   NoiseScale   : noiseScale [1,200]
//   Speed        : speed [0,100]
//   Wrap         : wrap (0/1)
//   Seed         : seed [0,100]
//   HueRotation  : hueRotation [0,360]
//   HueRange     : hueRange [0,100]
//   Intensity    : intensity [-100,100]
//   UV           : 0..1 fragment UV (top-left origin, WGSL convention)
//   Resolution   : render-target size in px (used as fullResolution; the core
//                  divides by Resolution.y and uses the x/y aspect)
//   Time         : normalized animation time
// =============================================================================

#include "../../Shaders/Effects/classicNoisedeck/Caustic.hlsl"

void NM_Caustic_float(
    int   NoiseType,
    float NoiseScale,
    float Speed,
    int   Wrap,
    int   Seed,
    float HueRotation,
    float HueRange,
    float Intensity,
    float2 UV,
    float2 Resolution,
    float  Time,
    out float4 Out)
{
    // Bridge node inputs -> the core's named global uniforms.
    NOISE_TYPE  = NoiseType;
    noiseScale  = NoiseScale;
    speed       = Speed;
    wrap        = Wrap;
    seed        = Seed;
    hueRotation = HueRotation;
    hueRange    = HueRange;
    intensity   = Intensity;

    // The core reads the engine `time` alias (_NM_Time) inside the value-noise
    // path; seed it from the Time input so the node is self-contained.
    _NM_Time           = Time;
    _NM_Resolution     = float4(Resolution, 0.0, 0.0);
    _NM_FullResolution = float4(Resolution, 0.0, 0.0);

    // globalCoord = UV * Resolution (pixel-centered when UV hits a texel center);
    // tileOffset = 0 for standalone node usage. fullResolution = Resolution.
    float2 globalCoord = UV * Resolution;
    Out = nm_caustic(globalCoord, Resolution);
}

#endif // NM_CAUSTIC_SG_INCLUDED
