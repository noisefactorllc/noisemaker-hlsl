#ifndef NM_EFFECT_CONVOLUTIONFEEDBACK_INCLUDED
#define NM_EFFECT_CONVOLUTIONFEEDBACK_INCLUDED

// =============================================================================
// ConvolutionFeedback.hlsl — filter/convolutionFeedback (func "convolutionFeedback")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL sources:
//   shaders/effects/filter/convolutionFeedback/wgsl/cfSharpen.wgsl (progName "cfSharpen")
//   shaders/effects/filter/convolutionFeedback/wgsl/cfBlur.wgsl    (progName "cfBlur")
//   shaders/effects/filter/convolutionFeedback/wgsl/cfBlend.wgsl   (progName "cfBlend")
//
// Three-pass temporal-feedback effect:
//   1) cfSharpen: unsharp-mask the PREVIOUS-FRAME feedback texture (selfTex) into
//      the transient internal texture _cfSharpened.
//   2) cfBlur:    Gaussian-blur _cfSharpened into transient internal _cfBlurred.
//   3) cfBlend:   lerp(input, processed feedback, intensity) -> output. resetState
//      bypasses feedback (returns input). Because pass 3 writes the chain output
//      surface and pass 1 reads it as selfTex, the surface is double-buffered by
//      the runtime (feedback ping-pong): pass 1 reads last frame's output.
//
// NOTE: multi-pass + persistent feedback effect. Ships as a runtime-rendered
// Texture2D (the C# runtime renders cfSharpen -> _cfSharpened, cfBlur ->
// _cfBlurred, cfBlend -> output, rebinding the feedback surface each frame). No
// Shader Graph Custom Function wrapper is provided (Shader Graph cannot express
// the persistent feedback target or the internal ping-pong).
//
// PORTING-GUIDE notes / hazards handled:
//  * Ported from WGSL (top-left, canonical). All three passes use
//    `textureLoad(tex, vec2<i32>(position.xy), 0)` — an INTEGER TEXEL FETCH, not a
//    sampled UV lookup. HLSL analog is `tex.Load(int3(x, y, 0))`. No sampler, no
//    divide-by-dimensions, no tileOffset, no bilinear filtering.
//  * coord = vec2<i32>(position.xy). position.xy is top-left, +0.5 centered;
//    (int)(px+0.5) == px. NM_FragCoord(i) is the HLSL analog; truncate to int.
//  * The WGSL uses the RAW radius uniforms (sharpenRadius / blurRadius), NO
//    renderScale multiply (the GLSL does `int(radius * renderScale)`). We follow
//    the WGSL (canonical) exactly. At renderScale==1 the two agree (H1).
//  * sigma = f32(radius) / 2.0 (NOTE: /2.0 here, unlike filter/blur which uses
//    /3.0). weight = exp(-dist2 / (2.0 * sigma2)) with dist2 = kx*kx + ky*ky
//    (the FULL 2D squared distance, a true 2D Gaussian — NOT separable).
//  * Loops are radius-driven (dynamic bounds), marked [loop]. Bounds inclusive
//    `k <= radius` exactly as written. samplePos clamped to [0, texSize-1].
//  * `i32(...)` / `vec2<i32>` -> (int) truncation toward zero (HLSL (int) cast).
//  * mix -> lerp; clamp/exp map 1:1; vec3<f32>(0.0) -> float3(0,0,0).
//  * resetState compared `!= 0` exactly (WGSL `uniforms.resetState != 0`).
//  * Render targets are linear (no sRGB); .Load reads raw texels.
//  * `_pad*` members in the WGSL Uniforms structs are alignment padding only;
//    we bind only the meaningful named uniforms.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-pass input textures (integer texel fetch via .Load; no sampler) -----
// cfSharpen.inputTex  = selfTex   (previous-frame feedback surface)
// cfBlur.inputTex     = _cfSharpened
// cfBlend.inputTex    = inputTex   (the effect's current-frame input)
// cfBlend.feedbackTex = _cfBlurred
// The runtime rebinds the HLSL `inputTex` slot per pass; `feedbackTex` is bound
// only for the blend pass. SamplerStates are declared for completeness/parity
// even though .Load does not use them.
Texture2D    inputTex;
SamplerState sampler_inputTex;
Texture2D    feedbackTex;
SamplerState sampler_feedbackTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
int   sharpenRadius;  // globals.sharpenRadius, [1,10] step 1, default 5
float sharpenAmount;  // globals.sharpenAmount, [0,3] step 0.1, default 2.5
int   blurRadius;     // globals.blurRadius,    [1,10] step 1, default 4
float blurAmount;     // globals.blurAmount,    [0,1] step 0.01, default 0.5
float intensity;      // globals.intensity,     [0,1] step 0.01, default 0.75
int   resetState;     // globals.resetState (boolean as int 0/1), default 0

// -----------------------------------------------------------------------------
// Pass "cfSharpen" — unsharp mask. Verbatim from cfSharpen.wgsl main().
// WGSL:
//   let texSize = vec2<i32>(textureDimensions(inputTex));
//   let coord = vec2<i32>(in.position.xy);
//   let center = textureLoad(inputTex, coord, 0);
//   let radius = uniforms.sharpenRadius; let amount = uniforms.sharpenAmount;
//   if (radius <= 0 || amount <= 0.0) { return center; }
//   let sigma = f32(radius) / 2.0; let sigma2 = sigma * sigma;
//   var blurSum = vec3<f32>(0.0); var weightSum = 0.0;
//   for ky in [-radius,radius]: for kx in [-radius,radius]:
//     samplePos = clamp(coord+vec2(kx,ky), 0, texSize-1);
//     dist2 = f32(kx*kx + ky*ky); weight = exp(-dist2 / (2.0*sigma2));
//     texSample = textureLoad(inputTex, samplePos, 0);
//     blurSum += texSample.rgb * weight; weightSum += weight;
//   let blurred = blurSum / weightSum;
//   var sharpened = center.rgb + amount * (center.rgb - blurred);
//   sharpened = clamp(sharpened, 0.0, 1.0);
//   return vec4<f32>(sharpened, center.a);
// -----------------------------------------------------------------------------
float4 frag_cfSharpen(NMVaryings i) : SV_Target
{
    uint tw, th;
    inputTex.GetDimensions(tw, th);
    int2 texSize = int2((int)tw, (int)th);
    int2 coord = (int2)NM_FragCoord(i);

    float4 center = inputTex.Load(int3(coord, 0));

    int   radius = sharpenRadius;
    float amount = sharpenAmount;

    if (radius <= 0 || amount <= 0.0)
    {
        return center;
    }

    // Compute Gaussian-weighted blur for unsharp mask
    float sigma  = (float)radius / 2.0;
    float sigma2 = sigma * sigma;

    float3 blurSum   = float3(0.0, 0.0, 0.0);
    float  weightSum = 0.0;

    [loop]
    for (int ky = -radius; ky <= radius; ky = ky + 1)
    {
        [loop]
        for (int kx = -radius; kx <= radius; kx = kx + 1)
        {
            int2 samplePos = coord + int2(kx, ky);
            samplePos = clamp(samplePos, int2(0, 0), texSize - int2(1, 1));

            float dist2  = (float)(kx * kx + ky * ky);
            float weight = exp(-dist2 / (2.0 * sigma2));

            float4 texSample = inputTex.Load(int3(samplePos, 0));
            blurSum   = blurSum + texSample.rgb * weight;
            weightSum = weightSum + weight;
        }
    }

    float3 blurred = blurSum / weightSum;

    // Unsharp mask: sharpened = original + amount * (original - blurred)
    float3 sharpened = center.rgb + amount * (center.rgb - blurred);
    sharpened = clamp(sharpened, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));

    return float4(sharpened, center.a);
}

// -----------------------------------------------------------------------------
// Pass "cfBlur" — Gaussian blur. Verbatim from cfBlur.wgsl main().
// WGSL: identical structure to cfSharpen but uses blurRadius/blurAmount and
//   blends via mix(center.rgb, blurred, amount) instead of an unsharp mask.
//   let radius = uniforms.blurRadius; let amount = uniforms.blurAmount;
//   if (radius <= 0 || amount <= 0.0) { return center; }
//   ... (same Gaussian accumulation into `sum`/`weightSum`) ...
//   let blurred = sum / weightSum;
//   let result = mix(center.rgb, blurred, amount);
//   return vec4<f32>(result, center.a);
// -----------------------------------------------------------------------------
float4 frag_cfBlur(NMVaryings i) : SV_Target
{
    uint tw, th;
    inputTex.GetDimensions(tw, th);
    int2 texSize = int2((int)tw, (int)th);
    int2 coord = (int2)NM_FragCoord(i);

    float4 center = inputTex.Load(int3(coord, 0));
    int   radius = blurRadius;
    float amount = blurAmount;

    if (radius <= 0 || amount <= 0.0)
    {
        return center;
    }

    // Compute sigma for Gaussian (radius ~= 2*sigma for good coverage)
    float sigma  = (float)radius / 2.0;
    float sigma2 = sigma * sigma;

    float3 sum       = float3(0.0, 0.0, 0.0);
    float  weightSum = 0.0;

    [loop]
    for (int ky = -radius; ky <= radius; ky = ky + 1)
    {
        [loop]
        for (int kx = -radius; kx <= radius; kx = kx + 1)
        {
            int2 samplePos = coord + int2(kx, ky);
            samplePos = clamp(samplePos, int2(0, 0), texSize - int2(1, 1));

            float dist2  = (float)(kx * kx + ky * ky);
            float weight = exp(-dist2 / (2.0 * sigma2));

            float4 texSample = inputTex.Load(int3(samplePos, 0));
            sum       = sum + texSample.rgb * weight;
            weightSum = weightSum + weight;
        }
    }

    float3 blurred = sum / weightSum;

    // Mix between original and blurred based on blurAmount
    float3 result = lerp(center.rgb, blurred, amount);

    return float4(result, center.a);
}

// -----------------------------------------------------------------------------
// Pass "cfBlend" — blend processed feedback with input. Verbatim from cfBlend.wgsl.
// WGSL:
//   let coord = vec2<i32>(in.position.xy);
//   let input = textureLoad(inputTex, coord, 0);
//   if (uniforms.resetState != 0) { return input; }
//   let feedback = textureLoad(feedbackTex, coord, 0);
//   let result = mix(input.rgb, feedback.rgb, uniforms.intensity);
//   return vec4<f32>(result, input.a);
// -----------------------------------------------------------------------------
float4 frag_cfBlend(NMVaryings i) : SV_Target
{
    int2 coord = (int2)NM_FragCoord(i);

    float4 input = inputTex.Load(int3(coord, 0));

    // If resetState is true, bypass feedback and return input directly
    if (resetState != 0)
    {
        return input;
    }

    float4 feedback = feedbackTex.Load(int3(coord, 0));

    // Blend input with processed feedback based on intensity
    float3 result = lerp(input.rgb, feedback.rgb, intensity);

    return float4(result, input.a);
}

#endif // NM_EFFECT_CONVOLUTIONFEEDBACK_INCLUDED
