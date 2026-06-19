#ifndef NM_COMPOSITE_INCLUDED
#define NM_COMPOSITE_INCLUDED

// =============================================================================
// Composite.hlsl — classicNoisedeck/composite, ported PIXEL-IDENTICALLY from
// the canonical WGSL:
//   shaders/effects/classicNoisedeck/composite/wgsl/composite.wgsl
//
// Kind: mixer (two inputs: inputTex = A, tex = B).
// Single render pass (definition.js passes.length == 1, program "composite").
//
// PORTING-GUIDE notes:
//  * hsv2rgb / rgb2hsv / desaturate / blend_colors are this effect's OWN copies,
//    ported VERBATIM inline. They differ from any shared library version — do NOT
//    substitute. (Golden rule 2.)
//  * blendMode is an int uniform (definition.js type "int", 16 choices). We
//    declare `int blendMode` and reproduce the WGSL if-chain verbatim with
//    [branch] to prevent the compiler from flattening the chain into a select
//    tree (matching WGSL's natural branching).
//  * mixAmt: definition.js global key "mix", uniform name "mixAmt"
//    (paramAliases.mixAmt = 'mix'). Declared float mixAmt.
//  * inputColor: definition.js type "color", default [0,0,0]. Declared float3.
//  * range: definition.js type "float", default 20. Declared float.
//  * UV: WGSL uses textureDimensions(inputTex,0) for st, samples BOTH inputs
//    with that same st — identical to how mixer/blendMode works. Follow WGSL.
//  * WGSL `%` on f32 is floored mod. Translated to nm_mod (PORTING-GUIDE H6).
//  * mix() -> lerp(). fract() -> frac(). step() stays step().
//    smoothstep(a,b,x) — WGSL and HLSL share the same argument order.
//  * WGSL `select(false_val, true_val, cond)` does NOT appear in this shader.
//  * No PRNG / no atan2 / no nm_positiveModulo in this effect.
//  * Linear, clamp-to-edge, non-sRGB samplers (H7).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
float3 inputColor;  // globals.inputColor.uniform "inputColor", default (0,0,0)
int    blendMode;   // globals.blendMode.uniform  "blendMode",  default 1
float  range;       // globals.range.uniform      "range",      default 20
float  mixAmt;      // globals.mix.uniform        "mixAmt",     default 50

// -----------------------------------------------------------------------------
// hsv2rgb — ported VERBATIM from composite.wgsl lines 18-44. Per-effect copy.
// -----------------------------------------------------------------------------
float3 hsv2rgb(float3 hsv)
{
    float h = frac(hsv.x);
    float s = hsv.y;
    float v = hsv.z;

    float c = v * s;
    float x = c * (1.0 - abs(nm_mod(h * 6.0, 2.0) - 1.0));
    float m = v - c;

    float3 rgb;

    if (h < 1.0 / 6.0) {
        rgb = float3(c, x, 0.0);
    } else if (h < 2.0 / 6.0) {
        rgb = float3(x, c, 0.0);
    } else if (h < 3.0 / 6.0) {
        rgb = float3(0.0, c, x);
    } else if (h < 4.0 / 6.0) {
        rgb = float3(0.0, x, c);
    } else if (h < 5.0 / 6.0) {
        rgb = float3(x, 0.0, c);
    } else {
        rgb = float3(c, 0.0, x);
    }

    return rgb + float3(m, m, m);
}

// -----------------------------------------------------------------------------
// rgb2hsv — ported VERBATIM from composite.wgsl lines 46-73. Per-effect copy.
// WGSL `%` on f32 -> nm_mod (H6).
// -----------------------------------------------------------------------------
float3 rgb2hsv(float3 rgb)
{
    float r = rgb.r;
    float g = rgb.g;
    float b = rgb.b;

    float max_val = max(r, max(g, b));
    float min_val = min(r, min(g, b));
    float delta = max_val - min_val;

    float h = 0.0;
    if (delta != 0.0) {
        if (max_val == r) {
            h = nm_mod((g - b) / delta, 6.0) / 6.0;
        } else if (max_val == g) {
            h = ((b - r) / delta + 2.0) / 6.0;
        } else if (max_val == b) {
            h = ((r - g) / delta + 4.0) / 6.0;
        }
    }

    float s = 0.0;
    if (max_val != 0.0) {
        s = delta / max_val;
    }
    float v_out = max_val;

    return float3(h, s, v_out);
}

// -----------------------------------------------------------------------------
// desaturate — ported VERBATIM from composite.wgsl lines 75-79. Per-effect copy.
// -----------------------------------------------------------------------------
float3 desaturate(float3 color)
{
    float3 c = rgb2hsv(color);
    c.y = 0.0;
    return hsv2rgb(c);
}

// -----------------------------------------------------------------------------
// blend_colors — ported VERBATIM from composite.wgsl lines 81-179.
// Per-effect copy. WGSL if-chain reproduced literally with [branch].
// WGSL `step(vec3<f32>(cut), x)` -> step((float3)cut, x) (splat scalar).
// WGSL `mix(a,b,t)` -> lerp(a,b,t).
// -----------------------------------------------------------------------------
float3 blend_colors(float3 color1_in, float3 color2_in)
{
    float3 color = float3(0.0, 0.0, 0.0);
    float3 color1 = color1_in;
    float3 color2 = color2_in;
    float cut = range * 0.01;

    [branch]
    if (blendMode == 0) {
        // color splash. isolate input color and desaturate others
        if (distance(inputColor, color1) > range * 0.01) {
            color1 = desaturate(color1);
        }

        if (distance(inputColor, color2) > range * 0.01) {
            color2 = desaturate(color2);
        }

        color = lerp(color1, color2, mixAmt * 0.01);
    } else if (blendMode == 1) {
        // greenscreen a -> b. make color transparent
        if (distance(inputColor, color1) <= range * 0.01) {
            color = color2;
        } else {
            color = lerp(color1, color2, mixAmt * 0.01);
        }
    } else if (blendMode == 2) {
        // greenscreen b-> a. make color transparent
        if (distance(inputColor, color2) <= range * 0.01) {
            color = color1;
        } else {
            color = lerp(color2, color1, mixAmt * 0.01);
        }
    } else if (blendMode == 3) {
        // a -> b black
        float c = 1.0 - step(cut, desaturate(color2).r);
        color2 = lerp(color1, float3(0.0, 0.0, 0.0), c);
        color = lerp(color1, color2, mixAmt * 0.01);
    } else if (blendMode == 4) {
        // a -> b color black
        float3 c = 1.0 - step((float3)cut, color2);
        color2 = lerp(color1, float3(0.0, 0.0, 0.0), c);
        color = lerp(color1, color2, mixAmt * 0.01);
    } else if (blendMode == 5) {
        // a -> b hue
        float c = rgb2hsv(color2).r;
        color2 = lerp(color1, color2, c * cut);
        color = lerp(color1, color2, mixAmt * 0.01);
    } else if (blendMode == 6) {
        // a -> b saturation
        float c = rgb2hsv(color2).g;
        color2 = lerp(color1, color2, c * cut);
        color = lerp(color1, color2, mixAmt * 0.01);
    } else if (blendMode == 7) {
        // a -> b value
        float c = rgb2hsv(color2).b;
        color2 = lerp(color1, color2, c * cut);
        color = lerp(color1, color2, mixAmt * 0.01);
    } else if (blendMode == 8) {
        // b -> a black
        float c = 1.0 - step(cut, desaturate(color1).r);
        color1 = lerp(color2, float3(0.0, 0.0, 0.0), c);
        color = lerp(color2, color1, mixAmt * 0.01);
    } else if (blendMode == 9) {
        // b -> a color black
        float3 c = 1.0 - step((float3)cut, color1);
        color1 = lerp(color2, float3(0.0, 0.0, 0.0), c);
        color = lerp(color2, color1, mixAmt * 0.01);
    } else if (blendMode == 10) {
        // b -> a hue
        float c = rgb2hsv(color1).r;
        color1 = lerp(color1, color2, c * cut);
        color = lerp(color2, color1, mixAmt * 0.01);
    } else if (blendMode == 11) {
        // b -> a saturation
        float c = rgb2hsv(color1).g;
        color1 = lerp(color1, color2, c * cut);
        color = lerp(color2, color1, mixAmt * 0.01);
    } else if (blendMode == 12) {
        // b -> a value
        float c = rgb2hsv(color1).b;
        color1 = lerp(color1, color2, c * cut);
        color = lerp(color2, color1, mixAmt * 0.01);
    } else if (blendMode == 13) {
        // mix
        color2 = lerp(color1, color2, cut);
        color = lerp(color1, color2, mixAmt * 0.01);
    } else if (blendMode == 14) {
        // psychedelic
        float3 c = step((float3)cut, lerp(color1, color2, 0.5));
        color2 = lerp(color1, color2, c);
        color = lerp(color1, color2, mixAmt * 0.01);
    } else {
        // psychedelic 2 (blendMode == 15)
        // WGSL: smoothstep(color1, vec3<f32>(cut), color2)
        // HLSL smoothstep(edge0, edge1, x) — same argument order as WGSL.
        float3 c1 = smoothstep(color1, (float3)cut, color2);
        float3 c2 = smoothstep(color2, (float3)cut, color1);
        color = lerp(c1.brg, c2.gbr, mixAmt * 0.01);
    }

    return color;
}

// -----------------------------------------------------------------------------
// nm_composite — core per-pixel evaluation. Takes already-sampled colors
// (color1 = inputTex, color2 = tex) and returns composited RGBA.
// Ported VERBATIM from composite.wgsl main() lines 181-193.
// -----------------------------------------------------------------------------
float4 nm_composite(float4 color1, float4 color2)
{
    float4 color = float4(0.0, 0.0, 1.0, 1.0);
    color = float4(blend_colors(color1.rgb, color2.rgb), lerp(color1.a, color2.a, mixAmt * 0.01));
    return color;
}

#endif // NM_COMPOSITE_INCLUDED
