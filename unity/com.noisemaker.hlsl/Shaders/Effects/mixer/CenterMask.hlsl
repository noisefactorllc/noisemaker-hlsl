#ifndef NM_CENTERMASK_INCLUDED
#define NM_CENTERMASK_INCLUDED

// =============================================================================
// CenterMask.hlsl — mixer/centerMask, ported PIXEL-IDENTICALLY from the
// canonical WGSL: shaders/effects/mixer/centerMask/wgsl/centerMask.wgsl
//
// Blends from edges (inputTex/A) into center (tex/B) using a distance-based
// mask. The mask is computed in tile-local pixel space (no tileOffset — the
// WGSL does not add it). Single render pass (definition.js passes.length == 1,
// program "centerMask").
//
// PORTING-GUIDE notes:
//  * clamp01 / blendOverlay / blendSoftLight / applyBlendMode / distance_metric
//    are this effect's OWN copies, ported VERBATIM inline from centerMask.wgsl.
//    They are NOT shared with BlendMode.hlsl even though they look similar —
//    applyBlendMode here differs: mode 8 ("mix") returns color2 (passthrough),
//    not (color1+color2)*0.5. Golden rule 2: never substitute a generic version.
//  * `power`: WGSL uniform `power: f32`, definition.js key "mix", uniform name
//    "power". Declared as `float power`.
//  * `shape`: WGSL uniform `shape: i32`. 3 choices (circle=0, diamond=1,
//    square=2). distance_metric uses `m % 3` with a WGSL-style negative-modulo
//    guard (`mm < 0 { mm = mm + 3 }`). Reproduced literally.
//  * `hardness`: WGSL uniform `hardness: f32`, range 0..100.
//  * `blendMode`: WGSL uniform `blendMode: i32`, 16 choices.
//  * UV: WGSL `let dims = textureDimensions(inputTex,0); let st = position.xy/dims`.
//    Both textures sampled at the same st (tile-local). tileOffset NOT added.
//  * Mask center: WGSL `p = (position.xy - 0.5*dims) / (0.5*minRes)` where
//    minRes = min(dims.x,dims.y). This is tile-local (no tileOffset/fullResolution).
//    Follow the WGSL, NOT the GLSL which uses global coords + fullResolution.
//  * WGSL `select(b,a,cond)` -> HLSL `cond ? a : b` (reversed args — H table).
//    (No select() calls in this effect's main logic, but noted for completeness.)
//  * No PRNG / no atan2 / no nm_mod in this effect — no bit hazards.
//  * Full 32-bit float only (H4).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
float power;      // globals.mix.uniform "power",      default 0,  range -100..100
int   shape;      // globals.shape.uniform "shape",    default 2   (square)
float hardness;   // globals.hardness.uniform "hardness", default 0, range 0..100
int   blendMode;  // globals.blendMode.uniform "blendMode", default 8

// -----------------------------------------------------------------------------
// clamp01 — ported VERBATIM from centerMask.wgsl.
// -----------------------------------------------------------------------------
float clamp01(float x)
{
    return clamp(x, 0.0, 1.0);
}

// -----------------------------------------------------------------------------
// blendOverlay — ported VERBATIM from centerMask.wgsl. Per-effect copy.
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
// blendSoftLight — ported VERBATIM from centerMask.wgsl. Per-effect copy.
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
// applyBlendMode — ported VERBATIM from centerMask.wgsl. Per-effect copy.
// NOTE: mode 8 ("mix") returns color2 (passthrough), NOT an average — this
// differs from BlendMode.hlsl. Do not substitute the BlendMode version.
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
        // mix (passthrough color2)
        return color2;
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
// distance_metric — ported VERBATIM from centerMask.wgsl. Per-effect copy.
// shape choices: 0 = circle (euclidean), 1 = diamond (manhattan),
//                2 = square (chebyshev)
// WGSL uses `m % 3` with a negative-modulo guard (mm < 0 -> mm + 3).
// HLSL `%` truncates toward zero (same sign as dividend), so the guard is exact.
// -----------------------------------------------------------------------------
float distance_metric(float2 p, float2 corner, int m)
{
    int mm = m % 3;
    if (mm < 0) {
        mm = mm + 3;
    }
    float2 ap = abs(p);

    // 0: euclidean
    if (mm == 0) {
        float d = length(ap);
        float maxD = length(corner);
        return d / maxD;
    }

    // 1: manhattan
    if (mm == 1) {
        float d = ap.x + ap.y;
        float maxD = corner.x + corner.y;
        return d / maxD;
    }

    // 2: chebyshev
    float d = max(ap.x, ap.y);
    float maxD = max(corner.x, corner.y);
    return d / maxD;
}

// -----------------------------------------------------------------------------
// nm_centerMask — core per-pixel evaluation. Pure function shared by the render
// pass frag and the Shader Graph wrapper. Ported VERBATIM from the WGSL main().
//
// edgeColor   = inputTex sample (edges / source A)
// centerColor = tex sample      (center / source B)
// pos         = fragment position in tile-local pixel space, top-left, +0.5
//               (= NM_FragCoord(i), same as WGSL position.xy)
// dims        = float2 dimensions of inputTex (same tile size as both inputs)
// -----------------------------------------------------------------------------
float4 nm_centerMask(float4 edgeColor, float4 centerColor, float2 pos, float2 dims)
{
    float minRes = min(dims.x, dims.y);

    // Centered, aspect-correct position (matches the WGSL path)
    float2 p = (pos - 0.5 * dims) / (0.5 * minRes);
    float2 corner = dims / minRes;

    float dist01 = clamp01(distance_metric(p, corner, shape));
    // Remap power from -100..100 to 0.1..25.05 (Old 0 maps to New 100)
    float scaledPower = lerp(0.1, 25.05, (power + 100.0) / 200.0);
    float mask = pow(dist01, scaledPower);

    // Apply hardness
    float h = clamp(hardness / 100.0, 0.0, 0.995);
    float width = (1.0 - h) * 0.5;
    mask = smoothstep(0.5 - width, 0.5 + width, mask);

    // Edge fading:
    // power < -95: fade to edgeColor (mask=1)
    // power > 95: fade to centerColor (mask=0)
    float f_low  = clamp((power + 100.0) / 5.0, 0.0, 1.0);
    float f_high = clamp((100.0 - power) / 5.0, 0.0, 1.0);

    mask = lerp(1.0, mask, f_low);
    mask = mask * f_high;

    // Apply blend mode between center and edge colors
    float4 blended = applyBlendMode(centerColor, edgeColor, blendMode);
    float4 color = lerp(centerColor, blended, mask);
    color.a = max(edgeColor.a, centerColor.a);

    return color;
}

#endif // NM_CENTERMASK_INCLUDED
