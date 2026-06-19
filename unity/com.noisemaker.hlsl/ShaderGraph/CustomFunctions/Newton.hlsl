#ifndef NM_NEWTON_SG_INCLUDED
#define NM_NEWTON_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Newton.hlsl
//
// Shader Graph Custom Function wrapper for synth/newton. Add a Custom Function
// node, point it at this file, select NM_Newton_float, and wire the named
// inputs. Outputs RGBA (grayscale Newton fractal).
//
// The core nm_newton(...) in Shaders/Effects/synth/Newton.hlsl reads effect
// parameters from named global uniforms. This wrapper bridges node inputs to
// those globals before calling the core.
//
// Engine globals (resolution/fullResolution/time) come from NMFullscreen via
// the shader pipeline. For standalone node usage, Resolution drives both
// resolution and fullResolution; tileOffset is assumed zero.
// =============================================================================

#include "../../Shaders/Effects/synth/Newton.hlsl"

void NM_Newton_float(
    float2 UV,
    float2 Resolution,
    float  Time,
    float  Degree,
    float  Relaxation,
    float  Iterations,
    float  Tolerance,
    int    Poi,
    float  CenterHiX,
    float  CenterHiY,
    float  CenterLoX,
    float  CenterLoY,
    float  ZoomSpeed,
    float  ZoomDepth,
    float  DegreeSpeed,
    float  DegreeRange,
    float  RelaxSpeed,
    float  RelaxRange,
    float  Rotation,
    int    OutputMode,
    float  Invert,
    out float4 Out)
{
    // Bridge node inputs -> the core's named global uniforms.
    degree      = Degree;
    relaxation  = Relaxation;
    iterations  = Iterations;
    tolerance   = Tolerance;
    poi         = Poi;
    centerHiX   = CenterHiX;
    centerHiY   = CenterHiY;
    centerLoX   = CenterLoX;
    centerLoY   = CenterLoY;
    zoomSpeed   = ZoomSpeed;
    zoomDepth   = ZoomDepth;
    degreeSpeed = DegreeSpeed;
    degreeRange = DegreeRange;
    relaxSpeed  = RelaxSpeed;
    relaxRange  = RelaxRange;
    rotation    = Rotation;
    outputMode  = OutputMode;
    invert      = Invert;

    // Seed engine globals so nm_newton()'s frRes resolve works correctly.
    _NM_Resolution     = float4(Resolution, 0.0, 0.0);
    _NM_FullResolution = float4(Resolution, 0.0, 0.0);
    _NM_Time           = Time;

    float2 globalCoord = UV * Resolution;
    Out = nm_newton(globalCoord, Resolution, Resolution);
}

#endif // NM_NEWTON_SG_INCLUDED
