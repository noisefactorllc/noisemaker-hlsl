#ifndef NM_SOBEL_INCLUDED
#define NM_SOBEL_INCLUDED

// =============================================================================
// Sobel.hlsl — filter/sobel, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/sobel/wgsl/sobel.wgsl
//
// Classic Sobel edge detection. For each pixel: sample a 3x3 neighbourhood,
// convolve the RGB with the Sobel-X and Sobel-Y kernels (one accumulator per
// axis), take distance(convX, convY) as the edge magnitude, multiply the
// original color by it, then blend original<->result by `alpha`.
//
// WGSL main():
//   let texSize   = vec2<f32>(textureDimensions(inputTex));
//   let uv        = pos.xy / texSize;                  // pos top-left, +0.5
//   let texelSize = 1.0 / texSize;
//   let origColor = textureSample(inputTex, inputSampler, uv);
//   sobel_x = (1,0,-1, 2,0,-2, 1,0,-1)
//   sobel_y = (1,2,1, 0,0,0, -1,-2,-1)
//   offsets = 3x3 neighbourhood scaled by texelSize
//   for i in 0..9:
//     sample = textureSample(inputTex, inputSampler, uv + offsets[i]*amount).rgb
//     convX += sample * sobel_x[i]; convY += sample * sobel_y[i];
//   dist    = distance(convX, convY);
//   result  = origColor.rgb * dist;
//   blended = mix(origColor.rgb, result, alpha);
//   return vec4(blended, origColor.a);
//
// PORTING-GUIDE notes:
//  * Single render pass (definition.js passes.length == 1, program "sobel").
//  * uv is fragCoord / the INPUT TEXTURE's own dimensions (the WGSL divides by
//    textureDimensions(inputTex), NOT fullResolution). We mirror exactly:
//    NM_FragCoord(i) (top-left, +0.5 centered) / input tex size. tileOffset does
//    NOT enter the sample uv (the WGSL does not add it; H8 handled by NMFullscreen
//    top-left UV — no per-effect flip).
//  * renderScale: the GLSL multiplies the offset by `amount * renderScale`; the
//    canonical WGSL multiplies by `amount` ONLY. WGSL is authoritative, so
//    renderScale does NOT enter the offset here.
//  * `distance(convX, convY)` is GLSL/WGSL builtin Euclidean distance; ported
//    inline as length(convX - convY). It is NOT a per-effect distance metric —
//    but per golden-rule 2 we still keep it local (no shared dist lib).
//  * mix -> lerp. No PRNG / atan2 / select / nm_mod in this effect — no bit hazards.
//  * The kernels/offsets are local arrays exactly as in the WGSL; not reassociated.
//  * Core takes Texture2D + SamplerState + uv so the render pass and the Shader
//    Graph node share identical math (the function samples 9 + 1 times).
//  * Linear, clamp-to-edge, non-sRGB sampler (H7) — set on the SamplerState in
//    Sobel.shader / supplied by the Shader Graph node.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
// Bound by the runtime via MaterialPropertyBlock under these exact names.
float amount;   // globals.amount.uniform "amount", default 1.0 (min 0.1, max 5)
float alpha;    // globals.alpha.uniform  "alpha",  default 1.0 (min 0,   max 1)

// -----------------------------------------------------------------------------
// nm_sobel — core per-pixel evaluation. `tex`/`ss` are the input surface and its
// sampler; `uv` is the (top-left, +0.5 centered) fragment uv; `texSize` is the
// input texture's pixel dimensions (used to derive texelSize). Ported VERBATIM
// from sobel.wgsl. Reads `amount` / `alpha` from module-scope named uniforms.
// -----------------------------------------------------------------------------
float4 nm_sobel(Texture2D tex, SamplerState ss, float2 uv, float2 texSize)
{
    // let texelSize = 1.0 / texSize;
    float2 texelSize = 1.0 / texSize;

    // let origColor = textureSample(inputTex, inputSampler, uv);
    float4 origColor = tex.Sample(ss, uv);

    // Sobel X and Y kernels (verbatim ordering).
    float sobel_x[9] = { 1.0, 0.0, -1.0, 2.0, 0.0, -2.0, 1.0, 0.0, -1.0 };
    float sobel_y[9] = { 1.0, 2.0, 1.0, 0.0, 0.0, 0.0, -1.0, -2.0, -1.0 };

    float2 offsets[9] = {
        float2(-texelSize.x, -texelSize.y),
        float2(0.0, -texelSize.y),
        float2(texelSize.x, -texelSize.y),
        float2(-texelSize.x, 0.0),
        float2(0.0, 0.0),
        float2(texelSize.x, 0.0),
        float2(-texelSize.x, texelSize.y),
        float2(0.0, texelSize.y),
        float2(texelSize.x, texelSize.y)
    };

    float3 convX = float3(0.0, 0.0, 0.0);
    float3 convY = float3(0.0, 0.0, 0.0);

    for (int i = 0; i < 9; i = i + 1)
    {
        // sample = textureSample(inputTex, inputSampler, uv + offsets[i] * amount).rgb
        float3 sampleRgb = tex.Sample(ss, uv + offsets[i] * amount).rgb;
        convX = convX + sampleRgb * sobel_x[i];
        convY = convY + sampleRgb * sobel_y[i];
    }

    // let dist = distance(convX, convY);  (Euclidean distance == length of diff)
    float dist = length(convX - convY);

    // Multiply with original color.
    float3 result = origColor.rgb * dist;

    // Blend between original input and sobel result.
    float3 blended = lerp(origColor.rgb, result, alpha);

    return float4(blended, origColor.a);
}

#endif // NM_SOBEL_INCLUDED
