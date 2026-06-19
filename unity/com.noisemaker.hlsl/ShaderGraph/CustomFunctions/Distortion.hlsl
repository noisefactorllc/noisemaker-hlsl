#ifndef NM_DISTORTION_SG_INCLUDED
#define NM_DISTORTION_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Distortion.hlsl
//
// Shader Graph Custom Function wrapper for mixer/distortion. Add a Custom
// Function node, point it at this file, select NM_Distortion_float, and wire
// the named inputs (both textures, shared sampler state, UV, and params).
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   InputTex   : inputTex  (source A)
//   Tex        : tex       (source B)
//   SS         : shared sampler state (bilinear, clamp, linear/non-sRGB)
//   UV         : 0..1 fragment UV (top-left origin, WGSL convention)
//   Mode       : mode       (0=displace, 1=refract, 2=reflect),  default 1
//   MapSource  : mapSource  (0=sourceA, 1=sourceB),              default 1
//   Intensity  : intensity  (0..100),                            default 50
//   Wrap       : wrap       (0=mirror, 1=repeat, 2=clamp),       default 0
//   Smoothing  : smoothing  (1..100),                            default 1
//   Aberration : aberration (0..25),                             default 0
//   Antialias  : antialias  (0=off, 1=on),                       default 0
//
// The WGSL derives uv from inputTex's own pixel dimensions; in a SG node we
// receive a pre-built UV and derive texelSize from GetDimensions on InputTex
// so the Sobel kernel spacing matches the reference.
// =============================================================================

#include "../../Shaders/Effects/mixer/Distortion.hlsl"

void NM_Distortion_float(
    UnityTexture2D    InputTex,
    UnityTexture2D    Tex,
    UnitySamplerState SS,
    float2            UV,
    int               Mode,
    int               MapSource,
    float             Intensity,
    int               Wrap,
    float             Smoothing,
    float             Aberration,
    int               Antialias,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    mode       = Mode;
    mapSource  = MapSource;
    intensity  = Intensity;
    wrap       = Wrap;
    smoothing  = Smoothing;
    aberration = Aberration;
    antialias  = Antialias;

    // Wire extern resources so the shared helpers (calculateNormal, sample
    // calls) resolve to the node-supplied textures and sampler.
    // TODO(verify): Unity SG extern resource bridging — confirm at runtime that
    // assigning UnityTexture2D.tex to Texture2D extern compiles correctly.
    inputTex         = InputTex.tex;
    sampler_inputTex = SS.samplerstate;
    tex              = Tex.tex;
    sampler_tex      = SS.samplerstate;

    uint dw, dh;
    InputTex.tex.GetDimensions(dw, dh);
    float2 texelSize = 1.0 / float2(dw, dh);

    Out = nm_distortion(UV, texelSize);
}

#endif // NM_DISTORTION_SG_INCLUDED
