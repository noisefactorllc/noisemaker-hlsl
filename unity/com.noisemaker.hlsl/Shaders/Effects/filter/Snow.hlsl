#ifndef NM_EFFECT_SNOW_INCLUDED
#define NM_EFFECT_SNOW_INCLUDED

// =============================================================================
// Snow.hlsl — filter/snow (func: "snow")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/filter/snow/wgsl/snow.wgsl
//
// TV snow/static noise blended over the input image. Single render pass.
// RGB is modulated by animated noise; alpha is passed through unchanged.
//
// PORTING-GUIDE notes / hazards handled:
//  * Noise-hash `coord`: the parity GOLDEN is rendered by WebGL2 (the GLSL path),
//    and snow.glsl feeds the RAW pixel-centered fragment coord into the hash —
//    `vec2 pixelCoord = vec2(gl_FragCoord.x + tileOffset.x, gl_FragCoord.y +
//    tileOffset.y)` (snow.glsl:88), NOT a truncated integer (it truncates only for
//    the texelFetch on line 79). The WGSL COMPUTE variant uses integer
//    `f32(gid.xy)`, which differs from GLSL by the 0.5 pixel center. The hash is
//    chaotic, so that 0.5 fully decorrelates the field — a previous floor() here
//    matched WGSL but NOT the GLSL golden (parity SSIM ~0.43). We use the GLSL
//    form: `NM_GlobalCoord(i)` = NM_FragCoord(i)+tileOffset = gl_FragCoord.xy +
//    tileOffset (pixel-centered, +0.5). Do NOT floor.
//  * `select(params.time, 0.0, params.pause > 0.5)` is `pause>0.5 ? 0.0 : time`
//    — preserved literally as the ternary.
//  * inputTex is sampled with textureLoad/texelFetch (integer load) in WGSL/GLSL.
//    In this pipeline the input is a half-float RenderTexture bound via the
//    sampler path, so we replicate it the way every sibling filter does:
//    inputTex.Sample(sampler_inputTex, NM_FragCoord(i)/texSize) at the pixel
//    center. (A raw .Load bypasses the binding and yields SSIM ~0.)
//  * `snow_noise` conditional `speed==0.0 || time==0.0` is preserved verbatim
//    using [branch] to match the early-return semantics.
//  * `mix` -> `lerp`; `clamp`/`cos`/`sin`/`pow`/`abs` map 1:1.
//  * All constants (TAU, TIME_SEED_OFFSETS, STATIC_SEED, LIMITER_SEED)
//    copied verbatim from WGSL.
//  * `pause` is a float uniform (WGSL/GLSL both use float), compared > 0.5.
//  * Full 32-bit float; no half promotion (parity requirement).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture (integer-loaded, no sampler needed for texelFetch path) ---
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
float alpha;    // globals.alpha.uniform,   [0,1]   default 0.5
float pause;    // globals.pause.uniform,   bool    default false (0.0)
float density;  // globals.density.uniform, [0,100] default 75

// ---- Verbatim constants from WGSL ----
static const float NM_SNOW_TAU              = 6.283185307179586;
static const float3 NM_SNOW_TIME_SEED_OFFSETS = float3(97.0, 57.0, 131.0);
static const float3 NM_SNOW_STATIC_SEED      = float3(37.0, 17.0, 53.0);
static const float3 NM_SNOW_LIMITER_SEED     = float3(113.0, 71.0, 193.0);

// ---- Verbatim helpers from WGSL ----

float nm_snow_normalized_sine(float value)
{
    return (sin(value) + 1.0) * 0.5;
}

float nm_snow_periodic_value(float t, float value)
{
    return nm_snow_normalized_sine((t - value) * NM_SNOW_TAU);
}

float3 nm_snow_fract_vec3(float3 value)
{
    return value - floor(value);
}

float nm_snow_hash(float3 sample_in)
{
    float3 scaled   = nm_snow_fract_vec3(sample_in * 0.1031);
    float  dot_val  = dot(scaled, scaled.yzx + float3(33.33, 33.33, 33.33));
    float3 shifted  = scaled + dot_val;
    float  combined = (shifted.x + shifted.y) * shifted.z;
    float  fractional = combined - floor(combined);
    return clamp(fractional, 0.0, 1.0);
}

float nm_snow_noise(float2 coord, float t, float speed, float3 seed)
{
    float  angle      = t * NM_SNOW_TAU;
    float  z_base     = cos(angle) * speed;
    float3 base_sample = float3(coord.x + seed.x, coord.y + seed.y, z_base + seed.z);
    float  base_value  = nm_snow_hash(base_sample);

    [branch]
    if (speed == 0.0 || t == 0.0)
    {
        return base_value;
    }

    float3 time_seed   = seed + NM_SNOW_TIME_SEED_OFFSETS;
    float3 time_sample = float3(
        coord.x + time_seed.x,
        coord.y + time_seed.y,
        1.0 + time_seed.z
    );
    float time_value  = nm_snow_hash(time_sample);
    float scaled_time = nm_snow_periodic_value(t, time_value) * speed;
    float periodic    = nm_snow_periodic_value(scaled_time, base_value);
    return clamp(periodic, 0.0, 1.0);
}

// ---- Pass: "snow" (progName "snow") -----------------------------------------
// Mirrors WGSL main() body.
float4 NMFrag_snow(NMVaryings i) : SV_Target
{
    // WGSL textureLoad(inputTex, gid) / GLSL texelFetch — in this pipeline the
    // input is a half-float RenderTexture bound through the sampler path (the
    // canonical sibling-filter convention: Grain/Invert/Adjust/Dither all sample
    // via NM_FragCoord / texSize, never .Load). A raw .Load bypasses that binding
    // and returns garbage (parity SSIM ~0). Sample at the pixel center instead.
    uint texW, texH;
    inputTex.GetDimensions(texW, texH);
    float2 sampleUV = NM_FragCoord(i) / float2((float)texW, (float)texH);
    float4 texel    = inputTex.Sample(sampler_inputTex, sampleUV);
    float  alphaVal = clamp(alpha, 0.0, 1.0);

    if (alphaVal == 0.0)
    {
        return texel;
    }

    // Noise-hash coord. The reference golden is rendered by WebGL2 (the GLSL
    // path), whose snow.glsl feeds the RAW pixel-centered fragment coord into the
    // hash, NOT a truncated integer:
    //   GLSL: vec2 pixelCoord = vec2(gl_FragCoord.x + tileOffset.x,
    //                                gl_FragCoord.y + tileOffset.y);   (snow.glsl:88)
    //         snow_noise(pixelCoord, ...);
    // (snow.glsl truncates gl_FragCoord ONLY for the texelFetch on line 79, never
    // for the noise.) The WGSL compute variant uses integer f32(gid.xy), which
    // differs from GLSL by the 0.5 pixel center; since the hash is chaotic, that
    // 0.5 completely decorrelates the field. Match the GLSL golden exactly:
    // NM_GlobalCoord(i) = NM_FragCoord(i) + tileOffset = gl_FragCoord.xy + tileOffset
    // (pixel-centered, +0.5). Do NOT floor.
    float2 coord = NM_GlobalCoord(i);
    // select(params.time, 0.0, params.pause > 0.5) — pause>0.5 picks 0.0
    float  t     = (pause > 0.5) ? 0.0 : time;
    float  speed = 100.0;

    float static_value  = nm_snow_noise(coord, t, speed, NM_SNOW_STATIC_SEED);
    float limiter_value = nm_snow_noise(coord, t, speed, NM_SNOW_LIMITER_SEED);
    float d             = max(density * 0.01, 0.0001);
    float exponent      = (1.0 - d) / d;
    float limiter_mask  = pow(min(limiter_value, 0.99), exponent) * alphaVal;

    float3 static_color = float3(static_value, static_value, static_value);
    float3 mixed_rgb    = lerp(texel.xyz, static_color, float3(limiter_mask, limiter_mask, limiter_mask));

    return float4(mixed_rgb, texel.w);
}

#endif // NM_EFFECT_SNOW_INCLUDED
