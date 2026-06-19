#ifndef NM_ALPHAMASK_INCLUDED
#define NM_ALPHAMASK_INCLUDED

// =============================================================================
// AlphaMask.hlsl — mixer/alphaMask, ported PIXEL-IDENTICALLY from the canonical
// WGSL:  shaders/effects/mixer/alphaMask/wgsl/alphaMask.wgsl
//
// Alpha transparency blend of two surfaces (base = inputTex, layer = tex).
// Single render pass (definition.js passes[].length == 1, program "alphaMask").
//
// PORTING-GUIDE notes:
//  * map_range is this effect's OWN per-effect copy (verbatim from WGSL line 7-9).
//    It happens to share the same formula as NMCore nm_map but the WGSL ships its
//    own local `map_range`; we keep it inline per golden rule 2.
//  * maskMode: WGSL `maskMode: i32`, tests `maskMode != 0`. Declared as `int`
//    uniform; runtime passes 1 (true) / 0 (false). definition.js type "boolean",
//    uniform "maskMode", default false.
//  * mixAmt: WGSL `mixAmt: f32`. definition.js global key "mix" with uniform name
//    "mixAmt" (paramAliases.mixAmt = 'mix'). Declared as `float mixAmt`.
//  * uv: WGSL lines 13-17 divide position.xy by inputTex's OWN dimensions (not
//    fullResolution) and use the SAME st for both texture samples:
//        let dims = vec2<f32>(textureDimensions(inputTex, 0));
//        var st = position.xy / dims;
//        color1 = textureSample(inputTex, samp, st);
//        color2 = textureSample(tex,      samp, st);
//    tileOffset does NOT enter the sample uv (the WGSL does not add it).
//  * Branch structure reproduced VERBATIM: `if (maskMode != 0) { ... return; }`
//    then `if (mixAmt < 0.0) { ... } else { ... }` followed by `color.a = max(...)`.
//  * WGSL `mix()` -> HLSL `lerp()`. `vec3<f32>(0.299, 0.587, 0.114)` -> `float3`.
//  * No PRNG / no atan2 / no nm_mod / no select in this effect — no bit hazards.
//  * Linear, clamp-to-edge, non-sRGB samplers (H7) set in AlphaMask.shader.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
float mixAmt;   // globals.mix.uniform  "mixAmt",   default 0  (paramAliases.mixAmt='mix')
int   maskMode; // globals.maskMode.uniform "maskMode", default 0 (false)

// -----------------------------------------------------------------------------
// map_range — ported VERBATIM from alphaMask.wgsl lines 7-9. Per-effect copy.
// WGSL: return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
// -----------------------------------------------------------------------------
float map_range(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

// -----------------------------------------------------------------------------
// nm_alphaMask — core per-pixel evaluation. Takes the two already-sampled input
// colors (color1 = base/inputTex, color2 = layer/tex) and returns the composited
// RGBA. Pure function so the Shader Graph wrapper and the render pass share
// identical math. Ported VERBATIM from alphaMask.wgsl main() lines 20-38.
// -----------------------------------------------------------------------------
float4 nm_alphaMask(float4 color1, float4 color2)
{
    // luminance mask mode
    if (maskMode != 0) {
        float maskVal = dot(color2.rgb, float3(0.299, 0.587, 0.114));
        return float4(color1.rgb, color1.a * maskVal);
    }

    // alpha blend — slider direction selects which input is on top
    float4 color;
    if (mixAmt < 0.0) {
        float4 AoverB = color2 * (1.0 - color1.a) + color1 * color1.a;
        color = lerp(color1, AoverB, map_range(mixAmt, -100.0, 0.0, 0.0, 1.0));
    } else {
        float4 BoverA = color1 * (1.0 - color2.a) + color2 * color2.a;
        color = lerp(BoverA, color2, map_range(mixAmt, 0.0, 100.0, 0.0, 1.0));
    }

    color.a = max(color1.a, color2.a);
    return color;
}

#endif // NM_ALPHAMASK_INCLUDED
