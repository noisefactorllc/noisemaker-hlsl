#ifndef NM_SCALE_SG_INCLUDED
#define NM_SCALE_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Scale.hlsl
//
// Shader Graph Custom Function wrapper for filter/scale. Add a Custom Function
// node, point it at this file, select NM_Scale_float, and wire the inputs.
// Outputs RGBA (scaled + wrapped sample of InputTex).
//
// Inputs mirror definition.js globals; UV and Resolution come from the graph.
// The wrapper declares the per-effect uniforms inline (overriding the ones in
// Scale.hlsl) so the SG node can drive them as node inputs rather than material
// properties. The math is identical — nm_scale() is called unchanged.
// =============================================================================

#include "../../Shaders/Effects/filter/Scale.hlsl"

// InputTex  : source surface to scale-sample
// SS        : sampler state (bilinear, clamp, linear/non-sRGB)
// UV        : 0..1 fragment UV (top-left origin, WGSL convention)
// Resolution: render target size in pixels (resolution.xy)
// ScaleX    : X scale factor (default 0.5)
// ScaleY    : Y scale factor (default 0.5)
// CenterX   : pivot X (0..1, default 0.5)
// CenterY   : pivot Y (0..1, default 0.5)
// Wrap      : 0=mirror, 1=repeat, 2=clamp (default 1)
void NM_Scale_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float2            Resolution,
    float             ScaleX,
    float             ScaleY,
    float             CenterX,
    float             CenterY,
    int               Wrap,
    out float4        Out)
{
    // Shadow the global uniforms with the node inputs.
    scaleX  = ScaleX;
    scaleY  = ScaleY;
    centerX = CenterX;
    centerY = CenterY;
    wrap    = Wrap;

    // Convert 0..1 UV back to pixel-centered fragCoord for nm_scale.
    float2 fragCoord = UV * Resolution;
    Out = nm_scale(fragCoord, Resolution, InputTex, SS); // TODO(verify): UnityTexture2D/UnitySamplerState implicit cast to Texture2D/SamplerState
}

#endif // NM_SCALE_SG_INCLUDED
