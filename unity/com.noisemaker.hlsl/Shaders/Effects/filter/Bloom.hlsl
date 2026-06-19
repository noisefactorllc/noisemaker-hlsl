#ifndef NM_EFFECT_BLOOM_INCLUDED
#define NM_EFFECT_BLOOM_INCLUDED

// =============================================================================
// Bloom.hlsl — filter/bloom (func: "bloom")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL sources:
//   shaders/effects/filter/bloom/wgsl/brightPass.wgsl   (progName "brightPass")
//   shaders/effects/filter/bloom/wgsl/ntapGather.wgsl   (progName "ntapGather")
//   shaders/effects/filter/bloom/wgsl/composite.wgsl    (progName "composite")
//
// Multi-pass bloom (all math in linear color space):
//   brightPass : inputTex      -> _brightTex   bright-pass extraction
//                (luma threshold + soft-knee smoothstep)
//   ntapGather : _brightTex    -> _bloomTex    golden-angle spiral N-tap gather
//                (Gaussian-ish radial weights, energy-normalized)
//   composite  : inputTex + _bloomTex -> outputTex  tinted additive bloom
//
// This effect is multi-pass with two internal '_'-prefixed targets (_brightTex,
// _bloomTex). The C# runtime renders brightPass -> _brightTex, ntapGather reads
// _brightTex -> _bloomTex, composite reads inputTex + _bloomTex -> outputTex.
// It ships as a runtime-rendered Texture2D; NO Shader Graph Custom Function
// wrapper is provided (multi-pass effects cannot be a single Custom Function).
//
// NOT a feedback effect: no pass samples its own previous output. The '_' prefix
// here marks internal transient targets (per-frame intra-pass plumbing), not
// persistent/feedback history. No 'repeat:' and no MRT.
//
// PORTING-GUIDE notes / hazards handled:
//  * Ported from WGSL (top-left, canonical) — no per-effect Y flip (Golden #1).
//  * uv = pos.xy / texSize where texSize = textureDimensions(inputTex), i.e.
//    fragCoord / the INPUT TEXTURE's own size (NOT fullResolution, NOT tileOffset-
//    shifted; the WGSL adds no tileOffset). Mirrored as NM_FragCoord(i)/float2(w,h).
//  * ntapGather: the WGSL computes radiusUV = radius * texelSize with NO
//    renderScale multiply (the GLSL does `radius * renderScale * texelSize`). We
//    follow the WGSL (canonical) exactly: no renderScale. At renderScale==1 the
//    two agree. // TODO(verify): if export-tiled parity drifts, the GLSL scales
//    the kernel by renderScale here.
//  * Loop is taps-driven over a fixed MAX_TAPS bound with an early break (exactly
//    as the WGSL); marked [loop]. tapCount = clamp((int)taps, 1, 64). i32(taps)
//    is float->int truncation == HLSL (int) cast.
//  * GOLDEN_ANGLE = 2.39996323 and sigma = 0.4 are the literal WGSL constants.
//  * clamp(uv + offset*radiusUV, vec2(0.0), vec2(1.0)) -> clamp to [0,1] per axis.
//  * dot(rgb, float3(0.2126,0.7152,0.0722)) Rec.709 luma, verbatim.
//  * Soft-knee branch order matches WGSL: <=threshLow ->0, >=threshHigh ->1, else
//    Hermite t*t*(3-2*t). Reproduced literally (do NOT collapse to smoothstep()).
//  * composite: bloom is sampled (bilinear, clamp) per WGSL textureSample, NOT
//    texelFetch (the GLSL uses texelFetch; same result at 1:1 sizing, but we port
//    the WGSL). finalRgb = sceneColor.rgb + intensity * (bloom * tint).
//  * `_pad*` members in the WGSL Uniforms structs are alignment padding only; we
//    bind only the meaningful named uniforms.
//  * Full 32-bit float; linear, clamp-to-edge, non-sRGB samplers (set in .shader).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input textures + samplers (distinct input samplers across passes) -------
// brightPass + composite bind the effect's inputTex; ntapGather binds _brightTex
// (rebound by the runtime onto the same HLSL `inputTex` slot). composite also
// binds the gathered bloom via `bloomTex`. The WGSL reuses one inputSampler for
// both reads in composite; we expose a distinct SamplerState per texture and set
// both identically (bilinear/clamp/linear).
Texture2D    inputTex;
SamplerState sampler_inputTex;

Texture2D    bloomTex;        // composite: the gathered _bloomTex
SamplerState sampler_bloomTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
float threshold;  // brightPass : default 0.8,  [0,2]   step 0.05
float softKnee;   // brightPass : default 0.2,  [0,0.5] step 0.01
float radius;     // ntapGather : default 32,   [1,128] step 1
int   taps;       // ntapGather : default 8,    [8,64]  step 1
float intensity;  // composite  : default 1.0,  [0,3]   step 0.05
float3 tint;      // composite  : default (1,1,1)

// Golden angle for Poisson-like disk distribution (ntapGather)
static const float GOLDEN_ANGLE = 2.39996323;
static const int   MAX_TAPS     = 64;

// -----------------------------------------------------------------------------
// Pass "brightPass" — bright-pass extraction (verbatim from brightPass.wgsl)
// -----------------------------------------------------------------------------
float4 frag_brightPass(NMVaryings i) : SV_Target
{
    uint w, h;
    inputTex.GetDimensions(w, h);
    float2 texSize = float2((float)w, (float)h);
    float2 uv = NM_FragCoord(i) / texSize;
    float4 color = inputTex.Sample(sampler_inputTex, uv);

    // Compute luminance (Rec. 709)
    float luma = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));

    // Soft knee thresholding
    float knee = softKnee;
    float threshLow = threshold - knee;
    float threshHigh = threshold + knee;

    float bloomFactor;
    if (luma <= threshLow) {
        bloomFactor = 0.0;
    } else if (luma >= threshHigh) {
        bloomFactor = 1.0;
    } else {
        // Smoothstep for the soft knee region
        float t = (luma - threshLow) / (threshHigh - threshLow);
        bloomFactor = t * t * (3.0 - 2.0 * t);
    }

    // Multiply original HDR color by bloom factor
    float3 brightColor = color.rgb * bloomFactor;

    return float4(brightColor, color.a);
}

// -----------------------------------------------------------------------------
// Pass "ntapGather" — golden-angle spiral N-tap gather (verbatim from
// ntapGather.wgsl). Reads _brightTex (rebound onto inputTex), writes _bloomTex.
// -----------------------------------------------------------------------------
float4 frag_ntapGather(NMVaryings i) : SV_Target
{
    uint w, h;
    inputTex.GetDimensions(w, h);
    float2 texSize = float2((float)w, (float)h);
    float2 uv = NM_FragCoord(i) / texSize;
    float2 texelSize = 1.0 / texSize;

    // Bloom radius in UV space
    float2 radiusUV = radius * texelSize;

    // Clamp taps to valid range
    int tapCount = clamp((int)taps, 1, MAX_TAPS);

    float3 bloomAccum = float3(0.0, 0.0, 0.0);
    float weightSum = 0.0;

    // Generate N-tap kernel using golden angle spiral (Poisson-ish distribution)
    // with Gaussian-like radial falloff for weights
    [loop]
    for (int j = 0; j < MAX_TAPS; j++) {
        if (j >= tapCount) { break; }

        // Compute tap offset using golden angle spiral
        // r goes from 0 to 1 as sqrt(i/N) for uniform area distribution
        float t = (float)j / (float)tapCount;
        float r = sqrt(t);
        float theta = (float)j * GOLDEN_ANGLE;

        float2 offset = float2(cos(theta), sin(theta)) * r;

        // Gaussian-ish weight based on distance from center
        float sigma = 0.4;
        float weight = exp(-0.5 * (r * r) / (sigma * sigma));

        // Sample with clamped UV (edge handling)
        float2 sampleUV = clamp(uv + offset * radiusUV, float2(0.0, 0.0), float2(1.0, 1.0));
        float3 sampleColor = inputTex.Sample(sampler_inputTex, sampleUV).rgb;

        bloomAccum += sampleColor * weight;
        weightSum += weight;
    }

    // Normalize for energy conservation
    if (weightSum > 0.0) {
        bloomAccum /= weightSum;
    }

    return float4(bloomAccum, 1.0);
}

// -----------------------------------------------------------------------------
// Pass "composite" — tinted additive bloom (verbatim from composite.wgsl).
// Reads inputTex + bloomTex (=_bloomTex), writes outputTex.
// -----------------------------------------------------------------------------
float4 frag_composite(NMVaryings i) : SV_Target
{
    uint w, h;
    inputTex.GetDimensions(w, h);
    float2 texSize = float2((float)w, (float)h);
    float2 uv = NM_FragCoord(i) / texSize;

    // Get original scene color (HDR)
    float4 sceneColor = inputTex.Sample(sampler_inputTex, uv);

    // Get bloom color
    float3 bloom = bloomTex.Sample(sampler_bloomTex, uv).rgb;

    // Apply tint
    bloom *= tint;

    // Additive blend: finalHDR = sceneColor + intensity * bloom
    float3 finalRgb = sceneColor.rgb + intensity * bloom;

    return float4(finalRgb, sceneColor.a);
}

#endif // NM_EFFECT_BLOOM_INCLUDED
