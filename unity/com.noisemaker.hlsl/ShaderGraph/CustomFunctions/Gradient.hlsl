#ifndef NM_GRADIENT_SG_INCLUDED
#define NM_GRADIENT_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Gradient.hlsl
//
// Shader Graph Custom Function wrapper for synth/gradient. Drops the effect in
// as a node: add a Custom Function node, point it at this file, select
// NM_Gradient_float, and wire the named inputs. Outputs RGBA.
//
// The core nm_gradient(...) in Shaders/Effects/synth/Gradient.hlsl reads the
// effect parameters from named GLOBAL uniforms (rotation, gradientType, ...).
// In a Shader Graph node those globals are unbound, so this wrapper COPIES each
// node input into the corresponding global before calling the core. HLSL global
// uniforms declared without `static const` are mutable storage assignable from
// the entry function, which is the standard Custom-Function bridging pattern.
//
// Engine globals (resolution/time/fullResolution) are passed explicitly via the
// UV/Resolution/Time inputs so the node is self-contained and does not depend on
// NMFullscreen's per-frame globals being set.
// =============================================================================

#include "../../Shaders/Effects/synth/Gradient.hlsl"

// Map each global param (definition.js globals[*].uniform) to a named input.
//   GradientType : type   (enum 0..6)
//   Rotation     : rotation (degrees)
//   Repeat       : repeat
//   ColorCount   : colorCount
//   Speed        : speed
//   Seed         : seed
//   Color1..4    : color1..color4
//   UV           : 0..1 fragment UV (top-left origin, WGSL convention)
//   Resolution   : render-target size in pixels (used as both resolution and
//                  fullResolution; tileOffset assumed 0 for node usage)
//   Time         : normalized animation time
void NM_Gradient_float(
    int   GradientType,
    float Rotation,
    int   Repeat,
    int   ColorCount,
    int   Speed,
    int   Seed,
    float3 Color1,
    float3 Color2,
    float3 Color3,
    float3 Color4,
    float2 UV,
    float2 Resolution,
    float  Time,
    out float4 Out)
{
    // Bridge node inputs -> the core's named global uniforms.
    gradientType = GradientType;
    rotation     = Rotation;
    repeat       = Repeat;
    colorCount   = ColorCount;
    speed        = Speed;
    seed         = Seed;
    color1       = Color1;
    color2       = Color2;
    color3       = Color3;
    color4       = Color4;

    // nmg_rotate2D() reads the engine globals `resolution`/`fullResolution`
    // (NMFullscreen aliases for _NM_Resolution/_NM_FullResolution). In a Shader
    // Graph node those are unbound, so seed them from the Resolution input to
    // keep the aspect-correct rotation consistent with the explicit args below.
    _NM_Resolution     = float4(Resolution, 0.0, 0.0);
    _NM_FullResolution = float4(Resolution, 0.0, 0.0);

    // globalCoord = UV * resolution (pixel-centered when UV hits a texel center).
    // tileOffset = 0 for standalone node usage. fullResolution = Resolution.
    float2 globalCoord = UV * Resolution;
    Out = nm_gradient(globalCoord, Resolution, Resolution, Time);
}

#endif // NM_GRADIENT_SG_INCLUDED
