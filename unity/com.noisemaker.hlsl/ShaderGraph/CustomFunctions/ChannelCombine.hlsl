#ifndef NM_CHANNELCOMBINE_SG_INCLUDED
#define NM_CHANNELCOMBINE_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/ChannelCombine.hlsl
//
// Shader Graph Custom Function wrapper for mixer/channelCombine. Add a Custom
// Function node, point it at this file, select NM_ChannelCombine_float, and
// wire the named inputs.
//
// The core nm_channelCombine() in Shaders/Effects/mixer/ChannelCombine.hlsl reads
// its scalar parameters from module-scope named uniforms (rLevel/gLevel/bLevel).
// This wrapper assigns the node inputs to those uniforms before calling the core,
// bridging Shader Graph node inputs into the named-uniform model.
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   RLevel   : rLevel (0..100), default 100
//   GLevel   : gLevel (0..100), default 100
//   BLevel   : bLevel (0..100), default 100
//   RTex     : red source   surface -> rTex
//   GTex     : green source surface -> gTex
//   BTex     : blue source  surface -> bTex
//   SS       : sampler state (bilinear, clamp, linear/non-sRGB) for all textures
//   UV       : 0..1 fragment UV (top-left origin, WGSL convention)
//
// The WGSL samples all three textures at the same `st`; here we use the supplied
// UV for all three, matching the single-resolution WGSL path.
// =============================================================================

#include "../../Shaders/Effects/mixer/ChannelCombine.hlsl"

void NM_ChannelCombine_float(
    float             RLevel,
    float             GLevel,
    float             BLevel,
    UnityTexture2D    RTex,
    UnityTexture2D    GTex,
    UnityTexture2D    BTex,
    UnitySamplerState SS,
    float2            UV,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    rLevel = RLevel;
    gLevel = GLevel;
    bLevel = BLevel;

    float4 rSample = RTex.Sample(SS, UV);
    float4 gSample = GTex.Sample(SS, UV);
    float4 bSample = BTex.Sample(SS, UV);
    Out = nm_channelCombine(rSample, gSample, bSample);
}

#endif // NM_CHANNELCOMBINE_SG_INCLUDED
