#ifndef NM_SG_SHAPE_INCLUDED
#define NM_SG_SHAPE_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for synth/shape.
//
// Drop this into a Shader Graph "Custom Function" node (File mode), set the
// function name to `NM_Shape_float`, and wire the named inputs. The node calls
// the verbatim core `nm_shape(...)` from the effect HLSL.
//
// Shader Graph has no integer port, so every input is a `float`; ints are
// truncated and booleans are tested `> 0.5` (matching the WGSL bool packing).
// Each input is named after its definition.js global (uniform names) plus the
// two compile-time-define-promoted selectors (loopAOffset -> LOOP_A_OFFSET,
// loopBOffset -> LOOP_B_OFFSET). UV/Resolution/Time are the engine inputs.
//
// UV is the canonical top-left fullscreen UV (0..1); Resolution is the full
// (untiled) render size in pixels (used as fullResolution; tileOffset is 0 in
// the Shader-Graph single-pass case). st divides by HEIGHT (.y) — PORTING-GUIDE H13.
// =============================================================================

// Resolve include relative to this file's location in the package.
#include "../../Shaders/Effects/synth/Shape.hlsl"

void NM_Shape_float(
    float  In_loopAOffset,  // -> LOOP_A_OFFSET (default 40)
    float  In_loopBOffset,  // -> LOOP_B_OFFSET (default 30)
    float  In_loopAScale,
    float  In_loopBScale,
    float  In_speedA,
    float  In_speedB,
    float  In_seed,
    float  In_wrap,         // boolean as 0/1 float; tested > 0.5
    float  In_time,
    float2 UV,
    float2 Resolution,
    out float4 Out)
{
    // globalCoord = UV * Resolution (pixel-space, top-left). tileOffset = 0.
    float2 globalCoord = UV * Resolution;
    float2 st     = globalCoord / Resolution.y;
    float2 stBase = globalCoord / Resolution.y;
    float  aspect = Resolution.x / Resolution.y;

    Out = nm_shape(st, stBase,
                   (int)In_loopAOffset, (int)In_loopBOffset,
                   In_loopAScale, In_loopBScale,
                   In_speedA, In_speedB,
                   In_seed, (In_wrap > 0.5), In_time, aspect);
}

#endif // NM_SG_SHAPE_INCLUDED
