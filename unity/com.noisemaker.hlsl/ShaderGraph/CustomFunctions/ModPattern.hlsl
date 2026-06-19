#ifndef NM_MODPATTERN_SG_INCLUDED
#define NM_MODPATTERN_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/ModPattern.hlsl
//
// Shader Graph Custom Function wrapper for synth/modPattern. Add a Custom
// Function node, point it at this file, select NM_ModPattern_float, and wire
// the named inputs. Outputs RGBA.
//
// The core nm_modPattern() in Shaders/Effects/synth/ModPattern.hlsl reads
// effect parameters from named global uniforms. This wrapper copies each node
// input into the corresponding global before calling the core — the standard
// Custom-Function bridging pattern.
//
// Engine globals (resolution, time) are passed explicitly via UV/Resolution/Time
// so the node is self-contained without NMFullscreen's per-frame globals.
// =============================================================================

#include "../../Shaders/Effects/synth/ModPattern.hlsl"

void NM_ModPattern_float(
    int    Shape1,
    float  Scale1,
    float  Repeat1,
    int    Shape2,
    float  Scale2,
    float  Repeat2,
    int    Shape3,
    float  Scale3,
    float  Repeat3,
    int    Blend,
    float  Smoothing,
    int    AnimMode,
    int    Speed,
    float2 UV,
    float2 Resolution,
    float  Time,
    out float4 Out)
{
    // Bridge node inputs -> the core's named global uniforms.
    shape1    = Shape1;
    scale1    = Scale1;
    repeat1   = Repeat1;
    shape2    = Shape2;
    scale2    = Scale2;
    repeat2   = Repeat2;
    shape3    = Shape3;
    scale3    = Scale3;
    repeat3   = Repeat3;
    blend     = Blend;
    smoothing = Smoothing;
    animMode  = AnimMode;
    speed     = Speed;

    // Seed engine globals so nm_modPattern()'s `resolution` and `time` aliases
    // resolve correctly inside a Shader Graph node context.
    _NM_Resolution     = float4(Resolution, 0.0, 0.0);
    _NM_FullResolution = float4(Resolution, 0.0, 0.0);
    _NM_Time           = Time;

    // fragCoord = UV * Resolution (pixel-centered at texel centers).
    // tileOffset = 0 for standalone node usage.
    float2 fragCoord = UV * Resolution;
    Out = nm_modPattern(fragCoord);
}

#endif // NM_MODPATTERN_SG_INCLUDED
