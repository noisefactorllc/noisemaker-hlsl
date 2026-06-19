#ifndef NM_EFFECT_SEAMLESS_INCLUDED
#define NM_EFFECT_SEAMLESS_INCLUDED

// =============================================================================
// Seamless.hlsl — filter/seamless (func: "seamless")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/filter/seamless/wgsl/seamless.wgsl
//
// Edge-blend cross-fade for seamless tiling: tiles the input by `repeat`,
// then 4-corner blends the seams using edgeWeight() with a selectable curve.
// Single render pass.
//
// PORTING-GUIDE notes / hazards handled:
//  * UV = pos.xy / textureDimensions(inputTex) — divide by INPUT TEXTURE size,
//    not fullResolution. NM_FragCoord(i) is the @builtin(position) analog.
//  * `fract2` helper is per-effect and is defined inline here (not in NMCore).
//  * `edgeWeight` helper is per-effect and is defined inline verbatim.
//  * `curve` is an int uniform; runtime branches guarded with [branch].
//  * textureSampleLevel(inputTex, samp, st, 0.0) -> inputTex.SampleLevel(...,0)
//  * textureSample(inputTex, samp, ...) -> inputTex.Sample(...)
//  * mix -> lerp, fract -> frac, vec2<f32> -> float2.
//  * No PCG/PRNG hazards in this effect.
//  * Linear, clamp-to-edge, non-sRGB sampler (H7).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (reference binding: inputTex) ------------------
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
float blend;  // globals.blend.uniform,  [0.0, 0.5]  default 0.25
float repeat; // globals.repeat.uniform, [1, 10]      default 2
int   curve;  // globals.curve.uniform,  0/1/2        default 1

// -----------------------------------------------------------------------------
// edgeWeight — verbatim from WGSL:
//   fn edgeWeight(t: f32, width: f32, c: i32) -> f32 {
//       if (width <= 0.0) { return 0.0; }
//       let d = min(t, 1.0 - t);
//       let w = 1.0 - clamp(d / width, 0.0, 1.0);
//       if (c == 0)      { return w; }
//       else if (c == 2) { return w * w; }
//       return w * w * (3.0 - 2.0 * w);
//   }
// -----------------------------------------------------------------------------
float nm_seamless_edgeWeight(float t, float width, int c)
{
    if (width <= 0.0) { return 0.0; }
    float d = min(t, 1.0 - t);
    float w = 1.0 - clamp(d / width, 0.0, 1.0);
    [branch]
    if (c == 0)
    {
        return w;
    }
    else if (c == 2)
    {
        return w * w;
    }
    return w * w * (3.0 - 2.0 * w);
}

// -----------------------------------------------------------------------------
// fract2 — verbatim from WGSL:
//   fn fract2(v: vec2<f32>) -> vec2<f32> { return v - floor(v); }
// (= frac in HLSL)
// -----------------------------------------------------------------------------
float2 nm_seamless_fract2(float2 v)
{
    return v - floor(v);
}

// =============================================================================
// NMFrag_seamless — core fragment, mirrors WGSL main() verbatim.
//
// WGSL main():
//   let texSize = vec2<f32>(textureDimensions(inputTex));
//   let uv = position.xy / texSize;
//   let st = fract2(uv * repeat);
//   let wx = edgeWeight(st.x, blend, curve);
//   let wy = edgeWeight(st.y, blend, curve);
//   let c00 = textureSampleLevel(inputTex, samp, st, 0.0);
//   let c10 = textureSample(inputTex, samp, fract2(st + vec2<f32>(0.5, 0.0)));
//   let c01 = textureSample(inputTex, samp, fract2(st + vec2<f32>(0.0, 0.5)));
//   let c11 = textureSample(inputTex, samp, fract2(st + vec2<f32>(0.5, 0.5)));
//   let mx0 = mix(c00, c10, wx);
//   let mx1 = mix(c01, c11, wx);
//   let result = mix(mx0, mx1, wy);
//   return vec4<f32>(result.rgb, 1.0);
// =============================================================================
float4 NMFrag_seamless(NMVaryings i) : SV_Target
{
    uint tw, th;
    inputTex.GetDimensions(tw, th);
    float2 texSize = float2((float)tw, (float)th);

    // WGSL: uv = position.xy / texSize   (top-left, +0.5 centered)
    float2 uv = NM_FragCoord(i) / texSize;

    float2 st = nm_seamless_fract2(uv * repeat);

    float wx = nm_seamless_edgeWeight(st.x, blend, curve);
    float wy = nm_seamless_edgeWeight(st.y, blend, curve);

    // textureSampleLevel with lod 0 -> SampleLevel(..., 0)
    float4 c00 = inputTex.SampleLevel(sampler_inputTex, st, 0);
    float4 c10 = inputTex.Sample(sampler_inputTex, nm_seamless_fract2(st + float2(0.5, 0.0)));
    float4 c01 = inputTex.Sample(sampler_inputTex, nm_seamless_fract2(st + float2(0.0, 0.5)));
    float4 c11 = inputTex.Sample(sampler_inputTex, nm_seamless_fract2(st + float2(0.5, 0.5)));

    float4 mx0    = lerp(c00, c10, wx);
    float4 mx1    = lerp(c01, c11, wx);
    float4 result = lerp(mx0, mx1, wy);

    return float4(result.rgb, 1.0);
}

#endif // NM_EFFECT_SEAMLESS_INCLUDED
