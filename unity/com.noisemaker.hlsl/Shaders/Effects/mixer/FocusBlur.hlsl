#ifndef NM_FOCUSBLUR_INCLUDED
#define NM_FOCUSBLUR_INCLUDED

// =============================================================================
// FocusBlur.hlsl — mixer/focusBlur, ported PIXEL-IDENTICALLY from the canonical
// WGSL:  shaders/effects/mixer/focusBlur/wgsl/focusBlur.wgsl
//
// Focus blur (depth of field) mixer shader.
// Reconstructs a faux depth buffer from luminance to drive circle-of-confusion
// Gaussian blurs. One render pass (definition.js passes.length == 1,
// program "focusBlur").
//
// PORTING-GUIDE notes:
//  * getLuminosity / computeBlurFactor / applyFocusBlurAB / applyFocusBlurBA are
//    this effect's OWN helpers — ported VERBATIM inline (golden rule 2).
//  * depthSource: WGSL `depthSource: i32` uniform. definition.js types it `int`
//    with choices sourceA=0 / sourceB=1. Declared as `int depthSource`.
//  * uv: WGSL line 89 — `let dims = vec2f(textureDimensions(inputTex, 0));` then
//    `let uv = position.xy / dims`. The same `uv` (derived from inputTex's own
//    size) drives all samples in both branches. We follow this literally.
//  * nm_mod not fmod — but there is no modulo in this effect, so n/a.
//  * No PRNG, no atan2, no select — no bit hazards.
//  * Linear, clamp-to-edge, non-sRGB samplers (H7).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
int   depthSource;    // globals.depthSource.uniform "depthSource", default 1
float focalDistance;  // globals.focalDistance.uniform "focalDistance", default 50
float aperture;       // globals.aperture.uniform "aperture", default 4
float sampleBias;     // globals.sampleBias.uniform "sampleBias", default 10

// -----------------------------------------------------------------------------
// getLuminosity — ported VERBATIM from focusBlur.wgsl
// WGSL: return dot(color, vec3f(0.2126, 0.7152, 0.0722));
// -----------------------------------------------------------------------------
float getLuminosity(float3 color)
{
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

// -----------------------------------------------------------------------------
// computeBlurFactor — ported VERBATIM from focusBlur.wgsl
// WGSL:
//   let focalPlane = focalDistance * 0.01;
//   let blur = abs(depth - focalPlane) * aperture;
//   return clamp(blur, 0.0, 1.0);
// -----------------------------------------------------------------------------
float computeBlurFactor(float depth)
{
    float focalPlane = focalDistance * 0.01;
    float blur = abs(depth - focalPlane) * aperture;
    return clamp(blur, 0.0, 1.0);
}

// -----------------------------------------------------------------------------
// applyFocusBlurAB — ported VERBATIM from focusBlur.wgsl
// depthSource==0: use inputTex (A) as depth map, blur tex (B)
// WGSL lines 28-55.
// -----------------------------------------------------------------------------
float4 applyFocusBlurAB(float2 uv, float2 resolutionDims,
    Texture2D inputTex_, SamplerState sampler_inputTex_,
    Texture2D tex_, SamplerState sampler_tex_)
{
    float4 depthSample = inputTex_.Sample(sampler_inputTex_, uv);
    float depth = getLuminosity(depthSample.rgb);

    float blurFactor = computeBlurFactor(depth) * 10.0;

    float4 color = float4(0.0, 0.0, 0.0, 0.0);
    float totalWeight = 0.0;

    for (int x = -4; x <= 4; x = x + 1)
    {
        for (int y = -4; y <= 4; y = y + 1)
        {
            float2 offset = float2((float)x, (float)y) * sampleBias / resolutionDims;

            float dist2 = (float)(x * x + y * y);
            float sigma2 = 2.0 * blurFactor * blurFactor;
            float weight = exp(-dist2 / max(sigma2, 0.001));

            color = color + tex_.Sample(sampler_tex_, uv + offset) * weight;
            totalWeight = totalWeight + weight;
        }
    }

    return color / totalWeight;
}

// -----------------------------------------------------------------------------
// applyFocusBlurBA — ported VERBATIM from focusBlur.wgsl
// depthSource==1: use tex (B) as depth map, blur inputTex (A)
// WGSL lines 58-85.
// -----------------------------------------------------------------------------
float4 applyFocusBlurBA(float2 uv, float2 resolutionDims,
    Texture2D inputTex_, SamplerState sampler_inputTex_,
    Texture2D tex_, SamplerState sampler_tex_)
{
    float4 depthSample = tex_.Sample(sampler_tex_, uv);
    float depth = getLuminosity(depthSample.rgb);

    float blurFactor = computeBlurFactor(depth) * 10.0;

    float4 color = float4(0.0, 0.0, 0.0, 0.0);
    float totalWeight = 0.0;

    for (int x = -4; x <= 4; x = x + 1)
    {
        for (int y = -4; y <= 4; y = y + 1)
        {
            float2 offset = float2((float)x, (float)y) * sampleBias / resolutionDims;

            float dist2 = (float)(x * x + y * y);
            float sigma2 = 2.0 * blurFactor * blurFactor;
            float weight = exp(-dist2 / max(sigma2, 0.001));

            color = color + inputTex_.Sample(sampler_inputTex_, uv + offset) * weight;
            totalWeight = totalWeight + weight;
        }
    }

    return color / totalWeight;
}

// -----------------------------------------------------------------------------
// nm_focusBlur — core per-pixel evaluation, ported VERBATIM from focusBlur.wgsl
// main() lines 88-108.
// Takes already-computed uv and dims, plus both sampled inputs for alpha.
// -----------------------------------------------------------------------------
float4 nm_focusBlur(float2 uv, float2 dims,
    Texture2D inputTex_, SamplerState sampler_inputTex_,
    Texture2D tex_, SamplerState sampler_tex_)
{
    float4 color;

    // depthSource: 0 = use inputTex (A) as depth map, blur tex (B)
    //              1 = use tex (B) as depth map, blur inputTex (A)
    if (depthSource == 0)
    {
        color = applyFocusBlurAB(uv, dims,
            inputTex_, sampler_inputTex_,
            tex_, sampler_tex_);
    }
    else
    {
        color = applyFocusBlurBA(uv, dims,
            inputTex_, sampler_inputTex_,
            tex_, sampler_tex_);
    }

    // Preserve maximum alpha from both sources
    float alpha1 = inputTex_.Sample(sampler_inputTex_, uv).a;
    float alpha2 = tex_.Sample(sampler_tex_, uv).a;
    color.a = max(alpha1, alpha2);

    return color;
}

#endif // NM_FOCUSBLUR_INCLUDED
