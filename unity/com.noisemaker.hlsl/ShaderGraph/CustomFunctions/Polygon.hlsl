#ifndef NM_POLYGON_SG_INCLUDED
#define NM_POLYGON_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Polygon.hlsl
//
// Shader Graph Custom Function wrapper for synth/polygon. Add a Custom Function
// node, point it at this file, select NM_Polygon_float, and wire the named
// inputs. Outputs premultiplied RGBA.
//
// The core nm_polygon(...) in Shaders/Effects/synth/Polygon.hlsl reads effect
// parameters from named global uniforms. This wrapper copies each node input
// into the corresponding global before calling the core, using the standard
// Custom-Function bridging pattern.
//
// Engine globals (resolution, aspectRatio) are derived from the Resolution
// input so the node is self-contained.
// =============================================================================

#include "../../Shaders/Effects/synth/Polygon.hlsl"

// Exposes all definition.js globals as named inputs.
//   Sides       : sides   (int, 3..64)
//   Radius      : radius  (float, 0..1)
//   Smoothing   : smoothing (float, 0..1; param name "smooth", uniform "smoothing")
//   Rotation    : rotation (float, degrees, -180..180)
//   FgColor     : fgColor
//   FgAlpha     : fgAlpha
//   BgColor     : bgColor
//   BgAlpha     : bgAlpha
//   UV          : 0..1 fragment UV (top-left origin, WGSL convention)
//   Resolution  : render-target size in pixels
void NM_Polygon_float(
    int    Sides,
    float  Radius,
    float  Smoothing,
    float  Rotation,
    float3 FgColor,
    float  FgAlpha,
    float3 BgColor,
    float  BgAlpha,
    float2 UV,
    float2 Resolution,
    out float4 Out)
{
    // Bridge node inputs -> the core's named global uniforms.
    sides     = Sides;
    radius    = Radius;
    smoothing = Smoothing;
    rotation  = Rotation;
    fgColor   = FgColor;
    fgAlpha   = FgAlpha;
    bgColor   = BgColor;
    bgAlpha   = BgAlpha;

    // Seed engine globals so NMFullscreen macros (resolution, aspectRatio) work.
    _NM_Resolution     = float4(Resolution, 0.0, 0.0);
    _NM_FullResolution = float4(Resolution, 0.0, 0.0);

    float aspect = (Resolution.y > 0.0) ? Resolution.x / Resolution.y : 1.0;

    // globalCoord = UV * resolution (pixel-centered for texel-center UVs).
    float2 globalCoord = UV * Resolution;
    Out = nm_polygon(globalCoord, Resolution, aspect);
}

#endif // NM_POLYGON_SG_INCLUDED
