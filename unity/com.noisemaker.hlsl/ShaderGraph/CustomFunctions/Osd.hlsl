#ifndef NM_OSD_SG_INCLUDED
#define NM_OSD_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Osd.hlsl
//
// Shader Graph Custom Function wrapper for filter/osd. Single render pass, so a
// node wrapper is provided. Add a Custom Function node, point it at this file,
// select NM_Osd_float, and wire the named inputs + InputTex/SS/UV. Outputs RGBA.
//
// The core nm_osd(...) in Shaders/Effects/filter/Osd.hlsl reads its parameters
// from module-scope named uniforms (alpha/seed/speed/corner) — matching the
// runtime's individual-named-uniform binding model. In a standalone Shader Graph
// node those globals are not bound by the runtime, so this wrapper assigns the
// node inputs to them before calling nm_osd.
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   Alpha  : alpha  (0..1),                              default 0.75
//   Seed   : seed   (1..100),                            default 1
//   Speed  : speed  (0..50),                             default 0
//   Corner : corner (0 TL, 1 TR, 2 BL, 3 BR),            default 3
//   InputTex : source surface
//   SS       : sampler state (bilinear, clamp, linear/non-sRGB) for InputTex
//   UV       : 0..1 fragment UV (top-left origin, WGSL convention)
//
// The integer pixel coord (== WGSL gid.xy) and width/height (== params.width/
// height) are reconstructed from UV * texture dimensions, matching Osd.shader.
// =============================================================================

#include "../../Shaders/Effects/filter/Osd.hlsl"

void NM_Osd_float(
    float             Alpha,
    int               Seed,
    float             Speed,
    int               Corner,
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    alpha  = Alpha;
    seed   = Seed;
    speed  = Speed;
    corner = Corner;

    uint tw, th;
    InputTex.tex.GetDimensions(tw, th);
    int w = max((int)tw, 1);
    int h = max((int)th, 1);

    // Pixel-centered fragment coord (top-left origin) -> integer texel index.
    float2 fc = float2(UV.x * (float)tw, UV.y * (float)th);
    int2 icoord = int2((int)floor(fc.x), (int)floor(fc.y));

    float4 texel = InputTex.Sample(SS, UV);
    Out = nm_osd(texel, icoord, w, h);
}

#endif // NM_OSD_SG_INCLUDED
