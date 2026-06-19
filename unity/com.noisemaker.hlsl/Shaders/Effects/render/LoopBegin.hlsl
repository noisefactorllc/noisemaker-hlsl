#ifndef NM_EFFECT_LOOPBEGIN_INCLUDED
#define NM_EFFECT_LOOPBEGIN_INCLUDED

// =============================================================================
// LoopBegin.hlsl — render/loopBegin (func: "loopBegin")
//
// Start of an accumulator feedback loop. Reads a persistent feedback buffer
// (global_accum) and blends it with the incoming texture using lighten (max)
// mode, then passes the result through to the next effect in the chain. A
// matching render/loopEnd writes the processed chain result back into
// global_accum, closing the loop (reference 10 §"render/loopBegin and
// render/loopEnd implement an accumulator pattern").
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source (top-left origin,
// no per-effect Y flip):
//   wgsl/loopBegin.wgsl   progName "loopBegin"   (frag_loopBegin)
//
// SINGLE PASS, FEEDBACK READ ONLY. This shader does NOT write global_accum
// itself — loopEnd does. loopBegin's only persistent dependency is the READ of
// global_accum (the prior loop iteration's / prior frame's accumulated state).
//
// LOOP-BRACKET SEMANTICS: loopBegin/loopEnd bracket a DSL sub-chain that the
// frontend compiler expands and the runtime iterates N times. This particular
// shader is NOT itself the loop body — it is a plain fullscreen blend executed
// once at the start of the bracket. The "loop" is control-flow handled by the
// compiler/runtime (reference 10 §"Some effects use repeat:..."), not by this
// fragment program. There is no iteration index uniform.
//
// MULTI-PASS / FEEDBACK effect → ships as a runtime-rendered Texture2D. No
// Shader Graph Custom Function wrapper is provided (the C# runtime binds
// inputTex and the persistent global_accum surface and drives the pass).
//
// PORTING-GUIDE / parity notes:
//  * WGSL textureSample(t, samp, st) → t.Sample(sampler_t, st) (bilinear,
//    clamp-to-edge, non-sRGB). Both inputTex and accumTex are sampled this way.
//  * st = position.xy / textureDimensions(inputTex). The WGSL divides the
//    top-left fragCoord by inputTex's OWN dimensions (NOT the resolution
//    uniform). Reproduced exactly via inputTex.GetDimensions + NM_FragCoord.
//  * max(vec4,vec4) → max(float4,float4) (component-wise). mix→lerp.
//  * alpha and intensity are 0..100 sliders, divided by 100.0 in-shader.
//  * No nm_mod / pcg / prng used; no NMCore helpers needed beyond NMFullscreen.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input samplers ----------------------------------------------------------
// inputTex: current chain input. accumTex: persistent global_accum feedback.
// The runtime rebinds these per definition.js inputs{}.
Texture2D inputTex;   SamplerState sampler_inputTex;
Texture2D accumTex;   SamplerState sampler_accumTex;

// ---- Per-effect named uniforms (match globals[*].uniform) --------------------
float alpha;       // globals.alpha     default 50  (0..100)
float intensity;   // globals.intensity default 100 (0..100)

// =============================================================================
// PASS: loopBegin — read feedback accumulator, lighten-blend with input
// =============================================================================
float4 frag_loopBegin(NMVaryings i) : SV_Target
{
    uint dw, dh;
    inputTex.GetDimensions(dw, dh);
    float2 dims = float2((float)dw, (float)dh);
    float2 st = NM_FragCoord(i) / dims;

    float4 inputColor = inputTex.Sample(sampler_inputTex, st);
    float4 accum = accumTex.Sample(sampler_accumTex, st);

    // Normalize alpha from 0-100 to 0-1
    float a = alpha / 100.0;

    // Normalize intensity from 0-100 to 0-1
    float ii = intensity / 100.0;

    // Lighten blend: max of input and accumulated
    float4 blended = max(inputColor, accum * ii);

    // Mix between pure input and blended based on alpha
    float4 result = lerp(inputColor, blended, a);

    // Preserve alpha
    result.a = max(inputColor.a, accum.a);

    return result;
}

#endif // NM_EFFECT_LOOPBEGIN_INCLUDED
