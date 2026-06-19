#ifndef NM_EFFECT_POSTERIZE_INCLUDED
#define NM_EFFECT_POSTERIZE_INCLUDED

// =============================================================================
// Posterize.hlsl — filter/posterize (func: "posterize")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/filter/posterize/wgsl/posterize.wgsl
// (GLSL consulted only to disambiguate; both bodies are identical.)
//
// sRGB-aware color quantization with adjustable gamma. Single render pass:
//   1. sRGB->linear the input rgb.
//   2. Apply forward gamma (pow with gamma_value).
//   3. Quantize into `levels` bins (centered via half_step), with optional
//      derivative-based edge antialias (fwidth + smoothstep).
//   4. Apply inverse gamma, linear->sRGB, clamp01. Alpha passes through.
//
// Helpers (clamp_01, srgb<->linear component/rgb, pow_vec3) are ported VERBATIM
// and INLINE per PORTING-GUIDE — they are NOT hoisted into NMCore. This effect
// uses NO PCG/prng and NO nm_mod.
//
// NUMERIC / TRANSLATION HAZARDS handled:
//  * Sampling UV: WGSL uses `pos.xy / textureDimensions(inputTex, 0)` — divides
//    by the INPUT TEXTURE dimensions (NOT fullResolution, NOT fullResolution.y).
//    -> HLSL: inputTex.GetDimensions(w,h); uv = NM_FragCoord(i) / float2(w,h).
//    NM_FragCoord (no tileOffset) mirrors WGSL @builtin(position).xy.
//  * `antialias` is an i32 uniform in WGSL tested `!= 0`. Bound here as int and
//    tested `!= 0` (the WGSL form), not `> 0.5`.
//  * `levels`/`gamma` are f32 in WGSL (definition.js: int / float). Declared as
//    float uniforms so max()/round() reproduce the WGSL float math exactly.
//  * fract -> frac. fwidth/smoothstep/floor/round/pow/clamp/max map 1:1.
//  * sRGB transfer constants (0.04045, 12.92, 0.055, 1.055, 2.4, 0.0031308) and
//    1.0/2.4 kept literal exactly as the WGSL. MIN_LEVELS=1.0, MIN_GAMMA=1e-3.
//  * Early-return when levels_quantized <= 1.0 returns the raw texel unchanged.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (reference binding: sampler@0, inputTex@1) ------
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
// Bound by the runtime via MaterialPropertyBlock.
float levels;      // int in def.js (default 5, [2,32]); f32 in WGSL math
float gamma;       // float (default 1, [0.1,3])
int   antialias;   // boolean in def.js (default true); WGSL i32 tested != 0

static const float NM_POSTERIZE_MIN_LEVELS = 1.0;
static const float NM_POSTERIZE_MIN_GAMMA  = 1e-3;

// clamp_01(value) — verbatim WGSL.
float nm_posterize_clamp_01(float value)
{
    return clamp(value, 0.0, 1.0);
}

// srgb_to_linear_component(value) — verbatim WGSL.
float nm_posterize_srgb_to_linear_component(float value)
{
    if (value <= 0.04045)
    {
        return value / 12.92;
    }
    return pow((value + 0.055) / 1.055, 2.4);
}

// linear_to_srgb_component(value) — verbatim WGSL.
float nm_posterize_linear_to_srgb_component(float value)
{
    if (value <= 0.0031308)
    {
        return value * 12.92;
    }
    return 1.055 * pow(value, 1.0 / 2.4) - 0.055;
}

// srgb_to_linear_rgb(rgb) — verbatim WGSL (per-component).
float3 nm_posterize_srgb_to_linear_rgb(float3 rgb)
{
    return float3(
        nm_posterize_srgb_to_linear_component(rgb.x),
        nm_posterize_srgb_to_linear_component(rgb.y),
        nm_posterize_srgb_to_linear_component(rgb.z)
    );
}

// linear_to_srgb_rgb(rgb) — verbatim WGSL (per-component).
float3 nm_posterize_linear_to_srgb_rgb(float3 rgb)
{
    return float3(
        nm_posterize_linear_to_srgb_component(rgb.x),
        nm_posterize_linear_to_srgb_component(rgb.y),
        nm_posterize_linear_to_srgb_component(rgb.z)
    );
}

// pow_vec3(value, exponent) — verbatim WGSL.
float3 nm_posterize_pow_vec3(float3 value, float exponent)
{
    return pow(value, float3(exponent, exponent, exponent));
}

// =============================================================================
// nm_posterize — core per-pixel evaluation. `texel` is the already-sampled
// input RGBA. Mirrors WGSL main() body after the textureSample. Returns RGBA.
//
// NOTE: this uses fwidth(...) on `scaled` when antialias != 0, so it MUST be
// evaluated inside a fragment stage where screen-space derivatives are valid
// (the fullscreen frag pass and the Shader Graph node both satisfy this).
// =============================================================================
float4 nm_posterize(float4 texel)
{
    float levels_raw = max(levels, 0.0);
    float levels_quantized = max(round(levels_raw), NM_POSTERIZE_MIN_LEVELS);
    if (levels_quantized <= 1.0)
    {
        return texel;
    }

    float level_factor = levels_quantized;
    float inv_factor = 1.0 / level_factor;
    float half_step = inv_factor * 0.5;
    float gamma_value = max(gamma, NM_POSTERIZE_MIN_GAMMA);
    float inv_gamma = 1.0 / gamma_value;

    float3 working_rgb = nm_posterize_srgb_to_linear_rgb(texel.xyz);
    working_rgb = nm_posterize_pow_vec3(
        clamp(working_rgb, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0)),
        gamma_value);

    // Posterize with optional edge smoothing
    float3 scaled = working_rgb * level_factor + float3(half_step, half_step, half_step);
    float3 quantized_rgb;
    if (antialias != 0)
    {
        float3 f = frac(scaled);
        float3 fw = fwidth(scaled);
        float3 blend = smoothstep(0.5 - fw * 0.5, 0.5 + fw * 0.5, f);
        quantized_rgb = (floor(scaled) + blend) * inv_factor;
    }
    else
    {
        quantized_rgb = floor(scaled) * inv_factor;
    }
    quantized_rgb = nm_posterize_pow_vec3(
        clamp(quantized_rgb, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0)),
        inv_gamma);

    quantized_rgb = nm_posterize_linear_to_srgb_rgb(quantized_rgb);

    return float4(
        nm_posterize_clamp_01(quantized_rgb.x),
        nm_posterize_clamp_01(quantized_rgb.y),
        nm_posterize_clamp_01(quantized_rgb.z),
        texel.w);
}

// ---- Pass: "posterize" (progName "posterize") -------------------------------
float4 NMFrag_posterize(NMVaryings i) : SV_Target
{
    // WGSL: uv = pos.xy / textureDimensions(inputTex, 0); divide by INPUT TEX dims.
    uint w, h;
    inputTex.GetDimensions(w, h);
    float2 uv = NM_FragCoord(i) / float2((float)w, (float)h);
    float4 texel = inputTex.Sample(sampler_inputTex, uv);
    return nm_posterize(texel);
}

#endif // NM_EFFECT_POSTERIZE_INCLUDED
