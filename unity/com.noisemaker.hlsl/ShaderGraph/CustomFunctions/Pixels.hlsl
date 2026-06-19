#ifndef NM_PIXELS_SG_INCLUDED
#define NM_PIXELS_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Pixels.hlsl
//
// Shader Graph Custom Function wrapper for filter/pixels. Add a Custom Function
// node, point it at this file, select NM_Pixels_float, and wire inputs.
//
// NOTE: This wrapper implements the non-tiling path only (tileOffset == (0,0)).
// For tile-aware pixelation the effect must be run as a fullscreen render pass
// (Pixels.shader) where the engine-provided tileOffset uniform is available.
// In Shader Graph, TileOffset is (0,0) by convention, so the result is identical
// to the Pixels.shader non-tiling branch.
//
// Inputs:
//   InputTex  — source surface to pixelate
//   SS        — sampler state (bilinear, clamp, linear/non-sRGB)
//   UV        — 0..1 fragment UV (top-left origin, WGSL convention)
//   Size      — pixel block size in texels [1..256] (definition.js default: 16)
// =============================================================================

#include "../../Shaders/Effects/filter/Pixels.hlsl"

void NM_Pixels_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    int               Size,
    out float4        Out)
{
    // Replicate the WGSL non-tiling path verbatim.
    // WGSL: let texSize = vec2<f32>(textureDimensions(inputTex));
    float width, height;
    InputTex.tex.GetDimensions(width, height); // TODO(verify): GetDimensions overload for UnityTexture2D
    float2 texSize = float2(width, height);

    float pixelSize = (float)Size;

    // WGSL: if (uniforms.size < 1.0) { return textureSample(..., uv); }
    if (pixelSize < 1.0)
    {
        Out = InputTex.Sample(SS, UV);
        return;
    }

    // WGSL non-tiling:
    //   let dx = pixelSize / texSize.x;  let dy = pixelSize / texSize.y;
    //   var centered = uv - 0.5;
    //   var coord = vec2<f32>(dx * floor(centered.x / dx), dy * floor(centered.y / dy));
    //   coord = coord + 0.5;
    float dx = pixelSize / texSize.x;
    float dy = pixelSize / texSize.y;
    float2 centered = UV - 0.5;
    float2 coord = float2(dx * floor(centered.x / dx),
                          dy * floor(centered.y / dy));
    coord = coord + 0.5;
    Out = InputTex.Sample(SS, coord);
}

#endif // NM_PIXELS_SG_INCLUDED
