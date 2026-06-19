#ifndef NM_WOBBLE_SG_INCLUDED
#define NM_WOBBLE_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Wobble.hlsl
//
// Shader Graph Custom Function wrapper for filter/wobble. Drops the effect in as
// a node: add a Custom Function node, point it at this file, select
// NM_Wobble_float, and wire the named inputs + InputTex/SS/UV. Outputs RGBA.
//
// The core nm_wobble(...) in Shaders/Effects/filter/Wobble.hlsl reads its scalar
// parameters from module-scope named uniforms (speed/range/wrap) — matching the
// runtime's individual-named-uniform binding model. In a standalone Shader Graph
// node those globals are not bound by the runtime, so this wrapper assigns the
// node inputs to them before calling nm_wobble, bridging the named inputs into
// the core function. `time` is normally an engine global aliased by NMFullscreen;
// here it is exposed as a node input (Time) and assigned to that alias target.
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   Speed : speed (0..5),  default 5.0
//   Range : range (0..5),  default 0.5
//   Wrap  : wrap  (0 mirror,1 repeat,2 clamp), default 0
//   Time  : normalized 0..1 animation time (engine global `time`)
//   InputTex : source surface to wobble
//   SS       : sampler state (bilinear, clamp, linear/non-sRGB) for InputTex
//   UV       : 0..1 fragment UV (top-left origin, WGSL convention)
// =============================================================================

// NOTE: nm_wobble references `time` (the NMFullscreen alias for _NM_Time). In a
// standalone Shader Graph node the runtime does not set _NM_Time, so feed the
// node's Time input. We cannot reassign the #define alias, so set the backing
// engine global directly before the call.
#include "../../Shaders/Effects/filter/Wobble.hlsl"

void NM_Wobble_float(
    float             Speed,
    float             Range,
    int               Wrap,
    float             Time,
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    speed = Speed;
    range = Range;
    wrap  = Wrap;
    // `time` is #define time (_NM_Time); set the backing global so the alias resolves.
    _NM_Time = Time;

    Out = nm_wobble(InputTex.tex, SS.samplerstate, UV);
}

#endif // NM_WOBBLE_SG_INCLUDED
