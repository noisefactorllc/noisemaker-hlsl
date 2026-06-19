#ifndef NM_CURL_SG_INCLUDED
#define NM_CURL_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Curl.hlsl
//
// Shader Graph Custom Function wrapper for synth/curl. Add a Custom Function
// node, point it at this file, select NM_Curl_float, and wire the named
// inputs. Outputs RGBA.
//
// Engine globals (resolution, fullResolution, time, tileOffset) are seeded
// from the Resolution and Time inputs so the node is self-contained.
// =============================================================================

#include "../../Shaders/Effects/synth/Curl.hlsl"

void NM_Curl_float(
    float2 UV,
    float2 Resolution,
    float  Time,
    float  Scale,
    int    Seed,
    float  Speed,
    float  Intensity,
    int    Octaves,
    int    Ridges,
    int    OutputMode,
    out float4 Out)
{
    // Bridge node inputs -> the core's named global uniforms.
    scale      = Scale;
    seed       = Seed;
    speed      = Speed;
    intensity  = Intensity;
    OCTAVES     = Octaves;
    RIDGES      = Ridges;
    OUTPUT_MODE = OutputMode;

    // Seed engine globals for standalone node usage (tileOffset = 0).
    _NM_Resolution     = float4(Resolution, 0.0, 0.0);
    _NM_FullResolution = float4(Resolution, 0.0, 0.0);
    _NM_TileOffset     = float4(0.0, 0.0, 0.0, 0.0);
    _NM_Time           = Time;

    // nm_curl() adds tileOffset internally; pass fragCoord = UV * Resolution.
    float2 fragCoord = UV * Resolution;
    Out = nm_curl(fragCoord);
}

#endif // NM_CURL_SG_INCLUDED
