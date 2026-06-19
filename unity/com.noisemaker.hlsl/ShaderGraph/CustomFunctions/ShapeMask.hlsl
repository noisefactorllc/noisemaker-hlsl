#ifndef NM_SHAPEMASK_SG_INCLUDED
#define NM_SHAPEMASK_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/ShapeMask.hlsl
//
// Shader Graph Custom Function wrapper for mixer/shapeMask. Add a Custom Function
// node, point it at this file, select NM_ShapeMask_float, and wire the named
// inputs. Outputs RGBA.
//
// The core nm_shapeMask(...) in Shaders/Effects/mixer/ShapeMask.hlsl reads its
// scalar parameters from module-scope named uniforms. This wrapper assigns node
// inputs to those globals before calling nm_shapeMask, bridging Shader Graph
// into the core function.
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   Shape      : shape      (0=circle..7=star), default 0
//   Radius     : radius     (0..1),             default 0.7
//   EdgeSmooth : edgeSmooth (0..0.25),           default 0.01
//   Rotation   : rotation   (-180..180 deg),    default 0
//   PosX       : posX       (-1..1),             default 0
//   PosY       : posY       (-1..1),             default 0
//   Invert     : invert     (0=A inside, 1=B inside), default 0
//   Speed      : speed      (0..4),              default 0
//   InputTex   : inputTex   (Source A)
//   Tex        : tex        (Source B)
//   SS         : sampler state (bilinear, clamp, linear/non-sRGB) for both
//   UV         : 0..1 fragment UV (top-left origin, WGSL convention)
// =============================================================================

#include "../../Shaders/Effects/mixer/ShapeMask.hlsl"

void NM_ShapeMask_float(
    int               Shape,
    float             Radius,
    float             EdgeSmooth,
    float             Rotation,
    float             PosX,
    float             PosY,
    int               Invert,
    int               Speed,
    UnityTexture2D    InputTex,
    UnityTexture2D    Tex,
    UnitySamplerState SS,
    float2            UV,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    shape      = Shape;
    radius     = Radius;
    edgeSmooth = EdgeSmooth;
    rotation   = Rotation;
    posX       = PosX;
    posY       = PosY;
    invert     = Invert;
    speed      = Speed;

    // Sample both inputs at the supplied UV (equal-size surface assumption,
    // matching the WGSL's single-st-from-inputTex-dims path).
    float4 colorA = InputTex.Sample(SS, UV);
    float4 colorB = Tex.Sample(SS, UV);

    // Reconstruct aspect-correct centered coordinate from UV.
    // In Shader Graph UV is 0..1; aspect must be supplied by the graph
    // (connect a resolution node or hard-wire 1.0 for square targets).
    // TODO(verify): aspect here assumed square (1.0) — wire actual aspect for
    // non-square render targets.
    float aspect = 1.0;
    float2 p = (UV - float2(0.5, 0.5)) * 2.0;
    p.x = p.x * aspect;
    p = p - float2(posX * aspect, -posY);
    float rad = rotation * NM_SM_PI / 180.0;
    p = rotate2D(p, rad);

    float r = radius;
    // NOTE: speed animation requires `time` from NMFullscreen globals.
    // In a standalone Shader Graph node `time` may not be bound.
    // TODO(verify): connect Time node from Shader Graph and assign _NM_Time,
    // or leave speed=0 for static use.
    [branch] if (speed > 0) {
        r = radius * 0.5 + sin(time * NM_SM_TAU * (float)speed) * radius * 0.5;
    }

    Out = nm_shapeMask(colorA, colorB, p, r);
}

#endif // NM_SHAPEMASK_SG_INCLUDED
