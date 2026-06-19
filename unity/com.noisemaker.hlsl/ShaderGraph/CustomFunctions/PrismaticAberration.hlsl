#ifndef NM_PRISMATIC_ABERRATION_SG_INCLUDED
#define NM_PRISMATIC_ABERRATION_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/PrismaticAberration.hlsl
//
// Shader Graph Custom Function wrapper for filter/prismaticAberration. Add a
// Custom Function node pointing at this file and select NM_PrismaticAberration_float.
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   AberrationAmt : aberrationAmt (0..100), default 50
//   Modulate      : modulate (0=off, 1=on), default 0
//   HueRotation   : hueRotation (-180..180), default 0
//   HueRange      : hueRange (0..100), default 0
//   Saturation    : saturation (-100..100), default 0
//   Passthru      : passthru (0..100), default 50
//   InputTex      : source surface (UnityTexture2D)
//   SS            : sampler state (bilinear, clamp, linear/non-sRGB)
//   UV            : 0..1 fragment UV (top-left origin, WGSL convention)
//   Resolution    : render target size in pixels (float2)
// =============================================================================

#include "../../Shaders/Effects/filter/PrismaticAberration.hlsl"

void NM_PrismaticAberration_float(
    float             AberrationAmt,
    int               Modulate,
    float             HueRotation,
    float             HueRange,
    float             Saturation,
    float             Passthru,
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float2            Resolution,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    aberrationAmt = AberrationAmt;
    modulate      = Modulate;
    hueRotation   = HueRotation;
    hueRange      = HueRange;
    saturation    = Saturation;
    passthru      = Passthru;

    // Reconstruct fragCoord from UV and Resolution (matching NM_FragCoord convention).
    float2 fragCoord = UV * Resolution;
    Out = nm_prismaticAberration(InputTex, SS, fragCoord);
}

#endif // NM_PRISMATIC_ABERRATION_SG_INCLUDED
