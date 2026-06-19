#ifndef NM_CELSHADING_INCLUDED
#define NM_CELSHADING_INCLUDED

// =============================================================================
// CelShading.hlsl — filter/celShading (func: "celShading")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL sources:
//   shaders/effects/filter/celShading/wgsl/celShadingColor.wgsl (progName "celShadingColor")
//   shaders/effects/filter/celShading/wgsl/celShadingEdges.wgsl (progName "celShadingEdges")
//   shaders/effects/filter/celShading/wgsl/celShadingBlend.wgsl (progName "celShadingBlend")
//
// Cartoon-style shading with posterization + Sobel outlines. THREE render passes:
//   1. celShadingColor : sRGB-aware color quantization + diffuse shading
//                        (inputTex -> celShadingColorTex)
//   2. celShadingEdges : Sobel edge detection on the quantized colors
//                        (celShadingColorTex -> celShadingEdgeTex)
//   3. celShadingBlend : composite cel color + edge color, mix with original
//                        (inputTex + celShadingColorTex + celShadingEdgeTex -> outputTex)
//
// NOTE: this effect is MULTI-PASS and ships as a runtime-rendered Texture2D
// (the C# runtime renders the three passes in order into intermediate targets).
// No Shader Graph Custom Function wrapper is provided.
//
// PORTING-GUIDE notes / hazards handled:
//  * Ported from WGSL (top-left, canonical) — no per-effect Y flip (golden rule 1).
//  * Helpers (srgb<->linear, pow_vec3, getLuminosity, wrapCoord) are this effect's
//    OWN copies — ported VERBATIM inline (golden rule 2). Not hoisted/shared.
//  * Color/Blend passes: uv = pos.xy / textureDimensions(<sampledTex>) — fragCoord
//    divided by the SAMPLED TEXTURE's own size, NOT fullResolution, NOT tileOffset-
//    shifted (the WGSL adds no tileOffset). NM_FragCoord(i) is the @builtin(position)
//    (top-left, +0.5 centered) analog.
//  * Edges pass: integer texel fetch (WGSL textureLoad / GLSL texelFetch) with
//    REPEAT wrapping via wrapCoord, at coord = vec2<i32>(pos.xy). HLSL analog uses
//    colorTex.Load(int3(x, y, 0)). coord = (int2)NM_FragCoord(i) (truncation of the
//    +0.5-centered fragCoord, matching i32(pos.xy)).
//  * renderScale: WGSL `select(uniforms.renderScale, 1.0, uniforms.renderScale<=0.0)`
//    — WGSL select(falseVal, trueVal, cond) is REVERSED vs C ternary. It yields 1.0
//    when renderScale<=0, else renderScale. We reproduce as a ternary with that exact
//    semantics. `renderScale` is the engine global from NMFullscreen.
//  * `antialias`: WGSL `antialias: i32`, tested `!= 0`. definition.js types boolean
//    (default false). Declared as `int` uniform; tested `!= 0` (matches WGSL).
//  * `levels`: WGSL `levels: i32`, then `f32(levels)`. definition.js int default 4.
//    Declared `int`; `lev = (float)levels`.
//  * fwidth: HLSL `fwidth` == WGSL `fwidth` (abs(ddx)+abs(ddy)). Used only in the
//    antialias branch of the color pass, mirroring the WGSL exactly.
//  * No PRNG / no atan2 / no nm_mod in this effect — int `%` in wrapCoord matches
//    WGSL `%` (truncating), with the explicit +size negative fixup reproduced.
//  * Render targets are linear half-float, non-sRGB (H2/H7). The srgb<->linear
//    conversions here are the effect's OWN per-pixel math (part of the algorithm),
//    NOT pipeline color management — keep them verbatim.
//  * Linear, clamp-to-edge, non-sRGB samplers (H7) — set on the SamplerStates in
//    CelShading.shader. The edge pass uses .Load (no sampler state involved).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input / intermediate textures + samplers -------------------------------
// The runtime rebinds these per pass by name:
//   celShadingColor : inputTex (effect input)
//   celShadingEdges : colorTex (= celShadingColorTex)
//   celShadingBlend : inputTex (effect input), colorTex (celShadingColorTex),
//                     edgeTex (celShadingEdgeTex)
Texture2D    inputTex;
SamplerState sampler_inputTex;
Texture2D    colorTex;
SamplerState sampler_colorTex;
Texture2D    edgeTex;
SamplerState sampler_edgeTex;

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
// Bound by the runtime via MaterialPropertyBlock under these exact names.
float  mixAmount;       // globals.mix.uniform   "mixAmount",     default 1.0
int    levels;          // globals.levels.uniform "levels",        default 4
float  gamma;           // globals.gamma.uniform  "gamma",         default 0.65
int    antialias;       // globals.antialias.uniform "antialias",  default 0 (false)
float  edgeWidth;       // globals.edgeWidth.uniform "edgeWidth",   default 1 (int-typed)
float  edgeThreshold;   // globals.edgeThreshold.uniform "edgeThreshold", default 0.15
float3 edgeColor;       // globals.edgeColor.uniform "edgeColor",   default (0,0,0)
float3 lightDirection;  // globals.lightDirection.uniform "lightDirection", default (0.5,0.5,1.0)
float  strength;        // globals.strength.uniform "strength",     default 0.0

// =============================================================================
// Pass 1: celShadingColor — verbatim from celShadingColor.wgsl
// =============================================================================

static const float MIN_GAMMA = 1e-3;

// srgb_to_linear_component — VERBATIM from celShadingColor.wgsl. Per-effect copy.
float srgb_to_linear_component(float value)
{
    if (value <= 0.04045) {
        return value / 12.92;
    }
    return pow((value + 0.055) / 1.055, 2.4);
}

// linear_to_srgb_component — VERBATIM from celShadingColor.wgsl. Per-effect copy.
float linear_to_srgb_component(float value)
{
    if (value <= 0.0031308) {
        return value * 12.92;
    }
    return 1.055 * pow(value, 1.0 / 2.4) - 0.055;
}

// srgb_to_linear_rgb — VERBATIM from celShadingColor.wgsl. Per-effect copy.
float3 srgb_to_linear_rgb(float3 rgb)
{
    return float3(
        srgb_to_linear_component(rgb.x),
        srgb_to_linear_component(rgb.y),
        srgb_to_linear_component(rgb.z)
    );
}

// linear_to_srgb_rgb — VERBATIM from celShadingColor.wgsl. Per-effect copy.
float3 linear_to_srgb_rgb(float3 rgb)
{
    return float3(
        linear_to_srgb_component(rgb.x),
        linear_to_srgb_component(rgb.y),
        linear_to_srgb_component(rgb.z)
    );
}

// pow_vec3 — VERBATIM from celShadingColor.wgsl. Per-effect copy.
float3 pow_vec3(float3 value, float exponent)
{
    return float3(
        pow(value.x, exponent),
        pow(value.y, exponent),
        pow(value.z, exponent)
    );
}

float4 fragCelShadingColor(NMVaryings i) : SV_Target
{
    // WGSL:
    //   let texSize = vec2<f32>(textureDimensions(inputTex));
    //   let uv      = pos.xy / texSize;
    uint tw, th;
    inputTex.GetDimensions(tw, th);
    float2 texSize = float2(tw, th);
    float2 uv = NM_FragCoord(i) / texSize;

    float4 origColor = inputTex.Sample(sampler_inputTex, uv);
    float lev = (float)levels;

    // Apply diffuse shading based on light direction
    float3 lightDir = normalize(lightDirection);
    float gradientShade = dot(normalize(float3(uv - 0.5, 0.5)), lightDir);
    float diffuse = 0.5 + 0.5 * gradientShade;
    float shadeFactor = lerp(1.0, 0.5 + 0.5 * diffuse, strength);
    float3 shadedColor = origColor.rgb * shadeFactor;

    // sRGB-aware quantization
    float gamma_value = max(gamma, MIN_GAMMA);
    float inv_gamma = 1.0 / gamma_value;
    float inv_factor = 1.0 / lev;
    float half_step = inv_factor * 0.5;

    float3 working_rgb = srgb_to_linear_rgb(shadedColor);
    working_rgb = pow_vec3(clamp(working_rgb, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0)), gamma_value);

    // Posterize with optional edge smoothing
    float3 scaled = working_rgb * lev + float3(half_step, half_step, half_step);
    float3 quantized_rgb;
    if (antialias != 0) {
        float3 f = frac(scaled);
        float3 fw = fwidth(scaled);
        float3 blend = smoothstep(0.5 - fw * 0.5, 0.5 + fw * 0.5, f);
        quantized_rgb = (floor(scaled) + blend) * inv_factor;
    } else {
        quantized_rgb = floor(scaled) * inv_factor;
    }
    quantized_rgb = pow_vec3(clamp(quantized_rgb, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0)), inv_gamma);
    quantized_rgb = linear_to_srgb_rgb(quantized_rgb);

    return float4(clamp(quantized_rgb, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0)), origColor.a);
}

// =============================================================================
// Pass 2: celShadingEdges — verbatim from celShadingEdges.wgsl
// Samples colorTex (= celShadingColorTex).
// =============================================================================

// getLuminosity — VERBATIM from celShadingEdges.wgsl. Per-effect copy.
float getLuminosity(float3 color)
{
    return dot(color, float3(0.299, 0.587, 0.114));
}

// wrapCoord — VERBATIM from celShadingEdges.wgsl. Per-effect copy.
int wrapCoord(int value, int size)
{
    if (size <= 0) {
        return 0;
    }
    int wrapped = value % size;
    if (wrapped < 0) {
        wrapped = wrapped + size;
    }
    return wrapped;
}

float4 fragCelShadingEdges(NMVaryings i) : SV_Target
{
    // WGSL: let texSize = vec2<i32>(textureDimensions(colorTex));
    uint cw, ch;
    colorTex.GetDimensions(cw, ch);
    int2 texSize = int2((int)cw, (int)ch);
    if (texSize.x == 0 || texSize.y == 0) {
        return float4(0.0, 0.0, 0.0, 0.0);
    }

    // WGSL: let coord = vec2<i32>(pos.xy);  (truncation of the +0.5-centered coord)
    int2 coord = (int2)NM_FragCoord(i);

    // Sample 3x3 neighborhood with thickness scaling. WGSL:
    //   let renderScale = select(uniforms.renderScale, 1.0, uniforms.renderScale <= 0.0);
    //   let offset = max(1, i32(uniforms.edgeWidth * renderScale));
    // WGSL select(falseVal, trueVal, cond): 1.0 when renderScale<=0, else renderScale.
    float rs = (renderScale <= 0.0) ? 1.0 : renderScale;
    int offset = max(1, (int)(edgeWidth * rs));
    float samples[9];
    int idx = 0;
    for (int ky = -1; ky <= 1; ky = ky + 1) {
        for (int kx = -1; kx <= 1; kx = kx + 1) {
            int sampleX = wrapCoord(coord.x + kx * offset, texSize.x);
            int sampleY = wrapCoord(coord.y + ky * offset, texSize.y);
            float4 texel = colorTex.Load(int3(sampleX, sampleY, 0));
            samples[idx] = getLuminosity(texel.rgb);
            idx = idx + 1;
        }
    }

    // Sobel X kernel: [-1 0 1; -2 0 2; -1 0 1]
    float gx = -samples[0] + samples[2] - 2.0*samples[3] + 2.0*samples[5] - samples[6] + samples[8];

    // Sobel Y kernel: [-1 -2 -1; 0 0 0; 1 2 1]
    float gy = -samples[0] - 2.0*samples[1] - samples[2] + samples[6] + 2.0*samples[7] + samples[8];

    // Calculate edge magnitude
    float magnitude = sqrt(gx * gx + gy * gy);

    // Apply threshold with smoothstep for anti-aliased edges
    float edge = smoothstep(edgeThreshold * 0.5, edgeThreshold * 1.5, magnitude);

    return float4(edge, edge, edge, 1.0);
}

// =============================================================================
// Pass 3: celShadingBlend — verbatim from celShadingBlend.wgsl
// Samples inputTex (effect input), colorTex (celShadingColorTex),
// edgeTex (celShadingEdgeTex). All sampled at uv = pos.xy / inputTex dimensions.
// =============================================================================

float4 fragCelShadingBlend(NMVaryings i) : SV_Target
{
    // WGSL:
    //   let texSize = vec2<f32>(textureDimensions(inputTex));
    //   let uv      = pos.xy / texSize;
    uint tw, th;
    inputTex.GetDimensions(tw, th);
    float2 texSize = float2(tw, th);
    float2 uv = NM_FragCoord(i) / texSize;

    float4 origColor = inputTex.Sample(sampler_inputTex, uv);
    float4 celColor = colorTex.Sample(sampler_colorTex, uv);
    float edgeStrength = edgeTex.Sample(sampler_edgeTex, uv).r;

    // Apply edge color where edges are detected
    float3 finalColor = lerp(celColor.rgb, edgeColor, edgeStrength);

    // Mix with original based on mix amount
    finalColor = lerp(origColor.rgb, finalColor, mixAmount);

    return float4(finalColor, origColor.a);
}

#endif // NM_CELSHADING_INCLUDED
