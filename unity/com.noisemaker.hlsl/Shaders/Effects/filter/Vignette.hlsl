#ifndef NM_EFFECT_VIGNETTE_INCLUDED
#define NM_EFFECT_VIGNETTE_INCLUDED

// =============================================================================
// Vignette.hlsl — filter/vignette (func: "vignette")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/filter/vignette/wgsl/vignette.wgsl
//
// Radial vignette: darkens (blends toward a brightness value) the edges of the
// frame by a squared, aspect-corrected normalized distance from center, then
// cross-fades that result with the original via `alpha`. Single render pass.
// RGB only is affected; alpha is passed through unchanged.
//
// PORTING-GUIDE notes / hazards handled:
//  * Sampling UV and the vignette mask BOTH use `uv = pos.xy / textureDimensions
//    (inputTex)` in the WGSL — i.e. fragCoord divided by the INPUT TEXTURE's own
//    dimensions, NOT fullResolution and NOT fullResolution.y. WGSL is canonical,
//    so we mirror it exactly: NM_FragCoord(i) / float2(texW, texH).
//    (The GLSL splits into a per-tile sample `uv` and a fullResolution-based
//    `globalUV` for the mask; the WGSL uses a single `uv` for both. We follow
//    the WGSL.) NM_FragCoord (top-left, +0.5 centered) is the @builtin(position)
//    analog; no per-effect Y flip is needed (H8).
//  * `dims` here is the input texture size (WGSL `texSize`), passed straight into
//    computeVignetteMask as `dims` — matching the WGSL call `computeVignetteMask
//    (uv, texSize)`.
//  * No PRNG / no PCG / no float-bit hazards in this effect.
//  * `mix` -> `lerp`; `length`/`clamp`/`abs`/`max` map 1:1.
//  * `vec3<f32>(uniforms.vignetteBrightness)` splat -> float3(b,b,b).
//  * Linear, clamp-to-edge, non-sRGB sampler (H7) — set on the SamplerState in
//    Vignette.shader / supplied by the Shader Graph node.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (reference binding: sampler@0, inputTex@1) ------
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
// Bound by the runtime via MaterialPropertyBlock by these exact names.
float vignetteBrightness;  // globals.brightness.uniform, [0,1]   default 0
float alpha;               // globals.alpha.uniform,      [0,1]   default 1

// -----------------------------------------------------------------------------
// computeVignetteMask — verbatim from WGSL `computeVignetteMask(uv, dims)`.
//   if (dims.x <= 0 || dims.y <= 0) return 0;
//   delta      = abs(uv - 0.5)
//   aspect     = dims.x / max(dims.y, 1.0)
//   scaled     = (delta.x * aspect, delta.y)
//   maxRadius  = length(aspect*0.5, 0.5)
//   if (maxRadius <= 0) return 0;
//   normalizedDist = clamp(length(scaled) / maxRadius, 0, 1)
//   return normalizedDist * normalizedDist
// -----------------------------------------------------------------------------
float nm_vignette_computeMask(float2 uv, float2 dims)
{
    if (dims.x <= 0.0 || dims.y <= 0.0)
    {
        return 0.0;
    }

    float2 delta = abs(uv - float2(0.5, 0.5));
    float aspect = dims.x / max(dims.y, 1.0);
    float2 scaled = float2(delta.x * aspect, delta.y);
    float maxRadius = length(float2(aspect * 0.5, 0.5));

    if (maxRadius <= 0.0)
    {
        return 0.0;
    }

    float normalizedDist = clamp(length(scaled) / maxRadius, 0.0, 1.0);
    return normalizedDist * normalizedDist;
}

// =============================================================================
// nm_vignette — core per-pixel evaluation. `texel` is the already-sampled input
// RGBA; `uv` is the sample/mask coordinate; `dims` is the input texture size.
// Mirrors the WGSL main() body after the textureSample. Returns RGBA.
//
// WGSL:
//   let mask = computeVignetteMask(uv, texSize);
//   let brightnessRgb = vec3<f32>(uniforms.vignetteBrightness);
//   let edgeBlend = mix(texel.rgb, brightnessRgb, mask);
//   let finalRgb  = mix(texel.rgb, edgeBlend, uniforms.alpha);
//   return vec4<f32>(finalRgb, texel.a);
// =============================================================================
float4 nm_vignette(float4 texel, float2 uv, float2 dims)
{
    float mask = nm_vignette_computeMask(uv, dims);

    // Apply brightness to RGB only, preserve alpha
    float3 brightnessRgb = float3(vignetteBrightness, vignetteBrightness, vignetteBrightness);
    float3 edgeBlend = lerp(texel.rgb, brightnessRgb, mask);
    float3 finalRgb = lerp(texel.rgb, edgeBlend, alpha);

    return float4(finalRgb, texel.a);
}

// ---- Pass: "vignette" (progName "vignette") ---------------------------------
float4 NMFrag_vignette(NMVaryings i) : SV_Target
{
    // WGSL: texSize = vec2<f32>(textureDimensions(inputTex));
    //       uv      = pos.xy / texSize;   (pos = @builtin(position), top-left)
    uint w, h;
    inputTex.GetDimensions(w, h);
    float2 texSize = float2((float)w, (float)h);
    float2 uv = NM_FragCoord(i) / texSize;

    float4 texel = inputTex.Sample(sampler_inputTex, uv);
    return nm_vignette(texel, uv, texSize);
}

#endif // NM_EFFECT_VIGNETTE_INCLUDED
