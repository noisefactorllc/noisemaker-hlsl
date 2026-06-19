#ifndef NM_BLENDMODE_INCLUDED
#define NM_BLENDMODE_INCLUDED

// =============================================================================
// BlendMode.hlsl — mixer/blendMode, ported PIXEL-IDENTICALLY from the canonical
// WGSL:  shaders/effects/mixer/blendMode/wgsl/blendMode.wgsl
//
// Blend two inputs (base = inputTex, layer = tex) with a selectable blend mode,
// then cross-fade with a single `mixAmt` slider and composite Porter-Duff "over"
// using the layer's alpha. Single render pass (definition.js passes[].length==1,
// program "blendMode").
//
// PORTING-GUIDE notes:
//  * Helpers (map_range / blendOverlay / blendSoftLight / applyBlendMode) are this
//    effect's OWN copies — ported VERBATIM inline here, NOT hoisted (golden rule 2).
//    map_range duplicates NMCore's nm_map math but the WGSL ships its own local
//    `map_range`; we keep it inline to mirror the source 1:1.
//  * `mode`: WGSL declares `mode: i32` (a uniform, NOT a compile-time define).
//    definition.js types it `int` with 16 named choices (add..subtract). We declare
//    an `int` uniform and reproduce the WGSL's plain `if (m == k) return ...;`
//    chain verbatim (no [branch] attribute — the WGSL uses none either).
//  * `mixAmt`: WGSL `mixAmt: f32` uniform. definition.js global key is `mix` with
//    uniform name `mixAmt` (paramAliases.mixAmt = 'mix'). Declared as `float mixAmt`.
//  * uv: WGSL line 113-117 divides position.xy by EACH input texture's own
//    dimensions:
//        let dims  = vec2<f32>(textureDimensions(inputTex, 0));
//        let st    = position.xy / dims;
//        color1 = textureSample(inputTex, samp, st);
//        color2 = textureSample(tex,      samp, st);
//    i.e. the same `st` (derived from inputTex's size) samples BOTH textures. The
//    GLSL instead divides each by its own textureSize, but for equal-sized surfaces
//    (the runtime allocates outputTex == input size) these coincide. We follow the
//    canonical WGSL: one `st` from inputTex's dims, used for both samples.
//    tileOffset does NOT enter the sample uv (the WGSL does not add it).
//  * `if (a < 0.5)` style branches are reproduced literally (no ternary reordering).
//  * mix(a,b,t) -> lerp(a,b,t). min/max/abs/sqrt map directly. vec4(1.0) splats.
//  * No PRNG / no atan2 / no select / no nm_mod in this effect — no bit hazards.
//  * Linear, clamp-to-edge, non-sRGB samplers (H7) — set on the SamplerStates in
//    BlendMode.shader / supplied by the Shader Graph node.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
// Bound by the runtime via MaterialPropertyBlock under these exact names.
int   mode;     // globals.mode.uniform "mode",   default 0 (add)
float mixAmt;   // globals.mix.uniform  "mixAmt",  default 0 (paramAliases.mixAmt='mix')

// -----------------------------------------------------------------------------
// map_range — ported VERBATIM from blendMode.wgsl. Per-effect copy.
// WGSL: return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
// -----------------------------------------------------------------------------
float map_range(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

// -----------------------------------------------------------------------------
// blendOverlay — ported VERBATIM from blendMode.wgsl. Per-effect copy.
// -----------------------------------------------------------------------------
float blendOverlay(float a, float b)
{
    if (a < 0.5) {
        return 2.0 * a * b;
    } else {
        return 1.0 - 2.0 * (1.0 - a) * (1.0 - b);
    }
}

// -----------------------------------------------------------------------------
// blendSoftLight — ported VERBATIM from blendMode.wgsl. Per-effect copy.
// -----------------------------------------------------------------------------
float blendSoftLight(float base, float blend)
{
    if (blend < 0.5) {
        return 2.0 * base * blend + base * base * (1.0 - 2.0 * blend);
    } else {
        return sqrt(base) * (2.0 * blend - 1.0) + 2.0 * base * (1.0 - blend);
    }
}

// -----------------------------------------------------------------------------
// applyBlendMode — ported VERBATIM from blendMode.wgsl. Per-effect copy.
// 0: add, 1: burn, 2: darken, 3: diff, 4: dodge, 5: exclusion,
// 6: hardLight, 7: lighten, 8: mix, 9: multiply, 10: negation,
// 11: overlay, 12: phoenix, 13: screen, 14: softLight, 15: subtract
// -----------------------------------------------------------------------------
float4 applyBlendMode(float4 color1, float4 color2, int m)
{
    if (m == 0) {
        // add
        return min(color1 + color2, float4(1.0, 1.0, 1.0, 1.0));
    }
    if (m == 1) {
        // burn
        return 1.0 - min((1.0 - color1) / max(color2, float4(0.001, 0.001, 0.001, 0.001)), float4(1.0, 1.0, 1.0, 1.0));
    }
    if (m == 2) {
        // darken
        return min(color1, color2);
    }
    if (m == 3) {
        // diff
        return abs(color1 - color2);
    }
    if (m == 4) {
        // dodge
        return min(color1 / max(1.0 - color2, float4(0.001, 0.001, 0.001, 0.001)), float4(1.0, 1.0, 1.0, 1.0));
    }
    if (m == 5) {
        // exclusion
        return color1 + color2 - 2.0 * color1 * color2;
    }
    if (m == 6) {
        // hardLight (overlay with swapped args)
        return float4(
            blendOverlay(color2.r, color1.r),
            blendOverlay(color2.g, color1.g),
            blendOverlay(color2.b, color1.b),
            1.0
        );
    }
    if (m == 7) {
        // lighten
        return max(color1, color2);
    }
    if (m == 8) {
        // mix (average)
        return (color1 + color2) * 0.5;
    }
    if (m == 9) {
        // multiply
        return color1 * color2;
    }
    if (m == 10) {
        // negation
        return float4(1.0, 1.0, 1.0, 1.0) - abs(float4(1.0, 1.0, 1.0, 1.0) - color1 - color2);
    }
    if (m == 11) {
        // overlay
        return float4(
            blendOverlay(color1.r, color2.r),
            blendOverlay(color1.g, color2.g),
            blendOverlay(color1.b, color2.b),
            1.0
        );
    }
    if (m == 12) {
        // phoenix
        return min(color1, color2) - max(color1, color2) + float4(1.0, 1.0, 1.0, 1.0);
    }
    if (m == 13) {
        // screen
        return float4(1.0, 1.0, 1.0, 1.0) - (float4(1.0, 1.0, 1.0, 1.0) - color1) * (float4(1.0, 1.0, 1.0, 1.0) - color2);
    }
    if (m == 14) {
        // softLight
        return float4(
            blendSoftLight(color1.r, color2.r),
            blendSoftLight(color1.g, color2.g),
            blendSoftLight(color1.b, color2.b),
            1.0
        );
    }
    // 15: subtract
    return max(color1 - color2, float4(0.0, 0.0, 0.0, 0.0));
}

// -----------------------------------------------------------------------------
// nm_blendMode — core per-pixel evaluation. Takes the two already-sampled input
// colors (color1 = base/inputTex, color2 = layer/tex) and returns the composited
// RGBA. Pure function so the Shader Graph wrapper and the render pass share
// identical math. Ported VERBATIM from blendMode.wgsl main() lines 119-143.
// -----------------------------------------------------------------------------
float4 nm_blendMode(float4 color1, float4 color2)
{
    float4 middle = applyBlendMode(color1, color2, mode);

    float amt = map_range(mixAmt, -100.0, 100.0, 0.0, 1.0);
    float4 color;
    if (amt < 0.5) {
        float factor = amt * 2.0;
        color = lerp(color1, middle, factor);
    } else {
        float factor = (amt - 0.5) * 2.0;
        color = lerp(middle, color2, factor);
    }

    // Porter-Duff "over" alpha compositing:
    // blend at full strength where top is opaque, preserve base where top is
    // transparent. amt is already applied above in the mixer branch that selected
    // `color` on the color1 <-> middle <-> color2 axis, so it must NOT be folded
    // into the PD factor for RGB here — doing so applies amt a second time and
    // halves the blend at the midpoint. The alpha output still scales with amt so
    // fading out the layer fades out the composite alpha.
    float alphaFactor = color2.a * amt;
    color = float4(
        lerp(color1.rgb, color.rgb, color2.a),
        alphaFactor + color1.a * (1.0 - alphaFactor)
    );
    return color;
}

#endif // NM_BLENDMODE_INCLUDED
