#ifndef NM_EFFECT_ZOOMBLUR_INCLUDED
#define NM_EFFECT_ZOOMBLUR_INCLUDED

// =============================================================================
// ZoomBlur.hlsl — filter/zoomBlur (func: "zoomBlur")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/filter/zoomBlur/wgsl/zoomBlur.wgsl
//
// Radial / zoom blur emanating from the frame center. 41 weighted samples
// (t = 0..40 inclusive) are taken along the vector from each pixel toward the
// center, jittered by a fixed PRNG offset to mask the discrete sample count.
// Single render pass. Output alpha is forced to 1.0 (matches WGSL).
//
// PORTING-GUIDE notes / hazards handled:
//  * Sample UV uses `uv = pos.xy / textureDimensions(inputTex)` in the WGSL —
//    i.e. fragCoord divided by the INPUT TEXTURE's own dimensions, NOT
//    fullResolution. WGSL is canonical; we mirror it: NM_FragCoord(i) / texSize.
//    NM_FragCoord (top-left, +0.5 centered) is the @builtin(position) analog;
//    no per-effect Y flip (H8).
//  * PRNG (H11): this effect's own `prng` does NOT sign-fold its input before the
//    float->uint cast — it casts directly `vec3<u32>(p)` (truncation toward zero).
//    NMCore's nm_prng() applies a sign-fold (x>=0 ? x*2 : -x*2+1) which would
//    produce DIFFERENT lattice coords for the positive inputs here (e.g. 12.9898
//    -> 12u, not 25u). So we DO NOT call nm_prng; we reuse only nm_pcg (identical
//    in all references) and reimplement this effect's prng verbatim inline.
//    Divisor is 4294967295.0 (= float(0xffffffffu)), not 2^32.
//  * `vec3<f32>(0.0)` accumulator splat -> float3(0,0,0).
//  * textureSampleLevel(...,0.0) -> .SampleLevel(ss, uv, 0). Linear, clamp,
//    non-sRGB sampler (H7) — set on the SamplerState in ZoomBlur.shader / node.
//  * Loop bound is inclusive `t <= 40.0` exactly as written (H: keep bounds).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (reference binding: sampler@0, inputTex@1) ------
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
// Bound by the runtime via MaterialPropertyBlock by these exact names.
float strength;   // globals.strength.uniform, [0,1], default 0.5

// -----------------------------------------------------------------------------
// prng — VERBATIM from this effect's WGSL `prng(p)`:
//   return vec3<f32>(pcg(vec3<u32>(p))) / f32(0xffffffffu);
// NOTE: NO sign-fold (unlike NMCore nm_prng). uint3(p) is float->uint TRUNCATION
// toward zero. Reuses nm_pcg (identical PCG hash across all references).
// -----------------------------------------------------------------------------
float3 nm_zoomBlur_prng(float3 p)
{
    return float3(nm_pcg((uint3)p)) / 4294967295.0;
}

// =============================================================================
// nm_zoomBlur — core per-pixel evaluation. Mirrors the WGSL main() body.
//   var color = vec3<f32>(0.0);
//   var total = 0.0;
//   let toCenter = uv - 0.5;
//   let offset = prng(vec3<f32>(12.9898, 78.233, 151.7182)).x;
//   for (var t = 0.0; t <= 40.0; t = t + 1.0) {
//       let percent = (t + offset) / 40.0;
//       let weight  = 4.0 * (percent - percent * percent);
//       let tex     = textureSampleLevel(inputTex, inputSampler,
//                       uv + toCenter * percent * strength, 0.0);
//       color += tex.rgb * weight;
//       total += weight;
//   }
//   color = color / total;
//   return vec4<f32>(color, 1.0);
// =============================================================================
float4 nm_zoomBlur(float2 uv, Texture2D inTex, SamplerState ss)
{
    float3 color = float3(0.0, 0.0, 0.0);
    float total = 0.0;
    float2 toCenter = uv - 0.5;

    // Randomize the lookup values to hide the fixed number of samples
    float offset = nm_zoomBlur_prng(float3(12.9898, 78.233, 151.7182)).x;

    for (float t = 0.0; t <= 40.0; t = t + 1.0)
    {
        float percent = (t + offset) / 40.0;
        float weight = 4.0 * (percent - percent * percent);
        float4 tex = inTex.SampleLevel(ss, uv + toCenter * percent * strength, 0.0);
        color = color + tex.rgb * weight;
        total = total + weight;
    }

    color = color / total;

    return float4(color, 1.0);
}

// ---- Pass: "zoomBlur" (progName "zoomBlur") ----------------------------------
float4 NMFrag_zoomBlur(NMVaryings i) : SV_Target
{
    // WGSL: texSize = vec2<f32>(textureDimensions(inputTex));
    //       uv      = pos.xy / texSize;   (pos = @builtin(position), top-left)
    uint w, h;
    inputTex.GetDimensions(w, h);
    float2 texSize = float2((float)w, (float)h);
    float2 uv = NM_FragCoord(i) / texSize;

    return nm_zoomBlur(uv, inputTex, sampler_inputTex);
}

#endif // NM_EFFECT_ZOOMBLUR_INCLUDED
