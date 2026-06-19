#ifndef NM_SUBDIVIDE_SG_INCLUDED
#define NM_SUBDIVIDE_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Subdivide.hlsl
//
// Shader Graph Custom Function wrapper for synth/subdivide (single render pass).
// Drops the effect in as a node: add a Custom Function node, point it at this
// file, select NM_Subdivide_float, and wire the named inputs + InputTex/SS/UV/
// Resolution/Time. Outputs RGBA.
//
// The core nm_subdivide(...) in Shaders/Effects/synth/Subdivide.hlsl reads its
// parameters from module-scope named uniforms (mode/depth/density/seed/fill/
// outline/inputMix/speed/wrap). In a standalone node those globals are unbound,
// so this wrapper assigns the node inputs to them before calling the core.
//
// The input surface is sampled INSIDE the core (only when InputMix > 0, with a
// generated cell-relative UV), so it is passed as InputTex.tex + SS.samplerstate
// (the UnityTexture2D/UnitySamplerState -> Texture2D/SamplerState bridge, same
// pattern as the UvRemap node).
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   Mode     : mode     (0 binary, 1 quad)                 default 1
//   Depth    : depth     (1..6)                            default 5
//   Density  : density   (30..100)                         default 75
//   Seed     : seed      (1..100)                          default 69
//   Fill     : fill      (0 solid,1 circle,2 diamond,3 square,4 arc,5 mixed) def 0
//   Outline  : outline   (0..10)                           default 3
//   InputMix : inputMix  (0..100)                          default 0
//   Speed    : speed     (0..20)                           default 1
//   Wrap     : wrap      (0 mirror,1 repeat,2 clamp)        default 0
//   InputTex : optional source surface (sampled only when InputMix > 0)
//   SS       : sampler state (bilinear, clamp, linear/non-sRGB) for InputTex
//   UV       : 0..1 fragment UV (top-left origin, WGSL convention)
//   Resolution : render-target size in pixels (= WGSL u.data[0].xy)
//   Time       : normalized animation time
// =============================================================================

#include "../../Shaders/Effects/synth/Subdivide.hlsl"

void NM_Subdivide_float(
    int               Mode,
    int               Depth,
    float             Density,
    int               Seed,
    int               Fill,
    float             Outline,
    float             InputMix,
    int               Speed,
    int               Wrap,
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float2            Resolution,
    float             Time,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    mode     = Mode;
    depth    = Depth;
    density  = Density;
    seed     = Seed;
    fill     = Fill;
    outline  = Outline;
    inputMix = InputMix;
    speed    = Speed;
    wrap     = Wrap;

    // WGSL: st = pos.xy / resolution. fragCoord = UV * Resolution (pixel-centered
    // when UV hits a texel center). tileOffset = 0 for standalone node usage.
    float2 fragCoord = UV * Resolution;
    Out = nm_subdivide(fragCoord, Resolution, Time, InputTex.tex, SS.samplerstate);
}

#endif // NM_SUBDIVIDE_SG_INCLUDED
