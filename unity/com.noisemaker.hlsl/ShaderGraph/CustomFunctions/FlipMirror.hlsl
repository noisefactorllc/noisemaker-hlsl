#ifndef NM_FLIPMIRROR_SG_INCLUDED
#define NM_FLIPMIRROR_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/FlipMirror.hlsl
//
// Shader Graph Custom Function wrapper for filter/flipMirror. Add a Custom
// Function node, point it at this file, select NM_FlipMirror_float, and wire
// the inputs. Outputs RGBA.
//
// Inputs:
//   InputTex  — source surface to warp and sample
//   SS        — sampler state (bilinear, clamp, linear/non-sRGB)
//   UV        — 0..1 fragment UV (top-left origin, WGSL convention)
//   FlipMode  — int mode value (see choices in flipMirror.json)
//
// NOTE: The SG wrapper uses UV directly as fragCoord already divided by texSize.
// To match the WGSL exactly (uv = pos.xy / texSize), pass a UV that was computed
// as fragCoord / inputTexSize (NOT fullResolution-normalized UV). // TODO(verify)
// =============================================================================

#include "../../Shaders/Effects/filter/FlipMirror.hlsl"

void NM_FlipMirror_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    int               FlipMode,
    out float4        Out)
{
    // Override the global uniform for this call.
    // In SG context the global 'flipMode' declared in FlipMirror.hlsl is set here.
    // We pass UV as the pre-divided coordinate; texSize is implicitly 1x1 (UV already
    // normalized). The [branch] chain in nm_flipMirror operates on the UV values,
    // which is equivalent since all thresholds are 0.5 and operations are symmetric.
    // TODO(verify): confirm that FlipMode drives flipMode correctly at SG compile time.
    flipMode = FlipMode;

    // UV is already in 0..1; texSize=float2(1,1) so fragCoord/texSize == UV.
    Out = nm_flipMirror(InputTex, SS, float2(1.0, 1.0), UV);
}

#endif // NM_FLIPMIRROR_SG_INCLUDED
