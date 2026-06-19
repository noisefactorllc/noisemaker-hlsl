#ifndef NM_EFFECT_LOOPEND_INCLUDED
#define NM_EFFECT_LOOPEND_INCLUDED

// =============================================================================
// LoopEnd.hlsl — render/loopEnd (func: "loopEnd")
//
// End of an accumulator feedback loop. Writes the processed chain result back
// into the persistent feedback surface (global_accum), closing the loop that
// render/loopBegin opens (reference 10 §"render/loopBegin and render/loopEnd
// implement an accumulator pattern"). loopBegin READS global_accum; loopEnd
// WRITES it (via the shared "copy"/blit program) and also passes the result
// through to outputTex.
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source (top-left origin,
// no per-effect Y flip):
//   wgsl/copy.wgsl   progName "copy"   (frag_copy)   fullscreen
//
// TWO PASSES, SAME PROGRAM. Both passes use program "copy" — a plain
// fullscreen blit of inputTex. The only difference is the OUTPUT target:
//   passes[0] "feedback" : copy(inputTex) -> global_accum   (write the loop)
//   passes[1] "output"   : copy(inputTex) -> outputTex      (pass-through)
// Identical fragment program; the runtime rebinds the output per definition.js.
//
// LOOP-BRACKET SEMANTICS: loopBegin/loopEnd bracket a DSL sub-chain that the
// frontend compiler expands and the runtime ITERATES N times (control-flow
// loop). This shader is NOT the loop body — it is a plain fullscreen copy
// executed once at the end of the bracket. There is no iteration-index uniform.
//
// MULTI-PASS / FEEDBACK effect → ships as a runtime-rendered Texture2D. No
// Shader Graph Custom Function wrapper is provided (the C# runtime binds
// inputTex + the persistent global_accum surface and drives the passes).
//
// PORTING-GUIDE / parity notes:
//  * WGSL textureSample(t, samp, uv) → t.Sample(sampler_t, uv) (bilinear,
//    clamp-to-edge, non-sRGB).
//  * uv = position.xy / textureDimensions(inputTex). The WGSL divides the
//    top-left fragCoord by inputTex's OWN dimensions (NOT the resolution
//    uniform). Reproduced exactly via inputTex.GetDimensions + NM_FragCoord.
//  * No uniforms. No nm_mod / pcg / prng used; no NMCore helpers needed beyond
//    NMFullscreen.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input sampler -----------------------------------------------------------
// inputTex: current chain input. The runtime rebinds it per definition.js
// inputs{} for both passes. The output target (global_accum or outputTex) is
// the render target, set by the runtime; not a sampler here.
Texture2D inputTex;   SamplerState sampler_inputTex;

// =============================================================================
// PASS: copy — blit inputTex unchanged (used by both "feedback" and "output").
//   WGSL derives uv from the BOUND input texture's OWN dimensions.
// =============================================================================
float4 frag_copy(NMVaryings i) : SV_Target
{
    uint dw, dh;
    inputTex.GetDimensions(dw, dh);
    float2 uv = NM_FragCoord(i) / float2((float)dw, (float)dh);
    return inputTex.Sample(sampler_inputTex, uv);
}

#endif // NM_EFFECT_LOOPEND_INCLUDED
