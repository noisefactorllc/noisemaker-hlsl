#ifndef NM_EFFECT_CHROMATICABERRATION_INCLUDED
#define NM_EFFECT_CHROMATICABERRATION_INCLUDED

// =============================================================================
// ChromaticAberration.hlsl — filter/chromaticAberration (func: "chromaticAberration")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/filter/chromaticAberration/wgsl/chromaticAberration.wgsl
//
// Color fringing effect simulating lens aberration. Single render pass.
// RGB channels are sampled at offset UVs; alpha passes through from the green
// (unshifted) sample.
//
// PORTING-GUIDE notes / hazards handled:
//  * UV for the aspect/center computation uses
//      uv = (fragCoord.xy + tileOffset) / fullResolution
//    i.e. global normalized UV — WGSL uses fullResolution here.
//  * The green (unshifted) sample and the red/blue offset samples are ALL
//    divided by the INPUT TEXTURE's own dimensions (texSize), NOT fullResolution.
//    WGSL line:
//      green = textureSample(inputTex, samp, fragCoord.xy / texSize)
//      red   = textureSample(inputTex, samp, (vec2(redOffset, uv.y) * fullResolution - tileOffset) / texSize)
//    We follow the WGSL literally.
//  * NM_FragCoord(i) is the fragCoord.xy analog (+0.5-centered, top-left).
//    NM_GlobalCoord(i) = NM_FragCoord(i) + tileOffset.
//  * `mix` -> `lerp`; `clamp`/`length`/`min` map 1:1.
//  * PI defined locally; mapVal helper inlined verbatim.
//  * No PRNG, no PCG, no per-effect Y-flip needed.
//  * `aspectRatio` is fullResolution.x / fullResolution.y (aliased in NMFullscreen.hlsl).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (reference binding: sampler@0, inputTex@1) ------
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
float aberrationAmt;  // globals.aberration.uniform, [0,100]  default 50
float passthru;       // globals.passthru.uniform,   [0,100]  default 50

// ---- Local constant ----
static const float NM_CA_PI = 3.14159265359;

// -----------------------------------------------------------------------------
// mapVal — verbatim from WGSL `mapVal(value, inMin, inMax, outMin, outMax)`.
//   return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
// -----------------------------------------------------------------------------
float nm_ca_mapVal(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

// =============================================================================
// NMFrag_chromaticAberration — single render pass.
//
// WGSL main() translated line-by-line:
//   aspectRatio    = fullResolution.x / fullResolution.y
//   uv             = (fragCoord.xy + tileOffset) / fullResolution
//   texSize        = vec2f(textureDimensions(inputTex, 0))
//   diff           = vec2(0.5 * aspectRatio, 0.5) - vec2(uv.x * aspectRatio, uv.y)
//   centerDist     = length(diff)
//   aberrationOffset = mapVal(aberrationAmt, 0,100, 0,0.05) * centerDist * PI * 0.5
//   redOffset      = mix(clamp(uv.x + aberrationOffset, 0,1), uv.x, uv.x)
//   red            = sample((vec2(redOffset,  uv.y) * fullResolution - tileOffset) / texSize)
//   green          = sample(fragCoord.xy / texSize)
//   blueOffset     = mix(uv.x, clamp(uv.x - aberrationOffset, 0,1), uv.x)
//   blue           = sample((vec2(blueOffset, uv.y) * fullResolution - tileOffset) / texSize)
//   aberrated      = vec3(red.r, green.g, blue.b)
//   edges          = aberrated - green.rgb
//   original       = green.rgb * mapVal(passthru, 0,100, 0,2)
//   return vec4(min(edges + original, vec3(1)), green.a)
// =============================================================================
float4 NMFrag_chromaticAberration(NMVaryings i) : SV_Target
{
    // Retrieve input texture dimensions (WGSL: textureDimensions(inputTex, 0))
    uint texW, texH;
    inputTex.GetDimensions(texW, texH);
    float2 texSize = float2((float)texW, (float)texH);

    // fragCoord.xy and global UV (WGSL: fragCoord = @builtin(position))
    float2 fragCoord = NM_FragCoord(i);                           // fragCoord.xy
    float2 uv = (fragCoord + tileOffset) / fullResolution;        // global normalized UV

    // Aspect-corrected distance from center
    float ar = fullResolution.x / fullResolution.y;               // aspectRatio
    float2 diff = float2(0.5 * ar, 0.5) - float2(uv.x * ar, uv.y);
    float centerDist = length(diff);

    // Aberration offset amount
    float aberrationOffset = nm_ca_mapVal(aberrationAmt, 0.0, 100.0, 0.0, 0.05)
                             * centerDist * NM_CA_PI * 0.5;

    // Red channel — shifted right
    float redOffset = lerp(clamp(uv.x + aberrationOffset, 0.0, 1.0), uv.x, uv.x);
    float2 redUV    = (float2(redOffset, uv.y) * fullResolution - tileOffset) / texSize;
    float4 red      = inputTex.Sample(sampler_inputTex, redUV);

    // Green channel — unshifted (WGSL: fragCoord.xy / texSize)
    float4 green = inputTex.Sample(sampler_inputTex, fragCoord / texSize);

    // Blue channel — shifted left
    float blueOffset = lerp(uv.x, clamp(uv.x - aberrationOffset, 0.0, 1.0), uv.x);
    float2 blueUV    = (float2(blueOffset, uv.y) * fullResolution - tileOffset) / texSize;
    float4 blue      = inputTex.Sample(sampler_inputTex, blueUV);

    // Chromatic aberration: extract fringing edges, blend with passthru original
    float3 aberrated = float3(red.r, green.g, blue.b);
    float3 edges     = aberrated - green.rgb;
    float3 original  = green.rgb * nm_ca_mapVal(passthru, 0.0, 100.0, 0.0, 2.0);

    return float4(min(edges + original, float3(1.0, 1.0, 1.0)), green.a);
}

#endif // NM_EFFECT_CHROMATICABERRATION_INCLUDED
