// NOTE: filter/strayHair is a MULTI-PASS effect requiring a CPU asyncInit step
// (traceWorms renders hair strands to an overlayTex canvas) before the GPU blend
// pass fires. The Shader Graph wrapper below covers ONLY the GPU blend pass and
// requires the caller to supply the pre-rendered overlayTex as a separate input.
// The CPU tracing step cannot run inside a Shader Graph node; for full parity use
// the runtime-managed NMPipeline path which calls asyncInit automatically.

#ifndef NM_STRAYHAIR_SG_INCLUDED
#define NM_STRAYHAIR_SG_INCLUDED

#include "../../Shaders/Effects/filter/StrayHair.hlsl"

// InputTex   : source surface (upstream render texture)
// OverlayTex : CPU-rendered hair overlay (rgba8; must be pre-populated by asyncInit)
// SS         : sampler state (not used for Load-based fetch; present for SG wiring)
// UV         : 0..1 fragment UV (top-left origin, WGSL convention)
// Resolution : render target resolution in pixels (needed to convert UV to int coord)
// Alpha      : blend weight for the overlay (globals.alpha, default 0.5)
//
// TODO(verify): Shader Graph does not drive asyncInit; overlayTex will be black
// unless the caller pre-renders it externally. For design-time preview, wire a
// pre-baked hair Texture2D to OverlayTex.
void NM_StrayHair_float(
    UnityTexture2D    InputTex,
    UnityTexture2D    OverlayTex,
    UnitySamplerState SS,
    float2            UV,
    float2            Resolution,
    float             Alpha,
    out float4        Out)
{
    // Convert UV to integer pixel coordinate matching WGSL i32(pos.x/y).
    int2 coord = (int2)(UV * Resolution);

    float4 base    = InputTex  .tex.Load(int3(coord, 0));
    float4 overlay = OverlayTex.tex.Load(int3(coord, 0));

    Out = nm_strayHairBlend(base, overlay, Alpha);
}

#endif // NM_STRAYHAIR_SG_INCLUDED
