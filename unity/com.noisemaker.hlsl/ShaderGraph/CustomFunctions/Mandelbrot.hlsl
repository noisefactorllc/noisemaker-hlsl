#ifndef NM_MANDELBROT_SG_INCLUDED
#define NM_MANDELBROT_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Mandelbrot.hlsl
//
// Shader Graph Custom Function wrapper for synth/mandelbrot. Add a Custom
// Function node, point it at this file, select NM_Mandelbrot_float, and wire
// the named inputs. Outputs RGBA (grayscale value, alpha=1).
//
// NOTE: normalMap output mode (outputMode==4) fires computeDistAt_df64 three
// times per pixel, which is heavy for a Shader Graph node. For animated deep-
// zoom usage prefer the runtime-rendered pass via NMPipeline rather than this
// wrapper.
//
// Engine globals (resolution, time) are passed explicitly via UV/Resolution/Time
// so the node is self-contained and does not depend on NMFullscreen per-frame
// globals being set.
// =============================================================================

#include "../../Shaders/Effects/synth/Mandelbrot.hlsl"

void NM_Mandelbrot_float(
    float2 UV,
    float2 Resolution,
    float  Time,
    int    Poi,
    int    OutputMode,
    int    Iterations,
    float  CenterHiX,
    float  CenterHiY,
    float  CenterLoX,
    float  CenterLoY,
    float  ZoomSpeed,
    float  ZoomDepth,
    float  Invert,
    float  StripeFreq,
    int    TrapShape,
    float  LightAngle,
    float  Rotation,
    out float4 Out)
{
    // Bridge node inputs -> the core's named global uniforms.
    poi         = Poi;
    outputMode  = OutputMode;
    iterations  = Iterations;
    centerHiX   = CenterHiX;
    centerHiY   = CenterHiY;
    centerLoX   = CenterLoX;
    centerLoY   = CenterLoY;
    zoomSpeed   = ZoomSpeed;
    zoomDepth   = ZoomDepth;
    invert      = Invert;
    stripeFreq  = StripeFreq;
    trapShape   = TrapShape;
    lightAngle  = LightAngle;
    rotation    = Rotation;

    // Seed engine globals so NMFullscreen aliases resolve correctly.
    _NM_Resolution     = float4(Resolution, 0.0, 0.0);
    _NM_FullResolution = float4(Resolution, 0.0, 0.0);
    _NM_Time           = Time;

    // fragCoord = UV * Resolution (pixel-centered when UV hits texel center).
    float2 fragCoord = UV * Resolution;
    Out = nm_mandelbrot(fragCoord, Resolution);
}

#endif // NM_MANDELBROT_SG_INCLUDED
