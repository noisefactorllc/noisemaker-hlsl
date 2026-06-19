#ifndef NM_BULGE_SG_INCLUDED
#define NM_BULGE_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Bulge.hlsl
//
// Shader Graph Custom Function wrapper for filter/bulge. Add a Custom Function
// node, point it at this file, select NM_Bulge_float, and wire inputs.
//
// Inputs mirror definition.js globals + the source texture/sampler.
// UV must be 0..1, top-left origin (WGSL convention).
//
// NOTE: The effect uses [branch] on antialias which calls ddx/ddy — these are
// valid inside a Shader Graph fragment context but will produce 0 if the node
// is evaluated in a vertex stage. Keep this node in the fragment stage only.
// =============================================================================

#include "../../Shaders/Effects/filter/Bulge.hlsl"

// InputTex   : source surface to distort
// SS         : sampler state (bilinear, clamp, linear/non-sRGB) for InputTex
// UV         : 0..1 fragment UV (top-left origin, WGSL convention)
// Strength   : distortion strength [0,100], default 25
// AspectLens : 1=correct lens aspect, 0=off
// Wrap       : 0=mirror, 1=repeat, 2=clamp
// Rotation   : pre/post rotation in degrees [-180,180], default 0
// Antialias  : 1=4x supersample, 0=off
void NM_Bulge_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             Strength,
    int               AspectLens,
    int               Wrap,
    float             Rotation,
    int               Antialias,
    out float4        Out)
{
    // Wire the effect's declared globals to the node inputs.
    // Bulge.hlsl reads globals as file-scope uniforms; for SG we shadow them
    // with local variables of the same name before calling NMFrag_bulge.
    // Instead, we replicate the core logic inline here so NMFrag_bulge's
    // NM_FragCoord(i) is not needed — we receive UV directly.

    // Resolve texture dimensions (matches WGSL textureDimensions)
    uint tw, th;
    InputTex.tex.GetDimensions(tw, th);
    float2 texSize = float2((float)tw, (float)th);
    float aspectRatio = texSize.x / texSize.y;

    float2 uv = UV;

    // rotate2D before distortion
    uv = nm_bulge_rotate2D(uv, Rotation / 180.0, aspectRatio);

    float intensity = Strength * -0.01;
    uv = uv - 0.5;

    if (AspectLens != 0) { uv.x = uv.x * aspectRatio; }

    float r = length(uv);
    float effect = pow(r, 1.0 - intensity);
    uv = normalize(uv) * effect;

    if (AspectLens != 0) { uv.x = uv.x / aspectRatio; }

    uv = uv + 0.5;

    [branch]
    if (Wrap == 0)
    {
        uv = abs(nm_mod(nm_mod(uv + 1.0, 2.0) + 2.0, 2.0) - 1.0);
    }
    else if (Wrap == 1)
    {
        uv = nm_mod(nm_mod(uv, 1.0) + 1.0, 1.0);
    }
    else
    {
        uv = clamp(uv, float2(0.0, 0.0), float2(1.0, 1.0));
    }

    // reverse rotation
    uv = nm_bulge_rotate2D(uv, -Rotation / 180.0, aspectRatio);

    [branch]
    if (Antialias != 0)
    {
        float2 dx = ddx(uv);
        float2 dy = ddy(uv);
        float4 col = float4(0.0, 0.0, 0.0, 0.0);
        col += InputTex.tex.Sample(SS.samplerstate, uv + dx * -0.375 + dy * -0.125);
        col += InputTex.tex.Sample(SS.samplerstate, uv + dx *  0.125 + dy * -0.375);
        col += InputTex.tex.Sample(SS.samplerstate, uv + dx *  0.375 + dy *  0.125);
        col += InputTex.tex.Sample(SS.samplerstate, uv + dx * -0.125 + dy *  0.375);
        Out = col * 0.25;
    }
    else
    {
        Out = InputTex.tex.Sample(SS.samplerstate, uv);
    }
}

#endif // NM_BULGE_SG_INCLUDED
