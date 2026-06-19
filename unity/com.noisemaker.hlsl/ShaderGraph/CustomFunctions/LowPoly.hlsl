#ifndef NM_LOWPOLY_SG_INCLUDED
#define NM_LOWPOLY_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/LowPoly.hlsl
//
// Shader Graph Custom Function wrapper for filter/lowPoly (single render pass).
// Add a Custom Function node, point it at this file, select NM_LowPoly_float,
// and wire the named inputs + InputTex/SS/UV/Resolution. Outputs RGBA.
//
// The core nm_lowpoly(...) in Shaders/Effects/filter/LowPoly.hlsl reads its scalar
// parameters from module-scope named uniforms (scale/seed/mode/edgeStrength/
// edgeColor/alpha/speed) and engine globals (fullResolution/tileOffset/time) —
// matching the runtime's individual-named-uniform binding model. In a standalone
// Shader Graph node those globals are not bound by the runtime, so this wrapper
// assigns the node inputs to them before calling nm_lowpoly, bridging the named
// inputs into the core function.
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   Scale        : scale        (2..100),            default 50
//   Seed         : seed         (1..100),            default 1
//   Mode         : mode         (0 flat,1 edges,2 distance2,3 distance3), default 1
//   EdgeStrength : edgeStrength (0..1),              default 0.15
//   EdgeColor    : edgeColor    (RGB, linear),       default (0,0,0)
//   Alpha        : alpha        (0..1),              default 1.0
//   Speed        : speed        (0..5),              default 0
//   Resolution   : full (untiled) target size in px; drives aspect + cell mapping.
//                  For an untiled node, set Resolution to the texture size.
//   Time         : normalized animation time (0..1); only used when Speed > 0.
//   InputTex     : source surface
//   SS           : sampler state (bilinear, clamp, linear/non-sRGB) for InputTex
//   UV           : 0..1 fragment UV (top-left origin, WGSL convention)
//
// TODO(verify): standalone-node use assumes tileOffset = (0,0) (untiled). The
// runtime render pass uses the engine _NM_TileOffset; the multi-tile path is only
// exercised by the C# runtime, not this single-node wrapper.
// =============================================================================

#include "../../Shaders/Effects/filter/LowPoly.hlsl"

void NM_LowPoly_float(
    int               Scale,
    int               Seed,
    int               Mode,
    float             EdgeStrength,
    float3            EdgeColor,
    float             Alpha,
    int               Speed,
    float2            Resolution,
    float             Time,
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    scale        = Scale;
    seed         = Seed;
    mode         = Mode;
    edgeStrength = EdgeStrength;
    edgeColor    = EdgeColor;
    alpha        = Alpha;
    speed        = Speed;

    // Bridge engine globals consumed by the core (fullResolution/tileOffset/time).
    _NM_FullResolution = float4(Resolution, 0.0, 0.0);
    _NM_TileOffset     = float4(0.0, 0.0, 0.0, 0.0);
    _NM_Time           = Time;

    // texSize = the INPUT TEXTURE's own dimensions (WGSL textureDimensions).
    uint tw, th;
    InputTex.tex.GetDimensions(tw, th);
    float2 texSize = float2(tw, th);

    // uv       = pos.xy / texSize ; for a 0..1 node UV at full-res, pos.xy = UV*Resolution.
    // globalUV = (pos.xy + tileOffset) / fullResolution = UV (tileOffset = 0).
    float2 pos      = UV * Resolution;
    float2 uv       = pos / texSize;
    float2 globalUV = UV;

    Out = nm_lowpoly(InputTex.tex, SS.samplerstate, texSize, uv, globalUV);
}

#endif // NM_LOWPOLY_SG_INCLUDED
