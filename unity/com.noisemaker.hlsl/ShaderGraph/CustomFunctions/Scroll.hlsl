#ifndef NM_SCROLL_SG_INCLUDED
#define NM_SCROLL_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Scroll.hlsl
//
// Shader Graph Custom Function wrapper for filter/scroll. Add a Custom Function
// node, point it at this file, select NM_Scroll_float, and wire the inputs.
//
// NOTE: This effect uses `time` and `resolution`/`aspectRatio` engine globals
// from NMFullscreen.hlsl (via Scroll.hlsl). In a Shader Graph context those must
// be provided by the NMPipeline — the node cannot be used standalone without the
// NMFullscreen uniforms bound. // TODO(verify): confirm Shader Graph context
// binds _NM_Resolution/_NM_Time/_NM_FullResolution before this node executes.
//
// Inputs:
//   InputTex  — source texture (UnityTexture2D)
//   SS        — sampler state (bilinear, clamp, linear/non-sRGB)
//   UV        — 0..1 fragment UV (top-left origin, not used directly — the WGSL
//               derives st from fragCoord/resolution, not UV. Pass SV_POSITION-
//               derived pixel coord via Resolution*UV as a float2 PixelCoord.)
//   PixelCoord — pixel-center coord = UV * Resolution (matches NM_FragCoord)
//   X, Y, SpeedX, SpeedY — scroll offsets/speeds
//   Wrap      — int: 0=mirror, 1=repeat, 2=clamp
// =============================================================================

#include "../../Shaders/Effects/filter/Scroll.hlsl"

void NM_Scroll_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            PixelCoord,
    float             X,
    float             Y,
    float             SpeedX,
    float             SpeedY,
    int               Wrap,
    out float4        Out)
{
    // Temporarily shadow the named uniforms declared in Scroll.hlsl so the
    // nm_scroll() call picks up the node's per-instance values.
    // HLSL allows local variable shadowing of globals within the function scope.
    float x      = X;
    float y      = Y;
    float speedX = SpeedX;
    float speedY = SpeedY;
    int   wrap   = Wrap;

    Out = nm_scroll(PixelCoord, InputTex, SS);
}

#endif // NM_SCROLL_SG_INCLUDED
