#ifndef NM_DISTORTION_INCLUDED
#define NM_DISTORTION_INCLUDED

// =============================================================================
// Distortion.hlsl — mixer/distortion, ported PIXEL-IDENTICALLY from the
// canonical WGSL:  shaders/effects/mixer/distortion/wgsl/distortion.wgsl
//
// Displace, reflect, and refract between two surfaces using Sobel normals.
// Single render pass (definition.js passes.length == 1, program "distortion").
//
// PORTING NOTES:
//  * All helpers (getLuminosity / calculateNormal / wrapCoords /
//    applyDisplacement / applyRefraction / applyReflection) are this effect's
//    OWN copies — ported VERBATIM inline (golden rule 2).
//  * uv: WGSL divides position.xy by inputTex's own dimensions:
//        let dims = vec2f(textureDimensions(inputTex, 0));
//        let uv   = position.xy / dims;
//    texelSize = 1.0 / dims.  tileOffset is NOT added (WGSL does not).
//  * wrapCoords: WGSL mode 0 (mirror):
//        st = abs(st % vec2f(2.0) - vec2f(1.0));
//        st = vec2f(1.0) - st;
//    nm_mod(x,y) == x - y*floor(x/y) maps to the WGSL % for positives.
//    For a general signed st we use nm_mod which is the GLSL mod equivalent
//    used across this codebase.
//  * WGSL `antialias: i32` — tested as `antialias != 0` in WGSL; we do the
//    same with an int uniform.
//  * dpdx/dpdy -> ddx/ddy in HLSL.
//  * reflect() is a built-in in both WGSL and HLSL with identical semantics.
//  * normalize() / length() / frac() / clamp() / dot() — direct.
//  * vec3f(normalize(uv - vec2f(0.5)), 100.0) — WGSL constructs a vec3 from a
//    normalized 2-component expression and a scalar z. Replicated literally.
//  * No PRNG / nm_mod needed except inside wrapCoords mirror branch.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
int   mode;       // 0=displace, 1=refract, 2=reflect;  default 1
int   mapSource;  // 0=sourceA(inputTex), 1=sourceB(tex);  default 1
float intensity;  // 0..100, default 50
int   wrap;       // 0=mirror, 1=repeat, 2=clamp;  default 0
float smoothing;  // 1..100, default 1
float aberration; // 0..25, default 0
int   antialias;  // 0=false, 1=true;  default 0

// ---- Constants ---------------------------------------------------------------
static const float NM_DIST_PI  = 3.14159265359;
static const float NM_DIST_TAU = 6.28318530718;

// ---- Helpers ported VERBATIM from distortion.wgsl ----------------------------

float getLuminosity(float3 color)
{
    return dot(color, float3(0.299, 0.587, 0.114));
}

// calculateNormal — Sobel convolution on either inputTex or tex.
// Declared forward; full version references the samplers so it is defined
// AFTER the sampler declarations in the .shader. We instead put it after
// a forward-declaration trick using the two Texture2D resources declared
// in the .shader HLSLPROGRAM block. Because HLSL does not allow forward
// declarations for functions that reference resource variables, the function
// bodies are defined in the .shader after the Texture2D declarations.
// We define a single inline macro-free version here:  the two
// applyDisplacement / applyRefraction / applyReflection functions accept
// explicit Texture2D + SamplerState pairs so we can keep all logic in this
// .hlsl file while the .shader binds the actual resources.

// NOTE: the resources (inputTex / sampler_inputTex / tex / sampler_tex) are
// declared in the .shader HLSLPROGRAM block BEFORE this file is #included, so
// the helpers below reference them directly. They must NOT be re-declared here
// or the compiler reports a redefinition.

float3 calculateNormal(float2 uv, float2 texelSize, bool useInputTex)
{
    float2 sampleSize = texelSize * smoothing;

    // Sobel X kernel (row-major: top-left to bottom-right)
    static const float sobel_x[9] = {
        -1.0, 0.0, 1.0,
        -2.0, 0.0, 2.0,
        -1.0, 0.0, 1.0
    };
    // Sobel Y kernel
    static const float sobel_y[9] = {
        -1.0, -2.0, -1.0,
         0.0,  0.0,  0.0,
         1.0,  2.0,  1.0
    };

    float2 offsets[9];
    offsets[0] = float2(-sampleSize.x, -sampleSize.y);
    offsets[1] = float2(0.0, -sampleSize.y);
    offsets[2] = float2(sampleSize.x, -sampleSize.y);
    offsets[3] = float2(-sampleSize.x, 0.0);
    offsets[4] = float2(0.0, 0.0);
    offsets[5] = float2(sampleSize.x, 0.0);
    offsets[6] = float2(-sampleSize.x, sampleSize.y);
    offsets[7] = float2(0.0, sampleSize.y);
    offsets[8] = float2(sampleSize.x, sampleSize.y);

    float dx = 0.0;
    float dy = 0.0;

    [unroll]
    for (int i = 0; i < 9; i = i + 1)
    {
        float3 texSample;
        if (useInputTex)
            texSample = inputTex.Sample(sampler_inputTex, uv + offsets[i]).rgb;
        else
            texSample = tex.Sample(sampler_tex, uv + offsets[i]).rgb;
        float height = getLuminosity(texSample);
        dx += height * sobel_x[i];
        dy += height * sobel_y[i];
    }

    float normalStrength = intensity * 0.1;
    dx *= normalStrength;
    dy *= normalStrength;

    float3 normal = normalize(float3(-dx, -dy, 1.0));
    return normal;
}

float2 wrapCoords(float2 st_in)
{
    float2 st = st_in;
    if (wrap == 0)
    {
        // mirror: WGSL: st = abs(st % vec2(2.0) - vec2(1.0)); st = 1.0 - st;
        st = abs(nm_mod(st, float2(2.0, 2.0)) - float2(1.0, 1.0));
        st = float2(1.0, 1.0) - st;
    }
    else if (wrap == 1)
    {
        // repeat
        st = frac(st);
    }
    else if (wrap == 2)
    {
        // clamp
        st = clamp(st, float2(0.0, 0.0), float2(1.0, 1.0));
    }
    return st;
}

float4 applyDisplacement(float2 uv, bool useInputTexAsMap)
{
    float4 mapColor;
    if (useInputTexAsMap)
        mapColor = inputTex.Sample(sampler_inputTex, uv);
    else
        mapColor = tex.Sample(sampler_tex, uv);

    float len = length(mapColor.rgb);

    float2 offset;
    offset.x = cos(len * NM_DIST_TAU) * (intensity * 0.001);
    offset.y = sin(len * NM_DIST_TAU) * (intensity * 0.001);

    float2 displacedUV = wrapCoords(uv + offset);

    if (antialias != 0)
    {
        float2 dx = ddx(displacedUV);
        float2 dy = ddy(displacedUV);
        float4 col = float4(0.0, 0.0, 0.0, 0.0);
        if (useInputTexAsMap)
        {
            col += tex.Sample(sampler_tex, displacedUV + dx * -0.375 + dy * -0.125);
            col += tex.Sample(sampler_tex, displacedUV + dx *  0.125 + dy * -0.375);
            col += tex.Sample(sampler_tex, displacedUV + dx *  0.375 + dy *  0.125);
            col += tex.Sample(sampler_tex, displacedUV + dx * -0.125 + dy *  0.375);
        }
        else
        {
            col += inputTex.Sample(sampler_inputTex, displacedUV + dx * -0.375 + dy * -0.125);
            col += inputTex.Sample(sampler_inputTex, displacedUV + dx *  0.125 + dy * -0.375);
            col += inputTex.Sample(sampler_inputTex, displacedUV + dx *  0.375 + dy *  0.125);
            col += inputTex.Sample(sampler_inputTex, displacedUV + dx * -0.125 + dy *  0.375);
        }
        return col * 0.25;
    }
    else if (useInputTexAsMap)
    {
        return tex.Sample(sampler_tex, displacedUV);
    }
    else
    {
        return inputTex.Sample(sampler_inputTex, displacedUV);
    }
}

float4 applyRefraction(float2 uv, float2 texelSize, bool useInputTexAsMap)
{
    float3 normal = calculateNormal(uv, texelSize, useInputTexAsMap);
    float2 refractionOffset = normal.xy * (intensity * 0.0125);
    float2 refractedUV = wrapCoords(uv + refractionOffset);

    if (antialias != 0)
    {
        float2 dx = ddx(refractedUV);
        float2 dy = ddy(refractedUV);
        float4 col = float4(0.0, 0.0, 0.0, 0.0);
        if (useInputTexAsMap)
        {
            col += tex.Sample(sampler_tex, refractedUV + dx * -0.375 + dy * -0.125);
            col += tex.Sample(sampler_tex, refractedUV + dx *  0.125 + dy * -0.375);
            col += tex.Sample(sampler_tex, refractedUV + dx *  0.375 + dy *  0.125);
            col += tex.Sample(sampler_tex, refractedUV + dx * -0.125 + dy *  0.375);
        }
        else
        {
            col += inputTex.Sample(sampler_inputTex, refractedUV + dx * -0.375 + dy * -0.125);
            col += inputTex.Sample(sampler_inputTex, refractedUV + dx *  0.125 + dy * -0.375);
            col += inputTex.Sample(sampler_inputTex, refractedUV + dx *  0.375 + dy *  0.125);
            col += inputTex.Sample(sampler_inputTex, refractedUV + dx * -0.125 + dy *  0.375);
        }
        return col * 0.25;
    }
    else if (useInputTexAsMap)
    {
        return tex.Sample(sampler_tex, refractedUV);
    }
    else
    {
        return inputTex.Sample(sampler_inputTex, refractedUV);
    }
}

float4 applyReflection(float2 uv, float2 texelSize, bool useInputTexAsMap)
{
    float3 normal = calculateNormal(uv, texelSize, useInputTexAsMap);

    // WGSL: let incident = vec3f(normalize(uv - vec2f(0.5)), 100.0);
    float3 incident = float3(normalize(uv - float2(0.5, 0.5)), 100.0);

    float3 reflectionVec = reflect(incident, normal);
    float2 reflectionOffset = reflectionVec.xy * (intensity * 0.00005);

    float2 redOffset   = reflectionOffset * (1.0 + aberration * 0.0075);
    float2 greenOffset = reflectionOffset;
    float2 blueOffset  = reflectionOffset * (1.0 - aberration * 0.0075);

    float2 redUV   = wrapCoords(uv + redOffset);
    float2 greenUV = wrapCoords(uv + greenOffset);
    float2 blueUV  = wrapCoords(uv + blueOffset);
    float2 alphaUV = wrapCoords(uv + reflectionOffset);

    if (antialias != 0)
    {
        float2 dx = ddx(greenUV);
        float2 dy = ddy(greenUV);
        float2 o1 = dx * -0.375 + dy * -0.125;
        float2 o2 = dx *  0.125 + dy * -0.375;
        float2 o3 = dx *  0.375 + dy *  0.125;
        float2 o4 = dx * -0.125 + dy *  0.375;

        float r = 0.0, g = 0.0, b = 0.0, a = 0.0;

        if (useInputTexAsMap)
        {
            r += tex.Sample(sampler_tex, redUV + o1).r;
            r += tex.Sample(sampler_tex, redUV + o2).r;
            r += tex.Sample(sampler_tex, redUV + o3).r;
            r += tex.Sample(sampler_tex, redUV + o4).r;
            g += tex.Sample(sampler_tex, greenUV + o1).g;
            g += tex.Sample(sampler_tex, greenUV + o2).g;
            g += tex.Sample(sampler_tex, greenUV + o3).g;
            g += tex.Sample(sampler_tex, greenUV + o4).g;
            b += tex.Sample(sampler_tex, blueUV + o1).b;
            b += tex.Sample(sampler_tex, blueUV + o2).b;
            b += tex.Sample(sampler_tex, blueUV + o3).b;
            b += tex.Sample(sampler_tex, blueUV + o4).b;
            a += tex.Sample(sampler_tex, alphaUV + o1).a;
            a += tex.Sample(sampler_tex, alphaUV + o2).a;
            a += tex.Sample(sampler_tex, alphaUV + o3).a;
            a += tex.Sample(sampler_tex, alphaUV + o4).a;
        }
        else
        {
            r += inputTex.Sample(sampler_inputTex, redUV + o1).r;
            r += inputTex.Sample(sampler_inputTex, redUV + o2).r;
            r += inputTex.Sample(sampler_inputTex, redUV + o3).r;
            r += inputTex.Sample(sampler_inputTex, redUV + o4).r;
            g += inputTex.Sample(sampler_inputTex, greenUV + o1).g;
            g += inputTex.Sample(sampler_inputTex, greenUV + o2).g;
            g += inputTex.Sample(sampler_inputTex, greenUV + o3).g;
            g += inputTex.Sample(sampler_inputTex, greenUV + o4).g;
            b += inputTex.Sample(sampler_inputTex, blueUV + o1).b;
            b += inputTex.Sample(sampler_inputTex, blueUV + o2).b;
            b += inputTex.Sample(sampler_inputTex, blueUV + o3).b;
            b += inputTex.Sample(sampler_inputTex, blueUV + o4).b;
            a += inputTex.Sample(sampler_inputTex, alphaUV + o1).a;
            a += inputTex.Sample(sampler_inputTex, alphaUV + o2).a;
            a += inputTex.Sample(sampler_inputTex, alphaUV + o3).a;
            a += inputTex.Sample(sampler_inputTex, alphaUV + o4).a;
        }

        return float4(r, g, b, a) * 0.25;
    }

    float redChannel, greenChannel, blueChannel, alphaChannel;

    if (useInputTexAsMap)
    {
        redChannel   = tex.Sample(sampler_tex, redUV).r;
        greenChannel = tex.Sample(sampler_tex, greenUV).g;
        blueChannel  = tex.Sample(sampler_tex, blueUV).b;
        alphaChannel = tex.Sample(sampler_tex, alphaUV).a;
    }
    else
    {
        redChannel   = inputTex.Sample(sampler_inputTex, redUV).r;
        greenChannel = inputTex.Sample(sampler_inputTex, greenUV).g;
        blueChannel  = inputTex.Sample(sampler_inputTex, blueUV).b;
        alphaChannel = inputTex.Sample(sampler_inputTex, alphaUV).a;
    }

    return float4(redChannel, greenChannel, blueChannel, alphaChannel);
}

// ---- nm_distortion: entry point called by the render-pass frag --------------
float4 nm_distortion(float2 uv, float2 texelSize)
{
    // mapSource: 0 = inputTex (A), 1 = tex (B)
    bool useInputTexAsMap = (mapSource == 0);

    float4 color;
    if (mode == 0)
        color = applyDisplacement(uv, useInputTexAsMap);
    else if (mode == 1)
        color = applyRefraction(uv, texelSize, useInputTexAsMap);
    else
        color = applyReflection(uv, texelSize, useInputTexAsMap);

    return color;
}

#endif // NM_DISTORTION_INCLUDED
