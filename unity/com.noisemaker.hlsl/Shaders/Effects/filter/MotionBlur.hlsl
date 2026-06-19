#ifndef NM_EFFECT_MOTIONBLUR_INCLUDED
#define NM_EFFECT_MOTIONBLUR_INCLUDED

// =============================================================================
// MotionBlur.hlsl — filter/motionBlur (func: "motionBlur")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL sources:
//   shaders/effects/filter/motionBlur/wgsl/motionBlur.wgsl  (progName "motionBlur")
//   shaders/effects/filter/motionBlur/wgsl/copy.wgsl        (progName "copy")
//
// Simple motion blur via frame blending with a PERSISTENT feedback buffer.
//
// Two passes per frame, in definition order:
//   1. "main"     (program "motionBlur"): inputs inputTex=inputTex,
//                  selfTex=_selfTex (persistent feedback); output fragColor=outputTex.
//                  Blends current input with the previous frame (held in _selfTex).
//   2. "feedback" (program "copy"): input inputTex=outputTex; output
//                  fragColor=_selfTex (persistent). Copies this frame's output back
//                  into the feedback buffer so the NEXT frame's "main" pass reads it.
//
// FEEDBACK / PERSISTENCE: `_selfTex` is a '_'-prefixed PERSISTENT texture. The C#
// runtime must treat it as state (NOT freed/cleared between frames) so the value
// written by the "feedback" pass survives to the next frame's "main" pass. This is
// the whole effect: motionBlur reads last frame's _selfTex, copy refills it.
//
// NOTE: this effect is multi-pass with persistent feedback and ships as a runtime-
// rendered Texture2D. No Shader Graph Custom Function wrapper is provided
// (multi-pass + feedback state cannot be expressed as a single Custom Function node).
//
// PORTING-GUIDE notes / hazards handled:
//  * Ported from WGSL (top-left, canonical). No per-effect Y flip (Golden rule 1).
//  * COORDINATE ASYMMETRY (reproduced literally):
//      - "motionBlur" main: `uv = pos.xy / uniforms.resolution` — divides by the
//        ENGINE resolution uniform (current render-target size), NOT texture dims
//        and NOT fullResolution. We mirror with NM_FragCoord(i) / resolution.
//      - "copy": `uv = pos.xy / vec2<f32>(textureDimensions(inputTex, 0))` — divides
//        by the INPUT TEXTURE's own size. We mirror with inputTex.GetDimensions.
//    These are different denominators; do not unify them.
//  * resetState is a WGSL `i32` tested `!= 0` (the GLSL `bool` path is equivalent).
//    We declare `int resetState` and test `!= 0` to match the WGSL exactly.
//  * mixFactor = clamp(amount * 0.008, 0.0, 0.98); mix(current, previous, mixFactor)
//    -> lerp(current, previous, mixFactor). Magic constants 0.008 / 0.98 verbatim.
//  * Distinct input samplers across passes: "motionBlur" samples inputTex + selfTex;
//    "copy" samples inputTex. We declare inputTex (+sampler), selfTex (+sampler).
//    The runtime rebinds inputTex per pass (effect input for "main", outputTex for
//    "copy"). selfTex is only sampled by "main".
//  * No helpers from NMCore are used (no pcg/prng/random/nm_mod/etc.); none needed.
//  * Linear, clamp-to-edge, non-sRGB samplers (H7) — set on the SamplerStates in
//    MotionBlur.shader.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input textures + samplers (distinct samplers per the WGSL bindings) -----
// "motionBlur" pass: inputTex (binding 2) + selfTex (binding 3), shared sampler.
// "copy" pass: inputTex (binding 1) with its own sampler.
// HLSL name `inputTex` is shared; the runtime rebinds it per pass
// (effect input for "main", outputTex for "feedback").
Texture2D    inputTex;
SamplerState sampler_inputTex;

Texture2D    selfTex;       // persistent feedback buffer (_selfTex), sampled by "main"
SamplerState sampler_selfTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -------
float amount;       // globals.amount.uniform, [0,100], default 50
int   resetState;   // globals.resetState.uniform, boolean (0/1), default 0 (false)

// -----------------------------------------------------------------------------
// Pass "main" (program "motionBlur") — verbatim from motionBlur.wgsl main().
//
// WGSL:
//   let uv = pos.xy / uniforms.resolution;
//   if (uniforms.resetState != 0) {
//       return textureSample(inputTex, texSampler, uv);
//   }
//   let current  = textureSample(inputTex, texSampler, uv);
//   let previous = textureSample(selfTex,  texSampler, uv);
//   let mixFactor = clamp(uniforms.amount * 0.008, 0.0, 0.98);
//   return mix(current, previous, mixFactor);
// -----------------------------------------------------------------------------
float4 frag_motionBlur(NMVaryings i) : SV_Target
{
    float2 uv = NM_FragCoord(i) / resolution;

    // If resetState is true, bypass feedback and return input directly.
    if (resetState != 0)
    {
        return inputTex.Sample(sampler_inputTex, uv);
    }

    float4 current  = inputTex.Sample(sampler_inputTex, uv);
    float4 previous = selfTex.Sample(sampler_selfTex, uv);

    // Map amount 0-100 to 0-0.8 (clamped at 0.98).
    float mixFactor = clamp(amount * 0.008, 0.0, 0.98);

    return lerp(current, previous, mixFactor);
}

// -----------------------------------------------------------------------------
// Pass "feedback" (program "copy") — verbatim from copy.wgsl main().
// Copies the just-rendered output back into the persistent _selfTex buffer.
//
// WGSL:
//   let dims = vec2<f32>(textureDimensions(inputTex, 0));
//   let uv = pos.xy / dims;
//   return textureSample(inputTex, inputSampler, uv);
// -----------------------------------------------------------------------------
float4 frag_copy(NMVaryings i) : SV_Target
{
    uint w, h;
    inputTex.GetDimensions(w, h);
    float2 dims = float2((float)w, (float)h);
    float2 uv = NM_FragCoord(i) / dims;
    return inputTex.Sample(sampler_inputTex, uv);
}

#endif // NM_EFFECT_MOTIONBLUR_INCLUDED
