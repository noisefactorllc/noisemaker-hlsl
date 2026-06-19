#ifndef NM_EFFECT_POLAR_INCLUDED
#define NM_EFFECT_POLAR_INCLUDED

// =============================================================================
// Polar.hlsl — filter/polar, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/polar/wgsl/polar.wgsl
//
// Polar and vortex coordinate transforms.
// Single render pass (progName "polar").
//
// PORTING-GUIDE notes / hazards handled:
//  * UV computed as: pos.xy / textureDimensions(inputTex) — i.e. fragCoord
//    divided by the INPUT TEXTURE's own dimensions (NOT fullResolution).
//    WGSL is canonical; the GLSL uses fullResolution with tileOffset but WGSL
//    does not. We follow the WGSL.
//  * aspect = texSize.x / texSize.y (from input texture dims, not fullResolution).
//  * atan2 arg order from WGSL: atan2(uv.y, uv.x) — copied literally (H3).
//  * WGSL select(b,a,cond) = cond ? a : b — aspectLens/antialias tested as != 0.
//  * smod1 helper is this effect's own; copied verbatim (NOT NMCore).
//  * time, rotation, speed, scale, polarMode, aspectLens, antialias are uniforms.
//  * WGSL rotation/speed are f32; GLSL uses float too; definition.js declares
//    rotation and speed as type:"int" — declare as int, cast to float for math
//    exactly as the WGSL struct (which has them as f32) receives them from the
//    runtime. Cast at use site with (float) to preserve parity.
//  * nm_mod (not fmod) required by porting guide — smod1 uses fract, no mod needed.
//  * dpdx/dpdy map to ddx/ddy in HLSL.
//  * TAU constant: 6.28318530718 (verbatim from WGSL).
//  * No PCG / no PRNG / no float-bit hazards.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (reference binding: sampler@0, inputTex@1) ------
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
int   polarMode;   // globals.mode.uniform     — 0=polar, 1=vortex
float scale;       // globals.scale.uniform    — [-2,2], default 0
int   rotation;    // globals.rotation.uniform — [-2,2], default 0
int   speed;       // globals.speed.uniform    — [-2,2], default 0
int   aspectLens;  // globals.aspectLens.uniform — bool as int, default 1
int   antialias;   // globals.antialias.uniform  — bool as int, default 1

// ---- TAU constant (verbatim from WGSL) ---------------------------------------
static const float NM_POLAR_TAU = 6.28318530718;

// ---- smod1 — verbatim from WGSL `smod1(v, m)` --------------------------------
// WGSL: return m * (0.75 - abs(fract(v) - 0.5) - 0.25);
float nm_polar_smod1(float v, float m)
{
    return m * (0.75 - abs(frac(v) - 0.5) - 0.25);
}

// ---- polarCoords — verbatim from WGSL ----------------------------------------
// WGSL:
//   var uv = uvIn - 0.5;
//   if (doAspect) { uv.x = uv.x * aspect; }
//   var coord = vec2<f32>(atan2(uv.y, uv.x) / TAU + 0.5, length(uv) - uniforms.scale * 0.075);
//   coord.x = smod1(coord.x + uniforms.time * -uniforms.rotation, 1.0);
//   coord.y = smod1(coord.y + uniforms.time *  uniforms.speed,    1.0);
//   return coord;
float2 nm_polar_polarCoords(float2 uvIn, float aspect, bool doAspect)
{
    float2 uv = uvIn - float2(0.5, 0.5);
    if (doAspect) { uv.x = uv.x * aspect; }
    float2 coord = float2(
        atan2(uv.y, uv.x) / NM_POLAR_TAU + 0.5,
        length(uv) - scale * 0.075
    );
    coord.x = nm_polar_smod1(coord.x + time * -(float)rotation, 1.0);
    coord.y = nm_polar_smod1(coord.y + time *  (float)speed,    1.0);
    return coord;
}

// ---- vortexCoords — verbatim from WGSL ----------------------------------------
// WGSL:
//   var uv = uvIn - 0.5;
//   if (doAspect) { uv.x = uv.x * aspect; }
//   let r2 = dot(uv, uv) - uniforms.scale * 0.01;
//   uv = uv / r2;
//   uv.x = smod1(uv.x + uniforms.time * -uniforms.rotation, 1.0);
//   uv.y = smod1(uv.y + uniforms.time *  uniforms.speed,    1.0);
//   return uv;
float2 nm_polar_vortexCoords(float2 uvIn, float aspect, bool doAspect)
{
    float2 uv = uvIn - float2(0.5, 0.5);
    if (doAspect) { uv.x = uv.x * aspect; }
    float r2 = dot(uv, uv) - scale * 0.01;
    uv = uv / r2;
    uv.x = nm_polar_smod1(uv.x + time * -(float)rotation, 1.0);
    uv.y = nm_polar_smod1(uv.y + time *  (float)speed,    1.0);
    return uv;
}

// =============================================================================
// NMFrag_polar — main fragment for pass "polar".
//
// WGSL main():
//   let texSize = vec2<f32>(textureDimensions(inputTex));
//   let uv      = pos.xy / texSize;
//   let aspect  = texSize.x / texSize.y;
//   let doAspect = uniforms.aspectLens != 0;
//   var coord: vec2<f32>;
//   if (uniforms.polarMode == 0) { coord = polarCoords(uv, aspect, doAspect); }
//   else                         { coord = vortexCoords(uv, aspect, doAspect); }
//   if (uniforms.antialias != 0) {
//       let dx = dpdx(coord); let dy = dpdy(coord);
//       var col = vec4<f32>(0.0);
//       col += textureSample(inputTex, inputSampler, coord + dx * -0.375 + dy * -0.125);
//       col += textureSample(inputTex, inputSampler, coord + dx *  0.125 + dy * -0.375);
//       col += textureSample(inputTex, inputSampler, coord + dx *  0.375 + dy *  0.125);
//       col += textureSample(inputTex, inputSampler, coord + dx * -0.125 + dy *  0.375);
//       return col * 0.25;
//   } else {
//       return textureSample(inputTex, inputSampler, coord);
//   }
// =============================================================================
float4 NMFrag_polar(NMVaryings i) : SV_Target
{
    uint tw, th;
    inputTex.GetDimensions(tw, th);
    float2 texSize = float2((float)tw, (float)th);
    float2 uv = NM_FragCoord(i) / texSize;
    float aspect = texSize.x / texSize.y;
    bool doAspect = (aspectLens != 0);

    float2 coord;
    [branch]
    if (polarMode == 0)
    {
        coord = nm_polar_polarCoords(uv, aspect, doAspect);
    }
    else
    {
        coord = nm_polar_vortexCoords(uv, aspect, doAspect);
    }

    [branch]
    if (antialias != 0)
    {
        float2 dx = ddx(coord);
        float2 dy = ddy(coord);
        float4 col = float4(0.0, 0.0, 0.0, 0.0);
        col += inputTex.Sample(sampler_inputTex, coord + dx * -0.375 + dy * -0.125);
        col += inputTex.Sample(sampler_inputTex, coord + dx *  0.125 + dy * -0.375);
        col += inputTex.Sample(sampler_inputTex, coord + dx *  0.375 + dy *  0.125);
        col += inputTex.Sample(sampler_inputTex, coord + dx * -0.125 + dy *  0.375);
        return col * 0.25;
    }
    else
    {
        return inputTex.Sample(sampler_inputTex, coord);
    }
}

#endif // NM_EFFECT_POLAR_INCLUDED
