#ifndef NM_CELLSPLIT_SG_INCLUDED
#define NM_CELLSPLIT_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/CellSplit.hlsl
//
// Shader Graph Custom Function wrapper for mixer/cellSplit (single render pass).
// Drops the effect in as a node: add a Custom Function node, point it at this
// file, select NM_CellSplit_float, and wire the named inputs + the two
// textures/SS/UV/Resolution. Outputs RGBA.
//
// The core nm_cellSplit(...) in Shaders/Effects/mixer/CellSplit.hlsl reads its
// scalar parameters from module-scope named uniforms (mode/scale/edgeWidth/seed/
// invert/speed) — matching the runtime's individual-named-uniform binding model.
// In a standalone Shader Graph node those globals are not bound by the runtime,
// so this wrapper assigns the node inputs to them before calling nm_cellSplit.
//
// Coordinate handling: the canonical WGSL builds the Voronoi coordinate from
// engine globals (fullResolution, tileOffset) that are not available to a
// standalone node. Following the generator/standalone convention, this wrapper
// takes UV (0..1 fragment UV, top-left/WGSL origin) as the global coordinate
// (tileOffset = 0) and Resolution for aspect, reproducing WGSL lines 49-52:
//     aspect   = Resolution.x / Resolution.y;
//     globalUV = UV;                       // (position.xy + 0) / fullResolution
//     p        = globalUV * (31.0 - scale);
//     p.x      = p.x * aspect;
// Both textures are sampled at UV with the shared sampler (the equal-sized-
// surface case the runtime uses; WGSL samples both at the same st).
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   Invert    : invert    (0 sourceA, 1 sourceB), default 0
//   Mode      : mode       (0 edges, 1 split),     default 0
//   Scale     : scale      (1..30),                default 15
//   EdgeWidth : edgeWidth  (0..0.2),               default 0.08
//   Seed      : seed       (1..100),               default 1
//   Speed     : speed      (0..5, int),            default 1
//   InputTex  : source A surface -> inputTex (colorA)
//   Tex       : source B surface -> tex      (colorB)
//   SS        : sampler state (bilinear, clamp, linear/non-sRGB) for both textures
//   UV        : 0..1 fragment UV (top-left origin, WGSL convention)
//   Resolution: full image resolution in px (for aspect)
//
// NOTE: `time` (used for cell wobble when Speed > 0) is read from the engine
// global alias in NMFullscreen.hlsl. In a static graph preview it is whatever the
// engine provides (0 if unbound), which freezes the wobble — set Speed = 0 for a
// stable preview. The multi-tile cell continuity that fullResolution/tileOffset
// provide in the runtime path is not reproducible standalone.
// TODO(verify): confirm graph-node coordinate convention matches the runtime
// render for non-tiled (single full-frame) usage.
// =============================================================================

#include "../../Shaders/Effects/mixer/CellSplit.hlsl"

void NM_CellSplit_float(
    int               Invert,
    int               Mode,
    float             Scale,
    float             EdgeWidth,
    int               Seed,
    int               Speed,
    UnityTexture2D    InputTex,
    UnityTexture2D    Tex,
    UnitySamplerState SS,
    float2            UV,
    float2            Resolution,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    invert    = Invert;
    mode      = Mode;
    scale     = Scale;
    edgeWidth = EdgeWidth;
    seed      = Seed;
    speed     = (float)Speed;

    float4 colorA = InputTex.Sample(SS, UV);
    float4 colorB = Tex.Sample(SS, UV);

    // WGSL lines 49-52, with tileOffset = 0 (standalone node).
    float aspect = Resolution.x / Resolution.y;
    float2 globalUV = UV;
    float2 p = globalUV * (31.0 - scale);
    p.x = p.x * aspect;

    Out = nm_cellSplit(colorA, colorB, p);
}

#endif // NM_CELLSPLIT_SG_INCLUDED
