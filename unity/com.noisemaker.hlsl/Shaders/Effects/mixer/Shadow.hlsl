#ifndef NM_SHADOW_INCLUDED
#define NM_SHADOW_INCLUDED

// =============================================================================
// Shadow.hlsl — mixer/shadow, ported PIXEL-IDENTICALLY from the canonical
// WGSL:  shaders/effects/mixer/shadow/wgsl/shadow.wgsl
//
// Uses one input as a mask to cast a shadow or glow onto the other input.
// Extracts a single channel from the mask, applies threshold, then offsets,
// blurs, and spreads the result to create the shadow shape. Single render pass.
//
// PORTING-GUIDE notes:
//  * getChannel is this effect's OWN helper — ported VERBATIM inline (golden rule 2).
//  * maskSource/sourceChannel: int uniforms; runtime [branch] selection (no #define).
//  * WGSL line 33: uv = position.xy / dims  (dims from inputTex). Follow WGSL.
//  * WGSL maskUV = uv - vec2(offsetX, offsetY) * 0.1  (factor 0.1 is literal).
//  * Blur kernel: sigma = max(blur, 0.001); sigma2 = 2 * sigma * sigma;
//    loop x in [-5,5], y in [-5,5]; offset = vec2(x,y) * blur / dims.
//  * Wrap modes: hide(0), mirror(1), repeat(2), clamp(3). WGSL mirror uses
//    abs(((sampleUV + 1.0) % 2.0 + 2.0) % 2.0 - 1.0); translated with nm_mod.
//  * textureSampleLevel -> SampleLevel(ss, uv, 0) — required because sampling
//    occurs inside a loop (non-uniform control flow; implicit derivatives illegal).
//  * baseColor / fgSample sampling pattern follows WGSL exactly:
//    maskSource==0 => base=tex, mask/fg=inputTex
//    maskSource==1 => base=inputTex, mask/fg=tex
//  * fgSample uv uses the top-level `uv` (from inputTex dims), not maskUV.
//  * select(b,a,c) in WGSL = c ? a : b  — no select() here; plain ternary.
//  * nm_mod not fmod. No atan2/PRNG/asuint in this effect.
//  * Full 32-bit float; no half/min16float.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
int   maskSource;     // 0=sourceA, 1=sourceB, default 0
int   sourceChannel;  // 0=red,1=green,2=blue,3=alpha, default 0
float threshold;      // default 0.5
float3 color;         // shadow color, default (0,0,0)
float blur;           // default 1.0, range [0,3]
float spread;         // default 0.0, range [0,1]
float offsetX;        // default 0.1,  range [-1,1]
float offsetY;        // default -0.1, range [-1,1]
int   wrap;           // 0=hide,1=mirror,2=repeat,3=clamp, default 1

// -----------------------------------------------------------------------------
// getChannel — ported VERBATIM from shadow.wgsl. Per-effect copy.
// Extract a single channel from a color.
// -----------------------------------------------------------------------------
float getChannel(float4 c, int channel)
{
    if (channel == 0) { return c.r; }
    if (channel == 1) { return c.g; }
    if (channel == 2) { return c.b; }
    return c.a;
}

// -----------------------------------------------------------------------------
// nm_shadow — core fragment evaluation. Ported VERBATIM from shadow.wgsl main().
// Takes the two input textures and their shared sampler; returns RGBA output.
// Declared as a function so the frag body stays readable and the SG wrapper can
// share the same math.
// -----------------------------------------------------------------------------
float4 nm_shadow(
    Texture2D    inputTex,
    SamplerState sampler_inputTex,
    Texture2D    tex_,
    SamplerState sampler_tex,
    float2       fragCoord)   // NM_FragCoord(i): top-left, +0.5 centered
{
    uint dw, dh;
    inputTex.GetDimensions(dw, dh);
    float2 dims = float2(dw, dh);
    float2 uv = fragCoord / dims;

    // Base image is the non-mask source. Use SampleLevel throughout (non-uniform
    // control flow inside the blur loop disqualifies implicit-derivative Sample).
    float4 baseColor;
    if (maskSource == 0) {
        baseColor = tex_.SampleLevel(sampler_tex, uv, 0.0);
    } else {
        baseColor = inputTex.SampleLevel(sampler_inputTex, uv, 0.0);
    }

    // Mask UV shifted by shadow offset
    float2 maskUV = uv - float2(offsetX, offsetY) * 0.1;

    // Gaussian blur of thresholded mask
    float shadowMask  = 0.0;
    float totalWeight = 0.0;

    float sigma  = max(blur, 0.001);
    float sigma2 = 2.0 * sigma * sigma;

    for (int x = -5; x <= 5; x = x + 1)
    {
        for (int y = -5; y <= 5; y = y + 1)
        {
            float2 sampleOffset = float2((float)x, (float)y) * blur / dims;
            float2 sampleUV     = maskUV + sampleOffset;

            // Apply wrap mode to sample UVs
            float thresholded = 0.0;
            if (wrap == 0)
            {
                // hide: treat out-of-bounds as empty
                if (sampleUV.x >= 0.0 && sampleUV.x <= 1.0 &&
                    sampleUV.y >= 0.0 && sampleUV.y <= 1.0)
                {
                    float4 maskSample;
                    if (maskSource == 0) {
                        maskSample = inputTex.SampleLevel(sampler_inputTex, sampleUV, 0.0);
                    } else {
                        maskSample = tex_.SampleLevel(sampler_tex, sampleUV, 0.0);
                    }
                    thresholded = step(threshold, getChannel(maskSample, sourceChannel));
                }
            }
            else
            {
                float2 wrappedUV = sampleUV;
                if (wrap == 1)
                {
                    // mirror: abs(((sampleUV + 1.0) % 2.0 + 2.0) % 2.0 - 1.0)
                    // nm_mod for float modulo (never fmod)
                    wrappedUV = abs(nm_mod(nm_mod(sampleUV + 1.0, 2.0) + 2.0, 2.0) - 1.0);
                }
                else if (wrap == 2)
                {
                    // repeat
                    wrappedUV = nm_mod(nm_mod(sampleUV, 1.0) + 1.0, 1.0);
                }
                else
                {
                    // clamp
                    wrappedUV = clamp(sampleUV, float2(0.0, 0.0), float2(1.0, 1.0));
                }
                float4 maskSample;
                if (maskSource == 0) {
                    maskSample = inputTex.SampleLevel(sampler_inputTex, wrappedUV, 0.0);
                } else {
                    maskSample = tex_.SampleLevel(sampler_tex, wrappedUV, 0.0);
                }
                thresholded = step(threshold, getChannel(maskSample, sourceChannel));
            }

            float dist2  = (float)(x * x + y * y);
            float weight = exp(-dist2 / sigma2);

            shadowMask  = shadowMask  + thresholded * weight;
            totalWeight = totalWeight + weight;
        }
    }
    shadowMask = shadowMask / totalWeight;

    // Spread amplifies the mask to expand the shadow
    shadowMask = clamp(shadowMask * (1.0 + spread), 0.0, 1.0);

    // Composite shadow onto base
    float3 withShadow = lerp(baseColor.rgb, color, shadowMask);

    // Composite mask source (foreground) on top of the shadow
    float4 fgSample;
    if (maskSource == 0) {
        fgSample = inputTex.SampleLevel(sampler_inputTex, uv, 0.0);
    } else {
        fgSample = tex_.SampleLevel(sampler_tex, uv, 0.0);
    }
    float  fgMask  = step(threshold, getChannel(fgSample, sourceChannel));
    float3 result  = lerp(withShadow, fgSample.rgb, fgMask);

    return float4(result, baseColor.a);
}

#endif // NM_SHADOW_INCLUDED
