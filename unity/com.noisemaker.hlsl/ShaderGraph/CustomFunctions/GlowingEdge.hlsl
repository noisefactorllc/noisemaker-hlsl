#ifndef NM_GLOWING_EDGE_SG_INCLUDED
#define NM_GLOWING_EDGE_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/GlowingEdge.hlsl
//
// Shader Graph Custom Function wrapper for filter/glowingEdge.
// Add a Custom Function node, point it at this file, select NM_GlowingEdge_float,
// and wire the inputs. Outputs RGBA.
//
// Inputs:
//   InputTex    — source surface (UnityTexture2D)
//   SS          — sampler state (bilinear, clamp, linear/non-sRGB)
//   UV          — 0..1 fragment UV (top-left origin, WGSL convention)
//   SobelMetric — int: 0=Euclidean 1=Manhattan 2=Chebyshev 3=Minkowski
//   Width       — int: kernel half-width in pixels (default 1)
//   Alpha       — float [0,1]: blend between original and glow result
// =============================================================================

#include "../../Shaders/Effects/filter/GlowingEdge.hlsl"

void NM_GlowingEdge_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    int               SobelMetric,
    int               Width,
    float             Alpha,
    out float4        Out)
{
    // Resolve input texture dimensions
    uint tw, th;
    InputTex.tex.GetDimensions(tw, th);
    float2 texSize = float2((float)tw, (float)th);
    float2 texel = (float)Width / texSize;

    // Sample base color (mip 0, matching WGSL textureSampleLevel)
    float4 base = InputTex.tex.SampleLevel(SS.samplerstate, UV, 0.0);

    // 3x3 Sobel neighborhood
    float tl = nm_glowingEdge_luminance(InputTex.tex.SampleLevel(SS.samplerstate, UV + float2(-texel.x, -texel.y), 0.0).rgb);
    float tc = nm_glowingEdge_luminance(InputTex.tex.SampleLevel(SS.samplerstate, UV + float2( 0.0,     -texel.y), 0.0).rgb);
    float tr = nm_glowingEdge_luminance(InputTex.tex.SampleLevel(SS.samplerstate, UV + float2( texel.x, -texel.y), 0.0).rgb);
    float ml = nm_glowingEdge_luminance(InputTex.tex.SampleLevel(SS.samplerstate, UV + float2(-texel.x,  0.0    ), 0.0).rgb);
    float mr = nm_glowingEdge_luminance(InputTex.tex.SampleLevel(SS.samplerstate, UV + float2( texel.x,  0.0    ), 0.0).rgb);
    float bl = nm_glowingEdge_luminance(InputTex.tex.SampleLevel(SS.samplerstate, UV + float2(-texel.x,  texel.y), 0.0).rgb);
    float bc = nm_glowingEdge_luminance(InputTex.tex.SampleLevel(SS.samplerstate, UV + float2( 0.0,      texel.y), 0.0).rgb);
    float br = nm_glowingEdge_luminance(InputTex.tex.SampleLevel(SS.samplerstate, UV + float2( texel.x,  texel.y), 0.0).rgb);

    float gx = -tl - 2.0 * ml - bl + tr + 2.0 * mr + br;
    float gy = -tl - 2.0 * tc - tr + bl + 2.0 * bc + br;

    float edge = clamp(nm_glowingEdge_distMetric(gx, gy, SobelMetric) * 3.0, 0.0, 1.0);
    float3 glow = edge * base.rgb * 2.0;
    float3 result = float3(1.0, 1.0, 1.0) - (float3(1.0, 1.0, 1.0) - base.rgb) * (float3(1.0, 1.0, 1.0) - glow);
    float3 mixed = lerp(base.rgb, result, Alpha);

    Out = float4(clamp(mixed, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0)), base.a);
}

#endif // NM_GLOWING_EDGE_SG_INCLUDED
