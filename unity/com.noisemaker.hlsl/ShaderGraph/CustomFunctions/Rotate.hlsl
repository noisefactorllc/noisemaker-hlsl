#ifndef NM_ROTATE_SG_INCLUDED
#define NM_ROTATE_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Rotate.hlsl
//
// Shader Graph Custom Function wrapper for filter/rotate. Add a Custom Function
// node, point it at this file, select NM_Rotate_float, and wire inputs.
//
// Inputs:
//   InputTex  — source texture to rotate
//   SS        — sampler state (bilinear, clamp, linear/non-sRGB)
//   UV        — 0..1 fragment UV (top-left origin, WGSL convention)
//   Rotation  — degrees, default 45, range -180..180
//   Wrap      — 0=mirror 1=repeat 2=clamp, default 1
//   Speed     — integer animation speed -4..4, default 0
// Output:
//   Out       — rotated RGBA sample
//
// NOTE: The nm_rotate_uv() function reads the `rotation`, `wrap`, `speed` globals
// declared in Rotate.hlsl. In a Shader Graph context those globals must be driven
// by the node inputs below, so we assign them before calling the helper.
// =============================================================================

#include "../../Shaders/Effects/filter/Rotate.hlsl"

void NM_Rotate_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             Rotation,
    int               Wrap,
    int               Speed,
    out float4        Out)
{
    // Assign per-effect globals so nm_rotate_uv() reads the node's inputs.
    // TODO(verify): check that Shader Graph HLSL injection allows global writes;
    // if not, inline nm_rotate_uv logic directly here.
    rotation = Rotation;
    wrap     = Wrap;
    speed    = Speed;

    uint tw, th;
    InputTex.tex.GetDimensions(tw, th);
    float2 texSize = float2(tw, th);

    // UV is already in 0..1 top-left space; convert to pixel coords to match
    // the WGSL which starts from pos.xy (pixel-centered).
    float2 posPx = UV * texSize;
    float2 rotUV = nm_rotate_uv(posPx / texSize, texSize);

    Out = InputTex.tex.Sample(SS.samplerstate, rotUV);
}

#endif // NM_ROTATE_SG_INCLUDED
