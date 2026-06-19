#ifndef NM_POSTERIZE_SG_INCLUDED
#define NM_POSTERIZE_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Posterize.hlsl
//
// Shader Graph Custom Function wrapper for filter/posterize. Drops the effect in
// as a node: add a Custom Function node, point it at this file, select
// NM_Posterize_float, and wire the named inputs. Outputs RGBA.
//
// The core nm_posterize(...) in Shaders/Effects/filter/Posterize.hlsl reads the
// effect parameters from named GLOBAL uniforms (levels, gamma, antialias). In a
// Shader Graph node those globals are unbound, so this wrapper COPIES each node
// input into the corresponding global before calling the core. HLSL global
// uniforms declared without `static const` are mutable storage assignable from
// the entry function (standard Custom-Function bridging pattern).
//
// nm_posterize uses fwidth() on the antialias path, which requires screen-space
// derivatives — valid in a fragment-stage Custom Function node.
//
//   Levels    : levels    (int, [2,32], default 5)  -> float in core math
//   Gamma     : gamma      (float, [0.1,3], default 1)
//   Antialias : antialias  (bool toggle, default 1)  -> int, tested != 0
//   InputTex  : source surface to posterize
//   SS        : sampler state (bilinear, clamp, linear/non-sRGB) for InputTex
//   UV        : 0..1 fragment UV (top-left origin, WGSL convention)
// =============================================================================

#include "../../Shaders/Effects/filter/Posterize.hlsl"

void NM_Posterize_float(
    int               Levels,
    float             Gamma,
    int               Antialias,
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    out float4        Out)
{
    // Bridge node inputs -> the core's named global uniforms.
    // `levels` is f32 in the WGSL math (max/round operate on float); the int
    // node input promotes exactly for the non-negative range used.
    levels    = (float)Levels;
    gamma     = Gamma;
    antialias = Antialias;

    float4 texel = InputTex.Sample(SS, UV);
    Out = nm_posterize(texel);
}

#endif // NM_POSTERIZE_SG_INCLUDED
