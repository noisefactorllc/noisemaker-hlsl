#ifndef NM_JULIA_SG_INCLUDED
#define NM_JULIA_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Julia.hlsl
//
// Shader Graph Custom Function wrapper for synth/julia.
// Add a Custom Function node, point it at this file, select NM_Julia_float,
// and wire the named inputs. Outputs RGBA (grayscale Julia set, alpha=1).
//
// NOTE: outputMode=4 (normalMap) runs the iteration loop THREE times for
// finite differences. In a Shader Graph node context this is expensive but
// functionally correct. For production use the runtime-rendered Texture2D
// path instead.
//
// Engine globals (resolution/time/fullResolution/tileOffset) are passed
// explicitly so the node is self-contained without NMFullscreen per-frame
// globals being set.
// =============================================================================

#include "../../Shaders/Effects/synth/Julia.hlsl"

void NM_Julia_float(
    float2 UV,
    float2 Resolution,
    float  Time,
    int    Poi,
    int    OutputMode,
    int    Iterations,
    float  CReal,
    float  CImag,
    float  CenterX,
    float  CenterY,
    float  Rotation,
    int    CPath,
    float  CSpeed,
    float  CRadius,
    float  ZoomSpeed,
    float  ZoomDepth,
    float  StripeFreq,
    int    TrapShape,
    float  LightAngle,
    float  Invert,
    out float4 Out)
{
    // Bridge node inputs -> the core's named global uniforms.
    poi        = Poi;
    outputMode = OutputMode;
    iterations = Iterations;
    cReal      = CReal;
    cImag      = CImag;
    centerX    = CenterX;
    centerY    = CenterY;
    rotation   = Rotation;
    cPath      = CPath;
    cSpeed     = CSpeed;
    cRadius    = CRadius;
    zoomSpeed  = ZoomSpeed;
    zoomDepth  = ZoomDepth;
    stripeFreq = StripeFreq;
    trapShape  = TrapShape;
    lightAngle = LightAngle;
    invert     = Invert;

    // Seed engine globals so NMFullscreen aliases resolve correctly.
    _NM_Resolution     = float4(Resolution, 0.0, 0.0);
    _NM_FullResolution = float4(Resolution, 0.0, 0.0);
    _NM_TileOffset     = float4(0.0, 0.0, 0.0, 0.0);
    _NM_Time           = Time;

    // fragCoord = UV * Resolution (pixel-centered when UV hits a texel center).
    // tileOffset = 0 for standalone node usage.
    float2 fragCoord = UV * Resolution;
    Out = nm_julia(fragCoord, float2(0.0, 0.0), Resolution, Time);
}

#endif // NM_JULIA_SG_INCLUDED
