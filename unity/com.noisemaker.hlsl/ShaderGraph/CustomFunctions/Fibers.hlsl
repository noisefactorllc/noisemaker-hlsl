#ifndef NM_FIBERS_SG_INCLUDED
#define NM_FIBERS_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Fibers.hlsl
//
// Shader Graph Custom Function wrapper for filter/fibers (fibersBlend pass).
//
// NOTE: The fibers effect has a mandatory CPU async-init stage (worm tracer)
// that populates OverlayTex. In Shader Graph usage, OverlayTex must be supplied
// as a runtime-rendered Texture2D from NMPipeline.RunAsyncInit(). Wire it from
// an exposed Texture2D property; it cannot be generated inside this node.
//
// Inputs:
//   InputTex   — base input surface (UnityTexture2D)
//   OverlayTex — CPU-rendered fiber overlay (UnityTexture2D)
//   SS         — sampler state (bilinear, clamp, linear/non-sRGB)
//   UV         — 0..1 fragment UV (top-left origin, WGSL convention)
//   Alpha      — overlay blend weight [0..1], default 0.5
//
// The fibersBlend pass uses textureLoad (integer coord, no sampler). In the SG
// wrapper we accept UV and convert to integer coord via floor for parity.
// =============================================================================

#include "../../Shaders/Effects/filter/Fibers.hlsl"

void NM_Fibers_float(
    UnityTexture2D    InputTex,
    UnityTexture2D    OverlayTex,
    UnitySamplerState SS,
    float2            UV,
    float             Alpha,
    out float4        Out)
{
    // Mirror the fibersBlend WGSL: textureLoad at integer pixel coord.
    // Recover pixel coord from UV * textureDimensions.
    uint tw, th;
    InputTex.tex.GetDimensions(tw, th);
    int2 coord = (int2)(UV * float2(tw, th));

    float4 base    = InputTex.tex.Load(int3(coord, 0));
    float4 overlay = OverlayTex.tex.Load(int3(coord, 0));

    // Drive nm_fibers_blend via the global uniform — override alpha for SG use.
    alpha = Alpha; // TODO(verify): writing the global; isolate if SG instances conflict
    Out = nm_fibers_blend(base, overlay);
}

#endif // NM_FIBERS_SG_INCLUDED
