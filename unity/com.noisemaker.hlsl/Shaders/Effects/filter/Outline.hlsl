#ifndef NM_EFFECT_OUTLINE_INCLUDED
#define NM_EFFECT_OUTLINE_INCLUDED

// =============================================================================
// Outline.hlsl — filter/outline (func: "outline")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL sources:
//   shaders/effects/filter/outline/wgsl/outlineValueMap.wgsl (progName "outlineValueMap")
//   shaders/effects/filter/outline/wgsl/outlineSobel.wgsl    (progName "outlineSobel")
//   shaders/effects/filter/outline/wgsl/outlineBlend.wgsl    (progName "outlineBlend")
//
// Three-pass edge-stroke filter:
//   1. valueMap : inputTex          -> outlineValueMap (perceptual luminance)
//   2. sobel    : outlineValueMap   -> outlineEdges    (Sobel edge magnitude)
//   3. blend    : inputTex+outlineEdges -> outputTex   (darken/lighten edges)
//
// NOTE: this effect is multi-pass and ships as a runtime-rendered Texture2D
// (the C# runtime renders valueMap -> sobel -> blend through internal targets).
// No Shader Graph Custom Function wrapper is provided.
//
// PORTING-GUIDE notes / hazards handled:
//  * Ported from WGSL (top-left, canonical). No per-effect Y flip (H8).
//  * valueMap: WGSL samples `textureSample(inputTex, inputSampler, texCoord)`
//    using the interpolated vertex texCoord (== uv). We use the same `i.uv`.
//    (The GLSL recomputes uv = (fragCoord-0.5)/dims; the WGSL passes texCoord
//    straight through. WGSL is canonical, so we use i.uv directly.)
//  * sobel: WGSL uses `textureLoad(valueTexture, ivec2, 0)` (texelFetch — integer
//    coords, NO sampler, NO filtering) -> HLSL `valueTexture.Load(int3(x,y,0))`.
//    The neighborhood coord is `vec2<i32>(input.position.xy)` (the @builtin frag
//    coord truncated to int) -> int2(NM_FragCoord(i)). `offset = max(1, i32(
//    thickness))` — WGSL has NO renderScale multiply (GLSL multiplies thickness*
//    renderScale). WGSL is canonical: `(int)thickness`, no renderScale (H1).
//    `metric = i32(params.sobelMetric)` truncation. Octagram divisor literal is
//    `1.414` exactly. Magnitude boost `* 4.0` reproduced literally.
//  * blend: WGSL samples both inputTex and edgesTexture with the interpolated
//    texCoord (== uv). select(black, white, invert>0.5) -> invert>0.5 ? white :
//    black (WGSL select(falseVal, trueVal, cond) is reversed — H, table row).
//    mix -> lerp.
//  * Linear, clamp-to-edge, non-sRGB samplers (H7) — set on the SamplerStates in
//    Outline.shader. The Sobel `.Load` path ignores sampler state by design.
//  * `_pad*` members in the WGSL Uniforms structs are alignment padding only; we
//    bind only the meaningful named uniforms (sobelMetric, thickness, invert).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input textures + samplers ----------------------------------------------
// Names match definition.js inputs across the three passes:
//   valueMap pass: inputTex            blend pass: inputTex, edgesTexture
//   sobel pass:    valueTexture (Load-only, no sampler in WGSL)
Texture2D    inputTex;
SamplerState sampler_inputTex;
Texture2D    valueTexture;
Texture2D    edgesTexture;
SamplerState sampler_edgesTexture;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
// Bound by the runtime via MaterialPropertyBlock by these exact names.
float sobelMetric;  // globals.shape.uniform,    int choices {1:circle,2:diamond,3:square,4:octagon}, default 1
float thickness;    // globals.thickness.uniform, [1,10] step 0.1, default 1
float invert;       // globals.invert.uniform,    boolean (0/1), default 0

// =============================================================================
// PASS 1: valueMap — verbatim helpers from outlineValueMap.wgsl
// =============================================================================
float nm_outline_srgbToLinear(float value)
{
    if (value <= 0.04045)
    {
        return value / 12.92;
    }
    return pow((value + 0.055) / 1.055, 2.4);
}

float3 nm_outline_srgbToLinear3(float3 value)
{
    return float3(nm_outline_srgbToLinear(value.r), nm_outline_srgbToLinear(value.g), nm_outline_srgbToLinear(value.b));
}

float nm_outline_cubeRoot(float value)
{
    if (value < 0.0)
    {
        return -pow(-value, 1.0 / 3.0);
    }
    return pow(value, 1.0 / 3.0);
}

float nm_outline_oklabLComponent(float3 rgb)
{
    float3 linearRgb = nm_outline_srgbToLinear3(clamp(rgb, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0)));
    float l = 0.4121656120 * linearRgb.r + 0.5362752080 * linearRgb.g + 0.0514575653 * linearRgb.b;
    float m = 0.2118591070 * linearRgb.r + 0.6807189584 * linearRgb.g + 0.1074065790 * linearRgb.b;
    float s = 0.0883097947 * linearRgb.r + 0.2818474174 * linearRgb.g + 0.6302613616 * linearRgb.b;
    float lC = nm_outline_cubeRoot(max(l, 1e-9));
    float mC = nm_outline_cubeRoot(max(m, 1e-9));
    float sC = nm_outline_cubeRoot(max(s, 1e-9));
    return clamp(0.2104542553 * lC + 0.7936177850 * mC - 0.0040720468 * sC, 0.0, 1.0);
}

float nm_outline_valueMapComponent(float4 texel)
{
    float spread = max(abs(texel.r - texel.g), max(abs(texel.r - texel.b), abs(texel.g - texel.b)));
    if (spread < 1e-5)
    {
        return clamp(texel.r, 0.0, 1.0);
    }
    return nm_outline_oklabLComponent(texel.rgb);
}

// ---- Pass: "outlineValueMap" -------------------------------------------------
// WGSL: texel = textureSample(inputTex, inputSampler, texCoord);
//       value = valueMapComponent(texel);
//       return vec4<f32>(value, value, value, texel.a);
float4 NMFrag_outlineValueMap(NMVaryings i) : SV_Target
{
    float4 texel = inputTex.Sample(sampler_inputTex, i.uv);
    float value = nm_outline_valueMapComponent(texel);
    return float4(value, value, value, texel.a);
}

// =============================================================================
// PASS 2: sobel — verbatim helpers from outlineSobel.wgsl
// =============================================================================
int nm_outline_wrapCoord(int value, int size)
{
    if (size <= 0)
    {
        return 0;
    }
    int wrapped = value % size;
    if (wrapped < 0)
    {
        wrapped = wrapped + size;
    }
    return wrapped;
}

float nm_outline_distanceMetric(float gx, float gy, int metric)
{
    float abs_gx = abs(gx);
    float abs_gy = abs(gy);

    if (metric == 2)
    {
        // Manhattan
        return abs_gx + abs_gy;
    }
    else if (metric == 3)
    {
        // Chebyshev
        return max(abs_gx, abs_gy);
    }
    else if (metric == 4)
    {
        // Octagram
        float cross = (abs_gx + abs_gy) / 1.414;
        return max(cross, max(abs_gx, abs_gy));
    }
    else
    {
        // Euclidean (default)
        return sqrt(gx * gx + gy * gy);
    }
}

// ---- Pass: "outlineSobel" ----------------------------------------------------
// WGSL: dimensions = vec2<i32>(textureDimensions(valueTexture));
//       if (dimensions.x == 0 || dimensions.y == 0) { return vec4<f32>(0.0); }
//       coord  = vec2<i32>(input.position.xy);
//       metric = i32(params.sobelMetric);
//       offset = max(1, i32(params.thickness));
//       (3x3 neighborhood via textureLoad(valueTexture, ivec2, 0).r)
float4 NMFrag_outlineSobel(NMVaryings i) : SV_Target
{
    uint dw, dh;
    valueTexture.GetDimensions(dw, dh);
    int2 dimensions = int2((int)dw, (int)dh);
    if (dimensions.x == 0 || dimensions.y == 0)
    {
        return float4(0.0, 0.0, 0.0, 0.0);
    }

    int2 coord = (int2)NM_FragCoord(i);
    int metric = (int)sobelMetric;

    // Sample 3x3 neighborhood with thickness scaling
    int offset = max(1, (int)thickness);
    float samples[9];
    int idx = 0;
    for (int ky = -1; ky <= 1; ky = ky + 1)
    {
        for (int kx = -1; kx <= 1; kx = kx + 1)
        {
            int sampleX = nm_outline_wrapCoord(coord.x + kx * offset, dimensions.x);
            int sampleY = nm_outline_wrapCoord(coord.y + ky * offset, dimensions.y);
            samples[idx] = valueTexture.Load(int3(sampleX, sampleY, 0)).r;
            idx = idx + 1;
        }
    }

    // Sobel X kernel: [-1 0 1; -2 0 2; -1 0 1]
    float gx = -samples[0] + samples[2] - 2.0 * samples[3] + 2.0 * samples[5] - samples[6] + samples[8];

    // Sobel Y kernel: [-1 -2 -1; 0 0 0; 1 2 1]
    float gy = -samples[0] - 2.0 * samples[1] - samples[2] + samples[6] + 2.0 * samples[7] + samples[8];

    float magnitude = nm_outline_distanceMetric(gx, gy, metric);
    // Boost edge visibility - multiply by 4 to make edges more visible
    float normalized = clamp(magnitude * 4.0, 0.0, 1.0);

    return float4(normalized, normalized, normalized, 1.0);
}

// =============================================================================
// PASS 3: blend — verbatim from outlineBlend.wgsl
// =============================================================================
// WGSL: base = textureSample(inputTex, inputSampler, texCoord);
//       edges = textureSample(edgesTexture, edgesSampler, texCoord);
//       strength = clamp(edges.r, 0.0, 1.0);
//       outlineColor = select(vec3<f32>(0.0), vec3<f32>(1.0), params.invert > 0.5);
//       out_rgb = mix(base.rgb, outlineColor, strength);
//       return vec4<f32>(out_rgb, base.a);
float4 NMFrag_outlineBlend(NMVaryings i) : SV_Target
{
    float4 base = inputTex.Sample(sampler_inputTex, i.uv);
    float4 edges = edgesTexture.Sample(sampler_edgesTexture, i.uv);

    // Edge strength from luminance
    float strength = clamp(edges.r, 0.0, 1.0);

    // Outline color: black by default, white if inverted
    float3 outlineColor = invert > 0.5 ? float3(1.0, 1.0, 1.0) : float3(0.0, 0.0, 0.0);

    // Apply outline where edges are present
    float3 out_rgb = lerp(base.rgb, outlineColor, strength);

    return float4(out_rgb, base.a);
}

#endif // NM_EFFECT_OUTLINE_INCLUDED
