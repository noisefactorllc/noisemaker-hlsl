#ifndef NM_TESTPATTERN_SG_INCLUDED
#define NM_TESTPATTERN_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/TestPattern.hlsl
//
// Shader Graph Custom Function wrapper for synth/testPattern. Drops the effect
// in as a node: add a Custom Function node, point it at this file, select
// NM_TestPattern_float, and wire the named inputs. Outputs RGBA.
//
// The core nm_testPattern(...) in Shaders/Effects/synth/TestPattern.hlsl reads
// the effect parameters from named GLOBAL uniforms (gridSize, pattern). In a
// Shader Graph node those globals are unbound, so this wrapper COPIES each node
// input into the corresponding global before calling the core. HLSL global
// uniforms declared without `static const` are mutable storage assignable from
// the entry function, which is the standard Custom-Function bridging pattern.
//
// Engine globals (resolution/fullResolution/tileOffset) are passed explicitly
// via the UV/Resolution inputs so the node is self-contained and does not depend
// on NMFullscreen's per-frame globals being set. tileOffset is forced to 0 for
// standalone node usage; with tileOffset==0 and fullResolution==resolution the
// core takes the byte-identical non-tiling path.
// =============================================================================

#include "../../Shaders/Effects/synth/TestPattern.hlsl"

// Map each global param (definition.js globals[*].uniform) to a named input.
//   Pattern    : pattern   (enum 0..6)
//   GridSize   : gridSize  ([1,16])
//   UV         : 0..1 fragment UV (top-left origin, WGSL convention)
//   Resolution : render-target size in pixels (used as both resolution and
//                fullResolution; tileOffset assumed 0 for node usage)
void NM_TestPattern_float(
    int    Pattern,
    int    GridSize,
    float2 UV,
    float2 Resolution,
    out float4 Out)
{
    // Bridge node inputs -> the core's named global uniforms.
    pattern  = Pattern;
    gridSize = GridSize;

    // gridLines (pattern 4) reads engine globals tileOffset/resolution/
    // fullResolution (NMFullscreen aliases). Seed them so the node takes the
    // non-tiling path: tileOffset=0, fullResolution=resolution.
    _NM_Resolution     = float4(Resolution, 0.0, 0.0);
    _NM_FullResolution = float4(Resolution, 0.0, 0.0);
    _NM_TileOffset     = float4(0.0, 0.0, 0.0, 0.0);

    // globalCoord = UV * resolution (pixel-centered when UV hits a texel center).
    float2 globalCoord = UV * Resolution;

    // TODO(verify): pattern 4 (gridLines) on the non-tiling path uses
    // fwidthFine (ddx_fine/ddy_fine) for anti-aliasing. Shader Graph evaluates
    // Custom Functions in the fragment stage, so derivatives ARE available and
    // should match the .shader frag path; however if a graph instances the node
    // in a context without valid screen-space derivatives, the AA edge width
    // will differ from the runtime render. Other patterns are derivative-free
    // and are exact.
    Out = nm_testPattern(globalCoord, Resolution, Resolution);
}

#endif // NM_TESTPATTERN_SG_INCLUDED
