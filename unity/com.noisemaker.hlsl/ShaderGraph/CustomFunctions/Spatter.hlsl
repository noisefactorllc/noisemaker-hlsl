#ifndef NM_SPATTER_SG_INCLUDED
#define NM_SPATTER_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Spatter.hlsl
//
// Shader Graph Custom Function wrapper for filter/spatter. Drops the effect in as
// a node: add a Custom Function node, point it at this file, select
// NM_Spatter_float, and wire the named inputs + InputTex/SS/UV/Resolution.
//
// The core nm_spatter(...) in Shaders/Effects/filter/Spatter.hlsl reads its
// parameters from module-scope named uniforms (color/density/alpha/seed) and the
// engine globals (fullResolution, used for aspect correction). In a standalone
// Shader Graph node those are not bound by the runtime, so this wrapper assigns
// the node inputs to them before calling nm_spatter.
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   Color    : color (RGB, linear/non-sRGB), default (0.875,0.125,0.125)
//   Density  : density (0..1),                default 0.5
//   Alpha    : alpha   (0..1),                default 0.75
//   Seed     : seed    (int, 1..100),         default 1
//   InputTex : source surface to spatter over
//   SS       : sampler state (bilinear, clamp, linear/non-sRGB) for InputTex
//   UV       : 0..1 fragment UV (top-left origin, WGSL convention) — used as both
//              the sample coord and the noise coord (matches the WGSL fullResolution
//              UV; tileOffset assumed 0 for node usage)
//   Resolution : render-target size in pixels (seeds fullResolution for aspect)
// =============================================================================

#include "../../Shaders/Effects/filter/Spatter.hlsl"

void NM_Spatter_float(
    float3            Color,
    float             Density,
    float             Alpha,
    int               Seed,
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float2            Resolution,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    color   = Color;
    density = Density;
    alpha   = Alpha;
    seed    = Seed;

    // nm_spatter reads fullResolution (NMFullscreen alias for _NM_FullResolution)
    // for aspect correction. In a Shader Graph node it is unbound, so seed it from
    // the Resolution input. tileOffset assumed 0; fullResolution = Resolution.
    _NM_Resolution     = float4(Resolution, 0.0, 0.0);
    _NM_FullResolution = float4(Resolution, 0.0, 0.0);

    float4 base = InputTex.Sample(SS, UV);
    Out = nm_spatter(base, UV);
}

#endif // NM_SPATTER_SG_INCLUDED
