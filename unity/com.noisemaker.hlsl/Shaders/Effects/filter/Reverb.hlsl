#ifndef NM_REVERB_INCLUDED
#define NM_REVERB_INCLUDED

// =============================================================================
// Reverb.hlsl — filter/reverb, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/reverb/wgsl/reverb.wgsl
//
// Visual reverb/echo: blends the input with multiple 2x-scaled samples of
// itself. Each octave halves its weight, producing a reverb/echo effect.
//
// WGSL main() outline:
//   let dimsU = textureDimensions(inputTex, 0);
//   let dims  = vec2<f32>(dimsU);
//   let uv    = pos.xy / dims;              // pos = @builtin(position), top-left
//   let original = textureSample(inputTex, inputSampler, uv);
//   var current  = original;
//   if (ridges != 0) { current = ridge_transform(current); }
//   var accum = current; var totalWeight = 1.0; var weight = 0.5; var scale = 2.0;
//   let iters = clamp(iterations, 1, 8);
//   for i in 0..iters:
//       let scaledUV = applyWrap(uv * scale);
//       var scaled   = textureSample(inputTex, inputSampler, scaledUV);
//       if (ridges != 0) { scaled = ridge_transform(scaled); }
//       accum += scaled * weight; totalWeight += weight; scale *= 2.0; weight *= 0.5;
//   let result = accum / totalWeight;
//   return vec4<f32>(mix(original.rgb, result.rgb, alpha), 1.0);
//
// PORTING-GUIDE notes:
//  * Single render pass (definition.js passes[0].program = "reverb").
//  * uv = fragCoord / inputTex dimensions (WGSL divides by textureDimensions NOT
//    fullResolution). Mirrored with NM_FragCoord(i) / GetDimensions.
//  * ridges is an int uniform; test != 0 (matches WGSL: ridges != 0).
//  * wrap int uniform: 0=mirror, 1=repeat, 2=clamp. Use [branch].
//  * applyWrap mirror mode: literal verbatim from WGSL (manual mirror formula,
//    NOT the fmod-style abs(mod) from GLSL — WGSL is canonical).
//  * nm_mod NOT used here (no float mod needed; applyWrap mirror uses floor arithmetic).
//  * No PRNG/atan2/select hazards.
//  * Linear, clamp-to-edge, non-sRGB sampler (H7).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
int   iterations; // default 3, range [1,8]
int   ridges;     // boolean as int, default 0
float alpha;      // default 1.0, range [0,1]
int   wrap;       // 0=mirror 1=repeat 2=clamp, default 0

// -----------------------------------------------------------------------------
// applyWrap — ported VERBATIM from reverb.wgsl applyWrap().
// Mirror mode uses the WGSL floor-arithmetic formula, NOT abs(mod(...)).
// WGSL:
//   if (wrap == 0) {
//       let mx = abs((uv.x + 1.0) - floor((uv.x + 1.0) * 0.5) * 2.0 - 1.0);
//       let my = abs((uv.y + 1.0) - floor((uv.y + 1.0) * 0.5) * 2.0 - 1.0);
//       return vec2<f32>(mx, my);
//   } else if (wrap == 1) { return fract(uv); }
//   return clamp(uv, vec2<f32>(0.0), vec2<f32>(1.0));
// -----------------------------------------------------------------------------
float2 applyWrap(float2 uv)
{
    [branch]
    if (wrap == 0) {
        float mx = abs((uv.x + 1.0) - floor((uv.x + 1.0) * 0.5) * 2.0 - 1.0);
        float my = abs((uv.y + 1.0) - floor((uv.y + 1.0) * 0.5) * 2.0 - 1.0);
        return float2(mx, my);
    } else if (wrap == 1) {
        return frac(uv);  // WGSL fract -> HLSL frac
    }
    return clamp(uv, float2(0.0, 0.0), float2(1.0, 1.0));
}

// -----------------------------------------------------------------------------
// ridge_transform — ported VERBATIM from reverb.wgsl ridge_transform().
// WGSL: return vec4<f32>(1.0) - abs(color * 2.0 - vec4<f32>(1.0));
// -----------------------------------------------------------------------------
float4 ridge_transform(float4 color)
{
    return float4(1.0, 1.0, 1.0, 1.0) - abs(color * 2.0 - float4(1.0, 1.0, 1.0, 1.0));
}

// -----------------------------------------------------------------------------
// nm_reverb — core per-pixel reverb accumulation.
// Takes the already-sampled original color and the inputTex + sampler + uv
// (needed for the inner loop re-samples). Returns the final blended RGBA.
// Ported VERBATIM from reverb.wgsl main().
// -----------------------------------------------------------------------------
float4 nm_reverb(float4 original, float2 uv, Texture2D inputTex, SamplerState samplerinputTex)
{
    float4 current = original;

    // WGSL: let useRidges: bool = ridges != 0;
    bool useRidges = (ridges != 0);
    if (useRidges) {
        current = ridge_transform(current);
    }

    float4 accum       = current;
    float  totalWeight = 1.0;
    float  weight      = 0.5;
    float  scale       = 2.0;

    int iters = clamp(iterations, 1, 8);
    for (int i = 0; i < iters; i = i + 1)
    {
        float2 scaledUV = applyWrap(uv * scale);
        float4 scaled   = inputTex.Sample(samplerinputTex, scaledUV);

        if (useRidges) {
            scaled = ridge_transform(scaled);
        }

        accum       = accum + scaled * weight;
        totalWeight = totalWeight + weight;

        scale  = scale  * 2.0;
        weight = weight * 0.5;
    }

    float4 result = accum / totalWeight;

    // WGSL: return vec4<f32>(mix(original.rgb, result.rgb, alpha), 1.0);
    return float4(lerp(original.rgb, result.rgb, alpha), 1.0);
}

#endif // NM_REVERB_INCLUDED
