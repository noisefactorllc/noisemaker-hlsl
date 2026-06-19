#ifndef NM_EFFECT_LIGHTING_INCLUDED
#define NM_EFFECT_LIGHTING_INCLUDED

// =============================================================================
// Lighting.hlsl — filter/lighting (func: "lighting")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/filter/lighting/wgsl/lighting.wgsl
//
// 3D lighting for 2D textures: computes surface normals via Sobel convolution
// on luminosity, then applies Lambertian diffuse, Blinn-Phong specular, ambient
// lighting, plus optional refraction and reflection (with chromatic aberration).
// Single render pass.
//
// PORTING-GUIDE notes / hazards handled:
//  * uv = pos.xy / textureDimensions(inputTex) — divide by INPUT texture dims,
//    NOT fullResolution. Mirrors WGSL exactly.
//  * texelSize = 1.0 / texSize (WGSL: let texelSize = 1.0 / texSize).
//  * sampleSize = texelSize * uniforms.smoothing
//  * Normal construction: normalize(vec3(-dx, -dy, 1.0)) — note the negations.
//  * WGSL incident for reflection: vec3f(normalize(uv - 0.5), 100.0) — not
//    a unit vector; the 100.0 z-component is intentional; copy literally.
//  * Reflection condition: (uniforms.reflection > 0.0 || uniforms.aberration > 0.0)
//  * Refraction condition: (uniforms.refraction > 0.0)
//  * getLuminosity uses vec3(0.299, 0.587, 0.114) — copy literally.
//  * No PCG/PRNG, no nm_mod, no float-bit hazards.
//  * mix -> lerp; normalize/reflect/pow/max/dot map 1:1.
//  * No per-effect Y flip needed (ported from WGSL, top-left origin).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (reference binding: inputSampler@0, inputTex@1) -
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
float3 diffuseColor;        // default [1,1,1]
float3 specularColor;       // default [1,1,1]
float  specularIntensity;   // default 0.5
float3 ambientColor;        // default [0.2,0.2,0.2]
float  shininess;           // default 64.0
float3 lightDirection;      // default [0.5,0.5,1.0]
float  normalStrength;      // default 1.5
float  smoothing;           // default 1.0
float  reflection;          // default 0.0
float  refraction;          // default 0.0
float  aberration;          // default 0.0

// -----------------------------------------------------------------------------
// getLuminosity — verbatim from WGSL
//   return dot(color, vec3f(0.299, 0.587, 0.114));
// -----------------------------------------------------------------------------
float nm_lighting_getLuminosity(float3 color)
{
    return dot(color, float3(0.299, 0.587, 0.114));
}

// -----------------------------------------------------------------------------
// calculateNormal — verbatim from WGSL
// Samples 3×3 neighbourhood using Sobel kernels, weighted by normalStrength.
// -----------------------------------------------------------------------------
float3 nm_lighting_calculateNormal(float2 uv, float2 texelSize)
{
    float2 sampleSize = texelSize * smoothing;

    // Sobel X kernel (row-major: TL,TC,TR, ML,MC,MR, BL,BC,BR)
    float sobel_x[9] = { -1.0, 0.0, 1.0,
                         -2.0, 0.0, 2.0,
                         -1.0, 0.0, 1.0 };

    // Sobel Y kernel
    float sobel_y[9] = { -1.0, -2.0, -1.0,
                          0.0,  0.0,  0.0,
                          1.0,  2.0,  1.0 };

    float2 offsets[9] = {
        float2(-sampleSize.x, -sampleSize.y),
        float2( 0.0,          -sampleSize.y),
        float2( sampleSize.x, -sampleSize.y),
        float2(-sampleSize.x,  0.0         ),
        float2( 0.0,           0.0         ),
        float2( sampleSize.x,  0.0         ),
        float2(-sampleSize.x,  sampleSize.y),
        float2( 0.0,           sampleSize.y),
        float2( sampleSize.x,  sampleSize.y)
    };

    float dx = 0.0;
    float dy = 0.0;

    for (int i = 0; i < 9; i = i + 1)
    {
        float4 s = inputTex.Sample(sampler_inputTex, uv + offsets[i]);
        float  h = nm_lighting_getLuminosity(s.rgb);
        dx += h * sobel_x[i];
        dy += h * sobel_y[i];
    }

    dx *= normalStrength;
    dy *= normalStrength;

    float3 normal = normalize(float3(-dx, -dy, 1.0));
    return normal;
}

// -----------------------------------------------------------------------------
// applyRefraction — verbatim from WGSL
//   refractionOffset = normal.xy * (uniforms.refraction * 0.0125)
//   return textureSample(inputTex, inputSampler, uv + refractionOffset)
// -----------------------------------------------------------------------------
float4 nm_lighting_applyRefraction(float2 uv, float3 normal)
{
    float2 refractionOffset = normal.xy * (refraction * 0.0125);
    return inputTex.Sample(sampler_inputTex, uv + refractionOffset);
}

// -----------------------------------------------------------------------------
// applyReflection — verbatim from WGSL
//   incident       = vec3f(normalize(uv - 0.5), 100.0)
//   reflectionVec  = reflect(incident, normal)
//   reflectionOffset = reflectionVec.xy * (uniforms.reflection * 0.00005)
//   redOffset   = reflectionOffset * (1.0 + uniforms.aberration * 0.0075)
//   greenOffset = reflectionOffset
//   blueOffset  = reflectionOffset * (1.0 - uniforms.aberration * 0.0075)
//   separate channel samples + alpha from reflectionOffset
// -----------------------------------------------------------------------------
float4 nm_lighting_applyReflection(float2 uv, float3 normal)
{
    float3 incident = float3(normalize(uv - float2(0.5, 0.5)), 100.0);
    float3 reflectionVec = reflect(incident, normal);

    float2 reflectionOffset = reflectionVec.xy * (reflection * 0.00005);

    float2 redOffset   = reflectionOffset * (1.0 + aberration * 0.0075);
    float2 greenOffset = reflectionOffset;
    float2 blueOffset  = reflectionOffset * (1.0 - aberration * 0.0075);

    float redChannel   = inputTex.Sample(sampler_inputTex, uv + redOffset  ).r;
    float greenChannel = inputTex.Sample(sampler_inputTex, uv + greenOffset ).g;
    float blueChannel  = inputTex.Sample(sampler_inputTex, uv + blueOffset  ).b;
    float alphaChannel = inputTex.Sample(sampler_inputTex, uv + reflectionOffset).a;

    return float4(redChannel, greenChannel, blueChannel, alphaChannel);
}

// =============================================================================
// NMFrag_lighting — main fragment for pass "lighting" (single pass).
// Mirrors the WGSL @fragment main() body verbatim.
// =============================================================================
float4 NMFrag_lighting(NMVaryings i) : SV_Target
{
    // WGSL: texSize    = vec2<f32>(textureDimensions(inputTex))
    //       uv         = pos.xy / texSize
    //       texelSize  = 1.0 / texSize
    uint w, h;
    inputTex.GetDimensions(w, h);
    float2 texSize   = float2((float)w, (float)h);
    float2 uv        = NM_FragCoord(i) / texSize;
    float2 texelSize = 1.0 / texSize;

    float4 origColor = inputTex.Sample(sampler_inputTex, uv);
    float3 normal    = nm_lighting_calculateNormal(uv, texelSize);
    float3 lightDir  = normalize(lightDirection);
    float3 viewDir   = float3(0.0, 0.0, 1.0);

    // Ambient
    float3 ambient = ambientColor * origColor.rgb;

    // Diffuse (Lambertian)
    float diffuseFactor = max(dot(normal, lightDir), 0.0);
    float3 diffuse = diffuseColor * diffuseFactor * origColor.rgb;

    // Specular (Blinn-Phong)
    float3 halfDir      = normalize(lightDir + viewDir);
    float  specAngle    = max(dot(halfDir, normal), 0.0);
    float  specularFactor = pow(specAngle, shininess);
    float3 specular     = specularColor * specularFactor * specularIntensity;

    float3 litColor    = ambient + diffuse + specular;
    float4 workingColor = float4(litColor, origColor.a);

    // Refraction
    [branch]
    if (refraction > 0.0)
    {
        float4 refractedColor = nm_lighting_applyRefraction(uv, normal);
        workingColor = lerp(workingColor, refractedColor, refraction / 100.0);
    }

    // Reflection (with chromatic aberration)
    [branch]
    if (reflection > 0.0 || aberration > 0.0)
    {
        float4 reflectedColor = nm_lighting_applyReflection(uv, normal);
        workingColor = lerp(workingColor, reflectedColor, reflection / 100.0);
    }

    return workingColor;
}

#endif // NM_EFFECT_LIGHTING_INCLUDED
