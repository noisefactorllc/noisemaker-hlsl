#ifndef NM_TRANSLATE_INCLUDED
#define NM_TRANSLATE_INCLUDED

// =============================================================================
// Translate.hlsl — filter/translate, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/translate/wgsl/translate.wgsl
//
// Translates the input image by (x, y) in UV space, with three wrap modes:
//   0 = mirror, 1 = repeat, 2 = clamp
//
// WGSL main():
//   let texSize = vec2<f32>(textureDimensions(inputTex));
//   var uv = pos.xy / texSize;
//   uv.x = uv.x - uniforms.x;
//   uv.y = uv.y - uniforms.y;
//   if (uniforms.wrap == 0) { // mirror
//       uv = abs(((uv + 1.0) % 2.0 + 2.0) % 2.0 - 1.0);
//   } else if (uniforms.wrap == 1) { // repeat
//       uv = (uv % 1.0 + 1.0) % 1.0;
//   } else { // clamp
//       uv = clamp(uv, vec2<f32>(0.0), vec2<f32>(1.0));
//   }
//   return textureSample(inputTex, inputSampler, uv);
//
// PORTING-GUIDE notes:
//  * uv = fragCoord / INPUT TEXTURE's own dimensions (not fullResolution). Follow
//    WGSL: NM_FragCoord(i) / float2(tw, th). No tileOffset added (WGSL is canonical).
//  * WGSL `%` on floats is floor-based modulo -> nm_mod (NEVER fmod).
//  * mirror formula: abs(nm_mod(uv + 1.0, 2.0) + 2.0, ... ) — see verbatim below.
//  * wrap is an int uniform; branch with [branch] at runtime (WGSL already branches).
//  * No PRNG / no PCG / no float-bit hazards in this effect.
//  * Linear, clamp-to-edge, non-sRGB sampler (H7) — configured in Translate.shader.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (reference binding: inputSampler@0, inputTex@1) --
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) --------
float x;    // globals.x.uniform, [-1,1] default 0
float y;    // globals.y.uniform, [-1,1] default 0
int   wrap; // globals.wrap.uniform: 0=mirror, 1=repeat, 2=clamp  default 1

// =============================================================================
// nm_translate — core per-pixel evaluation. `fragCoord` is NM_FragCoord(i)
// (top-left, +0.5); `texSize` is the input texture dimensions.
// Returns RGBA sampled at the translated, wrapped UV.
// =============================================================================
float4 nm_translate(float2 fragCoord, float2 texSize)
{
    // WGSL: var uv = pos.xy / texSize;
    float2 uv = fragCoord / texSize;

    // WGSL: uv.x = uv.x - uniforms.x;  uv.y = uv.y - uniforms.y;
    uv.x = uv.x - x;
    uv.y = uv.y - y;

    // WGSL: wrap mode branches — WGSL % on float is floor-based -> nm_mod
    [branch]
    if (wrap == 0)
    {
        // mirror: abs(((uv + 1.0) % 2.0 + 2.0) % 2.0 - 1.0)
        uv = abs(nm_mod(nm_mod(uv + float2(1.0, 1.0), float2(2.0, 2.0)) + float2(2.0, 2.0), float2(2.0, 2.0)) - float2(1.0, 1.0));
    }
    else if (wrap == 1)
    {
        // repeat: (uv % 1.0 + 1.0) % 1.0
        uv = nm_mod(nm_mod(uv, float2(1.0, 1.0)) + float2(1.0, 1.0), float2(1.0, 1.0));
    }
    else
    {
        // clamp
        uv = clamp(uv, float2(0.0, 0.0), float2(1.0, 1.0));
    }

    // WGSL: return textureSample(inputTex, inputSampler, uv);
    return inputTex.Sample(sampler_inputTex, uv);
}

// ---- Pass: "translate" (progName "translate") --------------------------------
float4 NMFrag_translate(NMVaryings i) : SV_Target
{
    // WGSL: texSize = vec2<f32>(textureDimensions(inputTex)); uv = pos.xy / texSize;
    uint tw, th;
    inputTex.GetDimensions(tw, th);
    float2 texSize = float2((float)tw, (float)th);

    return nm_translate(NM_FragCoord(i), texSize);
}

#endif // NM_TRANSLATE_INCLUDED
