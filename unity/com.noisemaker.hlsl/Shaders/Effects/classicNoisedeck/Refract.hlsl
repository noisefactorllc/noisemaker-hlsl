#ifndef NM_EFFECT_REFRACT_INCLUDED
#define NM_EFFECT_REFRACT_INCLUDED

// =============================================================================
// Refract.hlsl — classicNoisedeck/refract (func: "refract")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/classicNoisedeck/refract/wgsl/refract.wgsl
//
// Noise-based UV perturbation (brightness-driven cosine/sine warp, or
// image-derivative warp) with 18 blend modes and mirror/repeat/clamp wrap.
// Single render pass — kind: filter.
//
// PORTING-GUIDE notes / hazards handled:
//  * UV = fragCoord / inputTex dimensions (WGSL: position.xy / textureDimensions).
//    NOT divided by fullResolution. NM_FragCoord(i) / float2(texW, texH).
//  * wrap == 0 (mirror): WGSL does nothing — relies on the sampler's mirror wrap.
//    SamplerState sampler_inputTex is declared as the default (mirror) address mode
//    by the runtime. wrap == 1 uses frac(); wrap == 2 clamps.
//  * blend_colors in the WGSL reads mixAmt and blendMode as module-scope globals.
//    In HLSL we use the per-effect uniform declarations.
//  * mix -> lerp; fract -> frac; clamp/abs/min/max/cos/sin map 1:1.
//  * No PCG/PRNG — no float-bit hazards.
//  * Full 32-bit float only (parity requirement).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (WGSL: @binding(0) samp, @binding(1) inputTex) --
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (definition.js globals[*].uniform) ------------
int   mode;       // 0=refract 1=reflect (derivative warp)   default 0
float amount;     // warp strength                            default 50  [0,100]
float direction;  // directional offset (degrees)             default 0   [0,360]
int   blendMode;  // blend mode enum                          default 10  (mix)
float mixAmt;     // blend mix amount                         default 50  [0,100]
int   wrap;       // 0=mirror 1=repeat 2=clamp                default 0

// ---- Constants ---------------------------------------------------------------

// -----------------------------------------------------------------------------
// map_range — verbatim from WGSL map_range.
// -----------------------------------------------------------------------------
float nm_refract_map_range(float value, float inMin, float inMax,
                           float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

// -----------------------------------------------------------------------------
// desaturate — verbatim from WGSL desaturate.
// -----------------------------------------------------------------------------
float nm_refract_desaturate(float3 color)
{
    return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
}

// -----------------------------------------------------------------------------
// convolve_kernel — verbatim from WGSL convolve_kernel.
// Reads inputTex; uses the 9-tap offset grid scaled by floor(map(amount,0,100,0,20)).
// -----------------------------------------------------------------------------
float3 nm_refract_convolve_kernel(float2 uv, float kernel[9], bool divide)
{
    uint texW, texH;
    inputTex.GetDimensions(texW, texH);
    float2 dims  = float2((float)texW, (float)texH);
    float2 steps = 1.0 / dims;

    float2 offsets[9];
    offsets[0] = float2(-steps.x, -steps.y);
    offsets[1] = float2( 0.0,     -steps.y);
    offsets[2] = float2( steps.x, -steps.y);
    offsets[3] = float2(-steps.x,  0.0    );
    offsets[4] = float2( 0.0,      0.0    );
    offsets[5] = float2( steps.x,  0.0    );
    offsets[6] = float2(-steps.x,  steps.y);
    offsets[7] = float2( 0.0,      steps.y);
    offsets[8] = float2( steps.x,  steps.y);

    float  kernelWeight = 0.0;
    float3 conv         = float3(0.0, 0.0, 0.0);
    float  scale        = floor(nm_refract_map_range(amount, 0.0, 100.0, 0.0, 20.0));

    [unroll]
    for (int i = 0; i < 9; i = i + 1)
    {
        float3 color = inputTex.Sample(sampler_inputTex, uv + offsets[i] * scale).rgb;
        conv         = conv + color * kernel[i];
        kernelWeight = kernelWeight + kernel[i];
    }

    if (divide && kernelWeight != 0.0)
    {
        conv = conv / kernelWeight;
    }

    return clamp(conv, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

// -----------------------------------------------------------------------------
// derivX — verbatim from WGSL derivX.
// -----------------------------------------------------------------------------
float3 nm_refract_derivX(float2 uv, bool divide)
{
    float kernel[9];
    kernel[0] = 0.0; kernel[1] = 0.0; kernel[2] = 0.0;
    kernel[3] = 0.0; kernel[4] = 1.0; kernel[5] = -1.0;
    kernel[6] = 0.0; kernel[7] = 0.0; kernel[8] = 0.0;
    return nm_refract_convolve_kernel(uv, kernel, divide);
}

// -----------------------------------------------------------------------------
// derivY — verbatim from WGSL derivY.
// -----------------------------------------------------------------------------
float3 nm_refract_derivY(float2 uv, bool divide)
{
    float kernel[9];
    kernel[0] = 0.0; kernel[1] = 0.0; kernel[2] = 0.0;
    kernel[3] = 0.0; kernel[4] = 1.0; kernel[5] = 0.0;
    kernel[6] = 0.0; kernel[7] = -1.0; kernel[8] = 0.0;
    return nm_refract_convolve_kernel(uv, kernel, divide);
}

// -----------------------------------------------------------------------------
// blendOverlay — verbatim from WGSL blendOverlay.
// -----------------------------------------------------------------------------
float nm_refract_blendOverlay(float a, float b)
{
    if (a < 0.5)
    {
        return 2.0 * a * b;
    }
    return 1.0 - 2.0 * (1.0 - a) * (1.0 - b);
}

// -----------------------------------------------------------------------------
// blendSoftLight — verbatim from WGSL blendSoftLight.
// -----------------------------------------------------------------------------
float nm_refract_blendSoftLight(float base, float blend)
{
    if (blend < 0.5)
    {
        return 2.0 * base * blend + base * base * (1.0 - 2.0 * blend);
    }
    return sqrt(base) * (2.0 * blend - 1.0) + 2.0 * base * (1.0 - blend);
}

// -----------------------------------------------------------------------------
// vec4_eq — all(a == b) equivalent.
// -----------------------------------------------------------------------------
bool nm_refract_vec4_eq(float4 a, float4 b)
{
    return all(a == b);
}

// -----------------------------------------------------------------------------
// blend_colors — verbatim from WGSL blend_colors.
// Reads module-scope uniforms mixAmt and blendMode.
// -----------------------------------------------------------------------------
float3 nm_refract_blend_colors(float4 color1, float4 color2)
{
    float4 color;
    float4 middle;
    float  amt = nm_refract_map_range(mixAmt, 0.0, 100.0, 0.0, 1.0);

    [branch]
    if (blendMode == 0)
    {
        // add
        middle = min(color1 + color2, float4(1.0, 1.0, 1.0, 1.0));
    }
    else if (blendMode == 2)
    {
        // color burn
        if (nm_refract_vec4_eq(color2, float4(0.0, 0.0, 0.0, 0.0)))
            middle = color2;
        else
            middle = max((1.0 - ((1.0 - color1) / color2)), float4(0.0, 0.0, 0.0, 0.0));
    }
    else if (blendMode == 3)
    {
        // color dodge
        if (nm_refract_vec4_eq(color2, float4(1.0, 1.0, 1.0, 1.0)))
            middle = color2;
        else
            middle = min(color1 / (1.0 - color2), float4(1.0, 1.0, 1.0, 1.0));
    }
    else if (blendMode == 4)
    {
        // darken
        middle = min(color1, color2);
    }
    else if (blendMode == 5)
    {
        // difference
        middle = abs(color1 - color2);
    }
    else if (blendMode == 6)
    {
        // exclusion
        middle = color1 + color2 - 2.0 * color1 * color2;
    }
    else if (blendMode == 7)
    {
        // glow
        if (nm_refract_vec4_eq(color2, float4(1.0, 1.0, 1.0, 1.0)))
            middle = color2;
        else
            middle = min(color1 * color1 / (1.0 - color2), float4(1.0, 1.0, 1.0, 1.0));
    }
    else if (blendMode == 8)
    {
        // hard light
        middle = float4(
            nm_refract_blendOverlay(color2.r, color1.r),
            nm_refract_blendOverlay(color2.g, color1.g),
            nm_refract_blendOverlay(color2.b, color1.b),
            lerp(color1.a, color2.a, 0.5)
        );
    }
    else if (blendMode == 9)
    {
        // lighten
        middle = max(color1, color2);
    }
    else if (blendMode == 10)
    {
        // mix (default)
        middle = lerp(color1, color2, 0.5);
    }
    else if (blendMode == 11)
    {
        // multiply
        middle = color1 * color2;
    }
    else if (blendMode == 12)
    {
        // negation
        middle = float4(1.0, 1.0, 1.0, 1.0) - abs(float4(1.0, 1.0, 1.0, 1.0) - color1 - color2);
    }
    else if (blendMode == 13)
    {
        // overlay
        middle = float4(
            nm_refract_blendOverlay(color1.r, color2.r),
            nm_refract_blendOverlay(color1.g, color2.g),
            nm_refract_blendOverlay(color1.b, color2.b),
            lerp(color1.a, color2.a, 0.5)
        );
    }
    else if (blendMode == 14)
    {
        // phoenix
        middle = min(color1, color2) - max(color1, color2) + float4(1.0, 1.0, 1.0, 1.0);
    }
    else if (blendMode == 15)
    {
        // reflect
        if (nm_refract_vec4_eq(color1, float4(1.0, 1.0, 1.0, 1.0)))
            middle = color1;
        else
            middle = min(color2 * color2 / (1.0 - color1), float4(1.0, 1.0, 1.0, 1.0));
    }
    else if (blendMode == 16)
    {
        // screen
        middle = 1.0 - ((1.0 - color1) * (1.0 - color2));
    }
    else if (blendMode == 17)
    {
        // soft light
        middle = float4(
            nm_refract_blendSoftLight(color1.r, color2.r),
            nm_refract_blendSoftLight(color1.g, color2.g),
            nm_refract_blendSoftLight(color1.b, color2.b),
            lerp(color1.a, color2.a, 0.5)
        );
    }
    else
    {
        // subtract (blendMode == 18)
        middle = max(color1 + color2 - 1.0, float4(0.0, 0.0, 0.0, 0.0));
    }

    if (amt == 0.5)
    {
        color = middle;
    }
    else if (amt < 0.5)
    {
        amt   = nm_refract_map_range(amt, 0.0, 0.5, 0.0, 1.0);
        color = lerp(color1, middle, amt);
    }
    else
    {
        amt   = nm_refract_map_range(amt, 0.5, 1.0, 0.0, 1.0);
        color = lerp(middle, color2, amt);
    }

    return color.rgb;
}

// =============================================================================
// NMFrag_refract — single render pass. Verbatim from WGSL main().
//
// WGSL:
//   dims       = textureDimensions(inputTex)
//   uv         = position.xy / dims
//   inputColor = textureSample(inputTex, samp, uv)
//   brightness = desaturate(inputColor.rgb) + direction / 360.0
//   if mode==0: uv.x += cos(brightness*TAU)*amount*0.01
//               uv.y += sin(brightness*TAU)*amount*0.01
//   if mode==1: uv.y += desaturate(derivX(uv,false))*amount*0.01
//               uv.x += desaturate(derivY(uv,false))*amount*0.01
//   if wrap==1: uv = fract(uv)
//   if wrap==2: uv = clamp(uv, 0, 1)
//   color = textureSample(inputTex, samp, uv)
//   color = vec4(blend_colors(inputColor, color), color.a)
// =============================================================================
float4 NMFrag_refract(NMVaryings i) : SV_Target
{
    uint texW, texH;
    inputTex.GetDimensions(texW, texH);
    float2 dims = float2((float)texW, (float)texH);

    float2 uv = NM_FragCoord(i) / dims;

    float4 inputColor = inputTex.Sample(sampler_inputTex, uv);
    float  brightness = nm_refract_desaturate(inputColor.rgb) + direction / 360.0;

    [branch]
    if (mode == 0)
    {
        uv.x = uv.x + cos(brightness * NM_TAU) * amount * 0.01;
        uv.y = uv.y + sin(brightness * NM_TAU) * amount * 0.01;
    }
    else if (mode == 1)
    {
        uv.y = uv.y + nm_refract_desaturate(nm_refract_derivX(uv, false)) * amount * 0.01;
        uv.x = uv.x + nm_refract_desaturate(nm_refract_derivY(uv, false)) * amount * 0.01;
    }

    [branch]
    if (wrap == 0)
    {
        // mirror — rely on sampler address mode; no UV change (WGSL: no-op)
    }
    else if (wrap == 1)
    {
        // repeat
        uv = frac(uv);
    }
    else if (wrap == 2)
    {
        // clamp
        uv = clamp(uv, float2(0.0, 0.0), float2(1.0, 1.0));
    }

    float4 color = inputTex.Sample(sampler_inputTex, uv);
    color = float4(nm_refract_blend_colors(inputColor, color), color.a);

    return color;
}

#endif // NM_EFFECT_REFRACT_INCLUDED
