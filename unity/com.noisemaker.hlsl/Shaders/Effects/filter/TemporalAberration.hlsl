#ifndef NM_EFFECT_TEMPORALABERRATION_INCLUDED
#define NM_EFFECT_TEMPORALABERRATION_INCLUDED

// =============================================================================
// TemporalAberration.hlsl — filter/temporalAberration (func: "temporalAberration")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL sources:
//   shaders/effects/filter/temporalAberration/wgsl/temporalAberration.wgsl
//       (read pass, progName "temporalAberration")
//   shaders/effects/filter/temporalAberration/wgsl/delayShift.wgsl
//       (shift pass, progName "delayShift")
//
// Temporal chromatic aberration via an 8-stage RGBA "bucket-brigade" delay line
// built only from render passes + persistent textures (no compute, no MRT).
//
// MULTI-PASS / FEEDBACK STATE:
//   9 passes total, in definition order:
//     0  "main"   program "temporalAberration"  -> reads live inputTex (delay 0)
//                                                   plus _h1.._h8 (delay 1..8),
//                                                   per channel fractionally
//                                                   interpolates a delayed frame.
//     1  "shift8" program "delayShift"  _h7 -> _h8
//     2  "shift7" program "delayShift"  _h6 -> _h7
//     3  "shift6" program "delayShift"  _h5 -> _h6
//     4  "shift5" program "delayShift"  _h4 -> _h5
//     5  "shift4" program "delayShift"  _h3 -> _h4
//     6  "shift3" program "delayShift"  _h2 -> _h3
//     7  "shift2" program "delayShift"  _h1 -> _h2
//     8  "shift1" program "delayShift"  inputTex -> _h1
//   The read pass MUST run before the shift passes so the history textures
//   still hold last frame's values. The shifts run tail-first (_h8 first, _h1
//   last) so each stage copies its source's last-frame value before that source
//   is overwritten this frame. _h1.._h8 are PERSISTENT (survive frame-to-frame,
//   init to zero -> alpha 0 == "empty"); the read shader falls back empty slots
//   to the live frame for a clean ramp-in.
//
// NOTE: this effect is multi-pass + persistent-state and ships as a runtime-
// rendered Texture2D (the C# runtime drives the 9 passes in order, rebinding
// srcTex per shift pass and keeping _h1.._h8 alive across frames). No Shader
// Graph Custom Function wrapper is provided.
//
// PORTING-GUIDE notes / hazards handled:
//  * Ported from WGSL (top-left, canonical) -> no per-effect Y flip (Golden #1).
//  * Helpers: NONE from NMCore needed. The bodies use only mix/clamp/floor/min
//    /select(ternary), no pcg/prng/nm_mod. Nothing copied beyond standard ops.
//  * WGSL `uv = pos.xy / texSize` where texSize = textureDimensions(inputTex)
//    in the read pass and textureDimensions(srcTex) in the shift pass — i.e.
//    fragCoord divided by THAT pass's own input-texture size, NOT fullResolution
//    and NOT tileOffset-shifted. Mirrored exactly via NM_FragCoord(i)/float2(w,h).
//  * `i32(floor(dr))` is float->int TRUNCATION via floor first then (int) cast,
//    matching WGSL `i32(floor(...))` / GLSL `int(floor(...))`. `min(ir0+1,8)`
//    is integer min. `f32(ir0)` -> (float)ir0.
//  * WGSL `select(s, cur, s.a < 0.5)` returns `cur` when the condition is true
//    (WGSL select(falseVal, trueVal, cond)). HLSL ternary: `(s.a < 0.5) ? cur : s`
//    — matches GLSL exactly. Empty (alpha<0.5) -> live frame fallback.
//  * `mix(slots[i0], slots[i1], frac)` -> lerp; per channel we then take .r/.g/.b.
//  * Dynamic index into the 9-element slots[] array is data-dependent; HLSL
//    arrays are indexable so this compiles, but indices are clamped to [0,8]
//    exactly as the source clamps delay to [0,8] then min(i0+1,8).
//  * Linear, clamp-to-edge, non-sRGB samplers (H7) — set on the SamplerStates in
//    TemporalAberration.shader. The history textures are rgba8unorm in the
//    reference; the C# runtime allocates them accordingly (alpha carries the
//    "filled" frontier flag, so 8-bit is sufficient and parity-faithful).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
// Bound by the runtime via MaterialPropertyBlock by these exact names.
float redDelay;    // globals.redDelay.uniform,   [0,8] step 0.1, default 0
float greenDelay;  // globals.greenDelay.uniform, [0,8] step 0.1, default 4
float blueDelay;   // globals.blueDelay.uniform,  [0,8] step 0.1, default 8

// ---- Read-pass input textures + samplers (reference bindings) ----------------
// WGSL: samp@1, inputTex@2, h1@3 .. h8@10. The history samplers h1..h8 bind the
// persistent _h1.._h8 textures (pre-shift, holding last frame's content).
Texture2D    inputTex;    SamplerState sampler_inputTex;
Texture2D    h1;          SamplerState sampler_h1;
Texture2D    h2;          SamplerState sampler_h2;
Texture2D    h3;          SamplerState sampler_h3;
Texture2D    h4;          SamplerState sampler_h4;
Texture2D    h5;          SamplerState sampler_h5;
Texture2D    h6;          SamplerState sampler_h6;
Texture2D    h7;          SamplerState sampler_h7;
Texture2D    h8;          SamplerState sampler_h8;

// ---- Shift-pass input texture + sampler (reference: samp@0, srcTex@1) --------
// The runtime rebinds srcTex per shift pass (_h7,_h6,..,_h1,inputTex).
Texture2D    srcTex;      SamplerState sampler_srcTex;

// -----------------------------------------------------------------------------
// frag_temporalAberration — verbatim from WGSL temporalAberration.wgsl main()
// (read pass, progName "temporalAberration").
//
// WGSL:
//   let redDelay = uniforms.data[0].x; ... let blueDelay = uniforms.data[0].z;
//   let texSize = vec2<f32>(textureDimensions(inputTex, 0));
//   let uv = pos.xy / texSize;
//   let cur = textureSampleLevel(inputTex, samp, uv, 0.0);
//   var slots : array<vec4<f32>, 9>; slots[0] = cur;
//   var s : vec4<f32>;
//   s = textureSampleLevel(h1, samp, uv, 0.0); slots[1] = select(s, cur, s.a < 0.5);
//   ... (h2..h8) ...
//   let dr = clamp(redDelay, 0.0, 8.0);
//   let ir0 = i32(floor(dr)); let ir1 = min(ir0 + 1, 8);
//   let rOut = mix(slots[ir0], slots[ir1], dr - f32(ir0)).r;
//   ... (green, blue) ...
//   return vec4<f32>(rOut, gOut, bOut, cur.a);
// -----------------------------------------------------------------------------
float4 frag_temporalAberration(NMVaryings i) : SV_Target
{
    uint w, h;
    inputTex.GetDimensions(w, h);
    float2 texSize = float2((float)w, (float)h);
    float2 uv = NM_FragCoord(i) / texSize;

    float4 cur = inputTex.Sample(sampler_inputTex, uv);

    // slots[0] = live (delay 0); slots[1..8] = history (delay 1..8) with empty -> live.
    float4 slots[9];
    slots[0] = cur;
    float4 s;
    s = h1.Sample(sampler_h1, uv); slots[1] = (s.a < 0.5) ? cur : s;
    s = h2.Sample(sampler_h2, uv); slots[2] = (s.a < 0.5) ? cur : s;
    s = h3.Sample(sampler_h3, uv); slots[3] = (s.a < 0.5) ? cur : s;
    s = h4.Sample(sampler_h4, uv); slots[4] = (s.a < 0.5) ? cur : s;
    s = h5.Sample(sampler_h5, uv); slots[5] = (s.a < 0.5) ? cur : s;
    s = h6.Sample(sampler_h6, uv); slots[6] = (s.a < 0.5) ? cur : s;
    s = h7.Sample(sampler_h7, uv); slots[7] = (s.a < 0.5) ? cur : s;
    s = h8.Sample(sampler_h8, uv); slots[8] = (s.a < 0.5) ? cur : s;

    float dr = clamp(redDelay, 0.0, 8.0);
    int ir0 = (int)floor(dr);
    int ir1 = min(ir0 + 1, 8);
    float rOut = lerp(slots[ir0], slots[ir1], dr - (float)ir0).r;

    float dg = clamp(greenDelay, 0.0, 8.0);
    int ig0 = (int)floor(dg);
    int ig1 = min(ig0 + 1, 8);
    float gOut = lerp(slots[ig0], slots[ig1], dg - (float)ig0).g;

    float db = clamp(blueDelay, 0.0, 8.0);
    int ib0 = (int)floor(db);
    int ib1 = min(ib0 + 1, 8);
    float bOut = lerp(slots[ib0], slots[ib1], db - (float)ib0).b;

    return float4(rOut, gOut, bOut, cur.a);
}

// -----------------------------------------------------------------------------
// frag_delayShift — verbatim from WGSL delayShift.wgsl main()
// (shift pass, progName "delayShift"). Copies one delay-line stage into the
// next, preserving alpha so the "filled" frontier advances one stage per frame.
//
// WGSL:
//   let texSize = vec2<f32>(textureDimensions(srcTex, 0));
//   let uv = pos.xy / texSize;
//   return textureSampleLevel(srcTex, samp, uv, 0.0);
// -----------------------------------------------------------------------------
float4 frag_delayShift(NMVaryings i) : SV_Target
{
    uint w, h;
    srcTex.GetDimensions(w, h);
    float2 texSize = float2((float)w, (float)h);
    float2 uv = NM_FragCoord(i) / texSize;
    return srcTex.Sample(sampler_srcTex, uv);
}

#endif // NM_EFFECT_TEMPORALABERRATION_INCLUDED
