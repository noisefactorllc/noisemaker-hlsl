#ifndef NM_CENTERMASK_SG_INCLUDED
#define NM_CENTERMASK_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/CenterMask.hlsl
//
// Shader Graph Custom Function wrapper for mixer/centerMask. Add a Custom
// Function node, point it at this file, select NM_CenterMask_float, and wire
// the named inputs.
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   BlendMode  : blendMode (int, 0 add..15 subtract), default 8
//   Shape      : shape     (int, 0 circle/1 diamond/2 square), default 2
//   Hardness   : hardness  (float, 0..100), default 0
//   Power      : power     (float, -100..100), default 0  (definition.js key "mix")
//   EdgeTex    : inputTex  (base/edges/A)
//   CenterTex  : tex       (center/B)
//   SS         : sampler state (bilinear, clamp, linear/non-sRGB) for both textures
//   UV         : 0..1 fragment UV (top-left origin, WGSL convention)
//   Resolution : pixel dimensions of the input textures (float2)
//
// The WGSL derives the mask geometry from tile-local pixel coords
// (position.xy, not UV). This wrapper reconstructs pixel coords from UV *
// Resolution, matching the equal-sized-surface case the runtime uses.
// // TODO(verify): confirm that UV * Resolution matches NM_FragCoord(i) for the
// Shader Graph execution context on the target platform.
// =============================================================================

#include "../../Shaders/Effects/mixer/CenterMask.hlsl"

void NM_CenterMask_float(
    int               BlendMode,
    int               Shape,
    float             Hardness,
    float             Power,
    UnityTexture2D    EdgeTex,
    UnityTexture2D    CenterTex,
    UnitySamplerState SS,
    float2            UV,
    float2            Resolution,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    blendMode = BlendMode;
    shape     = Shape;
    hardness  = Hardness;
    power     = Power;

    float4 edgeColor   = EdgeTex.Sample(SS, UV);
    float4 centerColor = CenterTex.Sample(SS, UV);

    // Reconstruct pixel-space position from UV and texture resolution.
    // The WGSL uses position.xy (top-left, +0.5 centered pixel).
    float2 pos = UV * Resolution;

    Out = nm_centerMask(edgeColor, centerColor, pos, Resolution);
}

#endif // NM_CENTERMASK_SG_INCLUDED
