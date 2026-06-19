#ifndef NM_GLYPHMAP_SG_INCLUDED
#define NM_GLYPHMAP_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/GlyphMap.hlsl
//
// Shader Graph Custom Function wrapper for filter/glyphMap. Add a Custom Function
// node, point it at this file, select NM_GlyphMap_float, and wire the named
// inputs + InputTex/SS/UV. Outputs RGBA.
//
// Single render pass, so the effect ships as a Shader Graph node (PORTING-GUIDE
// per-effect checklist item 4).
//
// The core nm_glyphMap(...) in Shaders/Effects/filter/GlyphMap.hlsl reads its
// parameters from module-scope named uniforms (cellSize/seed/colorMode) —
// matching the runtime's individual-named-uniform binding model. In a standalone
// node those globals are not bound, so this wrapper assigns the node inputs to
// them before calling nm_glyphMap.
//
// Coordinate bridge: the core works in target-pixel coords (the WGSL
// @builtin(position).xy). A Shader Graph node receives a 0..1 UV, so we
// reconstruct pixel coords as UV * texSize, where texSize is the input texture's
// own dimensions (the same denominator the WGSL uses for the cell-center sample).
// TODO(verify): runtime parity vs. the dedicated GlyphMap.shader render pass —
// the node path assumes UV*texSize reproduces NM_FragCoord (pixel-centered +0.5);
// confirm in the parity harness before relying on the SG node for tiling.
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   CellSize  : cellSize  (4..32),  default 16
//   Seed      : seed      (1..100), default 1
//   ColorMode : colorMode (0 mono,1 rgb), default 1
//   InputTex  : source surface to glyph-map
//   SS        : sampler state (bilinear, clamp, linear/non-sRGB) for InputTex
//   UV        : 0..1 fragment UV (top-left origin, WGSL convention)
// =============================================================================

#include "../../Shaders/Effects/filter/GlyphMap.hlsl"

void NM_GlyphMap_float(
    int               CellSize,
    int               Seed,
    int               ColorMode,
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    cellSize  = CellSize;
    seed      = Seed;
    colorMode = ColorMode;

    uint tw, th;
    InputTex.tex.GetDimensions(tw, th);
    float2 texSize = float2(tw, th);
    float2 pos = UV * texSize;

    Out = nm_glyphMap(pos, texSize, InputTex.tex, SS.samplerstate);
}

#endif // NM_GLYPHMAP_SG_INCLUDED
