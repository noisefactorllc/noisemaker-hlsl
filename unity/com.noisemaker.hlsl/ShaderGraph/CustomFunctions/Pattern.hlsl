#ifndef NM_PATTERN_SG_INCLUDED
#define NM_PATTERN_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Pattern.hlsl
//
// Shader Graph Custom Function wrapper for synth/pattern. Add a Custom Function
// node, point it at this file, select NM_Pattern_float, and wire the named
// inputs. Outputs RGBA.
//
// The core nm_pattern() in Shaders/Effects/synth/Pattern.hlsl reads effect
// params from named global uniforms. This wrapper copies each node input into
// the corresponding global before calling the core, following the same
// bridging pattern used by Gradient.hlsl (SG wrapper).
// =============================================================================

#include "../../Shaders/Effects/synth/Pattern.hlsl"

void NM_Pattern_float(
    float2  UV,
    float2  Resolution,
    float   Time,
    int     PatternType,
    float   Scale,
    float   Thickness,
    float   Smoothness,
    float   Rotation,
    float   Skew,
    int     Animation,
    int     Speed,
    float3  FgColor,
    float3  BgColor,
    out float4 Out)
{
    // Bridge node inputs -> core's named global uniforms.
    patternType = PatternType;
    scale       = Scale;
    thickness   = Thickness;
    smoothness  = Smoothness;
    rotation    = Rotation;
    skew        = Skew;
    animation   = Animation;
    speed       = Speed;
    fgColor     = FgColor;
    bgColor     = BgColor;

    // Seed engine globals so aspectRatio (#define alias) resolves correctly.
    _NM_Resolution     = float4(Resolution, 0.0, 0.0);
    _NM_FullResolution = float4(Resolution, 0.0, 0.0);
    _NM_Time           = Time;

    // fragCoord = UV * Resolution (pixel-centered texel). tileOffset = 0.
    float2 fragCoord = UV * Resolution;
    Out = nm_pattern(fragCoord);
}

#endif // NM_PATTERN_SG_INCLUDED
