#ifndef NM_SHADOW_SG_INCLUDED
#define NM_SHADOW_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Shadow.hlsl
//
// Shader Graph Custom Function wrapper for mixer/shadow. Add a Custom Function
// node, point it at this file, select NM_Shadow_float, and wire the named inputs.
// Outputs RGBA.
//
// The core nm_shadow(...) in Shaders/Effects/mixer/Shadow.hlsl reads its scalar
// parameters from module-scope named uniforms (maskSource/sourceChannel/threshold/
// color/blur/spread/offsetX/offsetY/wrap). This wrapper assigns node inputs to
// those globals before calling nm_shadow, bridging named node inputs into the
// core function.
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   MaskSource    : maskSource    (0=sourceA,1=sourceB),    default 0
//   SourceChannel : sourceChannel (0=R,1=G,2=B,3=A),        default 0
//   Threshold     : threshold     (0..1),                   default 0.5
//   Color         : color         (float3 shadow color),    default (0,0,0)
//   Blur          : blur          (0..3),                   default 1.0
//   Spread        : spread        (0..1),                   default 0.0
//   OffsetX       : offsetX       (-1..1),                  default 0.1
//   OffsetY       : offsetY       (-1..1),                  default -0.1
//   Wrap          : wrap          (0=hide,1=mirror,2=repeat,3=clamp), default 1
//   InputTex      : base input    -> inputTex  (source A)
//   Tex           : second input  -> tex       (source B)
//   SS            : sampler state (bilinear, clamp, linear/non-sRGB) for both
//   UV            : 0..1 fragment UV (top-left origin, WGSL convention)
//
// Note: nm_shadow uses SampleLevel (mip 0) for all samples because the blur
// kernel runs in a loop (non-uniform control flow). UV is multiplied by the
// inputTex dimensions to reconstruct a pixel-center fragCoord, matching the
// WGSL `position.xy / dims` -> fragCoord round-trip exactly.
// TODO(verify): SampleLevel availability on all Shader Graph target platforms.
// =============================================================================

#include "../../Shaders/Effects/mixer/Shadow.hlsl"

void NM_Shadow_float(
    int               MaskSource,
    int               SourceChannel,
    float             Threshold,
    float3            Color,
    float             Blur,
    float             Spread,
    float             OffsetX,
    float             OffsetY,
    int               Wrap,
    UnityTexture2D    InputTex,
    UnityTexture2D    Tex,
    UnitySamplerState SS,
    float2            UV,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    maskSource    = MaskSource;
    sourceChannel = SourceChannel;
    threshold     = Threshold;
    color         = Color;
    blur          = Blur;
    spread        = Spread;
    offsetX       = OffsetX;
    offsetY       = OffsetY;
    wrap          = Wrap;

    // Reconstruct fragCoord from UV and inputTex dimensions (pixel-center = +0.5
    // is already embedded in NM_FragCoord for the render pass; here we replicate
    // the WGSL convention: fragCoord = uv * dims, which is position.xy).
    uint dw, dh;
    InputTex.tex.GetDimensions(dw, dh);
    float2 fragCoord = UV * float2(dw, dh);

    Out = nm_shadow(
        InputTex.tex, SS.samplerstate,
        Tex.tex,      SS.samplerstate,
        fragCoord);
}

#endif // NM_SHADOW_SG_INCLUDED
