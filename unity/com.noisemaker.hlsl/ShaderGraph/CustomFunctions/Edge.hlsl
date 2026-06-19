#ifndef NM_EDGE_SG_INCLUDED
#define NM_EDGE_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Edge.hlsl
//
// Shader Graph Custom Function wrapper for filter/edge. Add a Custom Function
// node, point it at this file, select NM_Edge_float, and wire the inputs.
//
// NOTE: This wrapper fixes all uniforms as inputs because Shader Graph Custom
// Function nodes cannot mutate global uniform state. The global uniform
// declarations in Edge.hlsl (kernel, size, blend, etc.) are declared there for
// the runtime pass; in the SG context these are passed as explicit parameters.
// The wrapper re-assigns them before calling nm_edge_frag so the inline
// uniform reads in the core function see the correct values.
//
// filter/edge is single-pass so a SG wrapper is provided.
// =============================================================================

#include "../../Shaders/Effects/filter/Edge.hlsl"

// InputTex  : source surface
// SS        : sampler state (bilinear, clamp, linear/non-sRGB)
// UV        : 0..1 fragment UV (top-left, multiply by InputTex dimensions to get fragCoord)
// Kernel    : 0=fine, 1=bold
// Size      : 1=kernel5x5, 2=kernel7x7
// Blend     : 0=add..8=screen (see edge.json choices)
// Invert    : 0=off, 1=on
// Channel   : 0=color, 1=luminance
// Threshold : 0..100
// Amount    : 0..500
// MixAmt    : 0..100
void NM_Edge_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    int               Kernel,
    int               Size,
    int               Blend,
    int               Invert,
    int               Channel,
    float             Threshold,
    float             Amount,
    float             MixAmt,
    out float4        Out)
{
    // Assign globals so nm_edge_frag reads them correctly.
    kernel    = Kernel;
    size      = Size;
    blend     = Blend;
    invert    = Invert;
    channel   = Channel;
    threshold = Threshold;
    amount    = Amount;
    mixAmt    = MixAmt;

    // Reconstruct fragCoord from UV * texSize (matches WGSL pos.xy = uv * texSize).
    uint tw, th;
    InputTex.tex.GetDimensions(tw, th); // TODO(verify): UnityTexture2D .tex field name
    float2 fragCoord = UV * float2((float)tw, (float)th);

    Out = nm_edge_frag(InputTex.tex, SS.samplerstate, fragCoord);
}

#endif // NM_EDGE_SG_INCLUDED
