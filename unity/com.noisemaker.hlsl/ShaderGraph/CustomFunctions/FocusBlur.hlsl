#ifndef NM_FOCUSBLUR_SG_INCLUDED
#define NM_FOCUSBLUR_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/FocusBlur.hlsl
//
// Shader Graph Custom Function wrapper for mixer/focusBlur. Add a Custom
// Function node, point it at this file, select NM_FocusBlur_float, and wire
// the named inputs + the two textures/SS/UV.
// Outputs RGBA.
//
// The core nm_focusBlur(...) in Shaders/Effects/mixer/FocusBlur.hlsl reads its
// scalar parameters from module-scope named uniforms (depthSource/focalDistance/
// aperture/sampleBias). This wrapper assigns node inputs to those globals before
// calling nm_focusBlur, bridging named inputs into the core function.
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   DepthSource   : depthSource   (0=sourceA, 1=sourceB), default 1
//   FocalDistance : focalDistance (1..100),               default 50
//   Aperture      : aperture      (1..10),                default 4
//   SampleBias    : sampleBias    (2..64),                default 12
//   InputTex      : inputTex (Source A)
//   Tex           : tex      (Source B)
//   SS            : sampler state (bilinear, clamp, linear/non-sRGB)
//   UV            : 0..1 fragment UV (top-left origin, WGSL convention)
//
// NOTE: The WGSL derives uv from inputTex's own pixel dimensions; in Shader
// Graph we accept a UV and reconstruct dims from the texture for kernel offsets.
// The supplied UV is used as the center sample coordinate, matching the runtime.
// =============================================================================

#include "../../Shaders/Effects/mixer/FocusBlur.hlsl"

void NM_FocusBlur_float(
    int               DepthSource,
    float             FocalDistance,
    float             Aperture,
    float             SampleBias,
    UnityTexture2D    InputTex,
    UnityTexture2D    Tex,
    UnitySamplerState SS,
    float2            UV,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    depthSource   = DepthSource;
    focalDistance = FocalDistance;
    aperture      = Aperture;
    sampleBias    = SampleBias;

    // Reconstruct dims from inputTex for kernel offset computation (matches WGSL).
    uint dw, dh;
    InputTex.tex.GetDimensions(dw, dh);
    float2 dims = float2(dw, dh);

    // Convert UV (0..1) back to pixel position then re-derive uv — identity here
    // because the WGSL uv = position.xy / dims and position.xy = UV * dims.
    float2 uv = UV;

    Out = nm_focusBlur(uv, dims,
        InputTex.tex, SS.samplerstate,
        Tex.tex, SS.samplerstate);
}

#endif // NM_FOCUSBLUR_SG_INCLUDED
