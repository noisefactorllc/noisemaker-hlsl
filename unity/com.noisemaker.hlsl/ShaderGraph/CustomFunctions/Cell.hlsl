#ifndef NM_CELL_SG_INCLUDED
#define NM_CELL_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Cell.hlsl
//
// Shader Graph Custom Function wrapper for synth/cell. Drops the effect in as a
// node: add a Custom Function node, point it at this file, select NM_Cell_float,
// and wire the named inputs. Outputs RGBA (mono distance field).
//
// Unlike gradient, the core nm_cell(...) in Shaders/Effects/synth/Cell.hlsl is
// FULLY PARAMETERIZED (it reads no global uniforms), so this wrapper passes each
// node input straight through — no global bridging required. Engine globals
// (time/fullResolution) are supplied via the Time/Resolution inputs so the node
// is self-contained and does not depend on NMFullscreen's per-frame globals.
//
// Coordinate parity: the runtime computes st = (fragCoord + tileOffset) /
// fullResolution.y. In a standalone node there is no tiling, so fragCoord =
// UV * Resolution and tileOffset = 0, giving st = (UV * Resolution) /
// Resolution.y. aspect = Resolution.x / Resolution.y (H13).
// =============================================================================

#include "../../Shaders/Effects/synth/Cell.hlsl"

// Map each global param (definition.js globals[*].uniform) to a named input.
//   Shape      : shape   (uniform "metric"; enum 0,1,2,3,4,6)
//   Scale      : scale       (1..100)
//   CellScale  : cellScale   (1..100)
//   CellSmooth : cellSmooth  (0..100)
//   Variation  : variation   (0..100)
//   Speed      : speed        (0..5, floored inside cells())
//   Seed       : seed         (1..100)
//   UV         : 0..1 fragment UV (top-left origin, WGSL convention)
//   Resolution : render-target size in pixels (used as fullResolution; tileOffset 0)
//   Time       : normalized animation time
void NM_Cell_float(
    int    Shape,
    float  Scale,
    float  CellScale,
    float  CellSmooth,
    float  Variation,
    float  Speed,
    int    Seed,
    float2 UV,
    float2 Resolution,
    float  Time,
    out float4 Out)
{
    float2 st     = (UV * Resolution) / Resolution.y;
    float  aspect = Resolution.x / Resolution.y;

    Out = nm_cell(st, Scale, CellScale, Shape, Seed,
                  Speed, Variation, CellSmooth, Time, aspect);
}

#endif // NM_CELL_SG_INCLUDED
