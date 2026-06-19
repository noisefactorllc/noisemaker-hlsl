#ifndef NM_COALESCE_INCLUDED
#define NM_COALESCE_INCLUDED

// =============================================================================
// Coalesce.hlsl — classicNoisedeck/coalesce, ported PIXEL-IDENTICALLY from:
//   shaders/effects/classicNoisedeck/coalesce/wgsl/coalesce.wgsl
//
// Provides blend modes plus a refractive cloaking mix that cross-samples both
// synth inputs. Single render pass.
//
// PORTING-GUIDE notes:
//  * All helpers (map_range / blendOverlay / blendSoftLight / hsv2rgb / rgb2hsv /
//    cloak / blend_colors) are this effect's OWN copies, ported VERBATIM inline.
//  * `blendMode`: int uniform, 19 standard modes (0..18) + cloak (100) + 4 HSV
//    modes (1000..1005). declaration.js types it `int`.
//  * `mixAmt`: float uniform, UI range -100..100. paramAliases.mixAmt='mix'.
//  * uv: WGSL divides position.xy by textureDimensions(inputTex, 0) — i.e. by
//    inputTex's OWN dimensions. Both refracted samples also use inputTex's dims
//    as the coordinate space (st is derived from inputTex size). We follow WGSL.
//  * fract(leftUV) / fract(rightUV): WGSL wraps with fract after adding refract
//    offset. Rendered in HLSL as frac(leftUV) / frac(rightUV).
//  * nm_mod not used here (no floor-mod in this effect).
//  * The WGSL `%` on f32 (line 86: `((h * 6.0) % 2.0)`) is WGSL float modulo
//    which is floor-mod for positives. For h in [0,1), h*6 in [0,6) so the
//    expression is always non-negative — nm_mod and fmod agree here. We use
//    nm_mod for strictness.
//  * WGSL `if (factor == 0.5)` compares floats exactly. The caller passes
//    `mixAmt` directly as factor_in; factor==0.5 means mixAmt==0.5. The runtime
//    defaults mixAmt=0 so this branch is not the default. Reproduced verbatim.
//  * All vec4(1.0) splats rendered as float4(1.0,1.0,1.0,1.0).
//  * mix() -> lerp(). min/max/abs/sqrt map directly.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
int   blendMode;    // globals.blendMode.uniform "blendMode", default 10 (mix)
float mixAmt;       // globals.mix.uniform "mixAmt", default 0 (paramAliases.mixAmt='mix')
float refractAAmt;  // globals.refractAAmt.uniform "refractAAmt", default 0
float refractBAmt;  // globals.refractBAmt.uniform "refractBAmt", default 0
float refractADir;  // globals.refractADir.uniform "refractADir", default 0
float refractBDir;  // globals.refractBDir.uniform "refractBDir", default 0

// ---- Constants ---------------------------------------------------------------

// ---- Textures: declared in the .shader HLSLPROGRAM block (inputTex/tex and
// their samplers). The helper functions below reference them as globals. They
// are NOT redeclared here to avoid a redefinition error (the .shader is the
// single declaration site, matching the mixer-effect convention).

// =============================================================================
// map_range — ported VERBATIM from coalesce.wgsl
// WGSL: return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
// =============================================================================
float map_range(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

// =============================================================================
// blendOverlay — ported VERBATIM from coalesce.wgsl
// =============================================================================
float blendOverlay(float a, float b)
{
    if (a < 0.5) {
        return 2.0 * a * b;
    }
    return 1.0 - 2.0 * (1.0 - a) * (1.0 - b);
}

// =============================================================================
// blendSoftLight — ported VERBATIM from coalesce.wgsl
// =============================================================================
float blendSoftLight(float base, float blend)
{
    if (blend < 0.5) {
        return 2.0 * base * blend + base * base * (1.0 - 2.0 * blend);
    }
    return sqrt(base) * (2.0 * blend - 1.0) + 2.0 * base * (1.0 - blend);
}

// =============================================================================
// hsv2rgb — ported VERBATIM from coalesce.wgsl (per-effect copy)
// NOTE: WGSL uses `%` on f32 for floor-mod on positive values (h*6 in [0,6)).
//       nm_mod is used here for correctness; output is identical for h in [0,1).
// =============================================================================
float3 hsv2rgb(float3 hsv)
{
    float h = frac(hsv.x);
    float s = hsv.y;
    float v = hsv.z;

    float c = v * s;
    float x = c * (1.0 - abs(nm_mod(h * 6.0, 2.0) - 1.0));
    float m = v - c;

    float3 rgb;

    if (h < 1.0/6.0) {
        rgb = float3(c, x, 0.0);
    } else if (h < 2.0/6.0) {
        rgb = float3(x, c, 0.0);
    } else if (h < 3.0/6.0) {
        rgb = float3(0.0, c, x);
    } else if (h < 4.0/6.0) {
        rgb = float3(0.0, x, c);
    } else if (h < 5.0/6.0) {
        rgb = float3(x, 0.0, c);
    } else {
        rgb = float3(c, 0.0, x);
    }

    return rgb + float3(m, m, m);
}

// =============================================================================
// rgb2hsv — ported VERBATIM from coalesce.wgsl (per-effect copy)
// WGSL uses `%` on f32 for floor-mod: ((g - b) / delta) % 6.0.
// For rgb in [0,1], (g-b)/delta is in (-6,6); nm_mod maps to [0,6). // TODO(verify) edge case at exactly -6
// =============================================================================
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
            h = (nm_mod((g - b) / delta, 6.0)) / 6.0;
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
    float v = max_val;

    return float3(h, s, v);
}

// =============================================================================
// vec4_eq — exact element-wise equality (WGSL: all(a == b))
// Used for colorBurn / colorDodge / glow / reflect sentinel checks.
// =============================================================================
bool vec4_eq(float4 a, float4 b)
{
    return all(a == b);
}

// =============================================================================
// cloak — ported VERBATIM from coalesce.wgsl cloak()
// Called when blendMode == 100.
// st: normalized UV derived from inputTex dimensions (top-left origin).
// =============================================================================
float4 nm_coalesce_cloak(float2 st)
{
    float m  = map_range(mixAmt, -100.0, 100.0, 0.0, 1.0);
    float ra = map_range(refractAAmt, 0.0, 100.0, 0.0, 0.125);
    float rb = map_range(refractBAmt, 0.0, 100.0, 0.0, 0.125);

    float4 leftColor  = inputTex.Sample(sampler_inputTex, st);
    float4 rightColor = tex.Sample(sampler_tex, st);

    // When the mixer is all the way to the left, we see left refracted by right
    float2 leftUV  = st;
    float rightLen = length(rightColor.rgb);
    leftUV.x = leftUV.x + cos(rightLen * NM_TAU) * ra;
    leftUV.y = leftUV.y + sin(rightLen * NM_TAU) * ra;

    float4 leftRefracted = inputTex.Sample(sampler_inputTex, frac(leftUV));

    // When the mixer is all the way to the right, we see right refracted by left
    float2 rightUV = st;
    float leftLen  = length(leftColor.rgb);
    rightUV.x = rightUV.x + cos(leftLen * NM_TAU) * rb;
    rightUV.y = rightUV.y + sin(leftLen * NM_TAU) * rb;

    float4 rightRefracted = tex.Sample(sampler_tex, frac(rightUV));

    // As the mixer approaches midpoint, mix the two refracted outputs using the same
    // logic as the "reflect" mode in coalesce.
    float4 leftReflected  = min(rightRefracted * rightColor / (1.0 - leftRefracted  * leftColor),  float4(1.0,1.0,1.0,1.0));
    float4 rightReflected = min(leftRefracted  * leftColor  / (1.0 - rightRefracted * rightColor), float4(1.0,1.0,1.0,1.0));

    float4 left  = float4(1.0,1.0,1.0,1.0);
    float4 right = float4(1.0,1.0,1.0,1.0);
    if (mixAmt < 0.0) {
        left  = lerp(leftRefracted, leftReflected, map_range(mixAmt, -100.0, 0.0, 0.0, 1.0));
        right = rightReflected;
    } else {
        left  = leftReflected;
        right = lerp(rightRefracted, rightRefracted, map_range(mixAmt, 0.0, 100.0, 0.0, 1.0));
    }
    // NOTE: the WGSL cloak() right branch is lerp(rightRefracted, rightRefracted, ...) — verbatim.
    // The GLSL version also has this (same expression both args). Ported literally. // TODO(verify)

    return lerp(left, right, m);
}

// =============================================================================
// blend_colors — ported VERBATIM from coalesce.wgsl blend_colors()
// Called for all modes except cloak (100).
// factor_in: the raw mixAmt value (passed from main as `mixAmt`).
// =============================================================================
float3 nm_blend_colors(float4 color1, float4 color2, int mode_in, float factor_in)
{
    float4 color;
    float4 middle;

    float amt    = map_range(mixAmt, -100.0, 100.0, 0.0, 1.0);
    float factor = factor_in;

    float4 a = float4(1.0,1.0,1.0,1.0);
    float4 b = float4(1.0,1.0,1.0,1.0);
    if (mode_in >= 1000) {
        a = float4(rgb2hsv(color1.rgb), color1.a);
        b = float4(rgb2hsv(color2.rgb), color2.a);
    }

    if (mode_in == 0) {
        // add
        middle = min(color1 + color2, float4(1.0,1.0,1.0,1.0));
    } else if (mode_in == 1) {
        // alpha
        if (mixAmt < 0.0) {
            return lerp(color1,
                        color2 * float4(1.0 - color1.a, 1.0 - color1.a, 1.0 - color1.a, 1.0 - color1.a)
                      + color1 * float4(color1.a, color1.a, color1.a, color1.a),
                        map_range(mixAmt, -100.0, 0.0, 0.0, 1.0)).rgb;
        } else {
            return lerp(color1 * float4(1.0 - color2.a, 1.0 - color2.a, 1.0 - color2.a, 1.0 - color2.a)
                      + color2 * float4(color2.a, color2.a, color2.a, color2.a),
                        color2,
                        map_range(mixAmt, 0.0, 100.0, 0.0, 1.0)).rgb;
        }
    } else if (mode_in == 2) {
        // color burn
        if (vec4_eq(color2, float4(0.0,0.0,0.0,0.0))) {
            middle = color2;
        } else {
            middle = max((1.0 - ((1.0 - color1) / color2)), float4(0.0,0.0,0.0,0.0));
        }
    } else if (mode_in == 3) {
        // color dodge
        if (vec4_eq(color2, float4(1.0,1.0,1.0,1.0))) {
            middle = color2;
        } else {
            middle = min(color1 / (1.0 - color2), float4(1.0,1.0,1.0,1.0));
        }
    } else if (mode_in == 4) {
        // darken
        middle = min(color1, color2);
    } else if (mode_in == 5) {
        // difference
        middle = abs(color1 - color2);
    } else if (mode_in == 6) {
        // exclusion
        middle = color1 + color2 - 2.0 * color1 * color2;
    } else if (mode_in == 7) {
        // glow
        if (vec4_eq(color2, float4(1.0,1.0,1.0,1.0))) {
            middle = color2;
        } else {
            middle = min(color1 * color1 / (1.0 - color2), float4(1.0,1.0,1.0,1.0));
        }
    } else if (mode_in == 8) {
        // hard light
        middle = float4(blendOverlay(color2.r, color1.r),
                        blendOverlay(color2.g, color1.g),
                        blendOverlay(color2.b, color1.b),
                        lerp(color1.a, color2.a, 0.5));
    } else if (mode_in == 9) {
        // lighten
        middle = max(color1, color2);
    } else if (mode_in == 10) {
        // mix
        middle = lerp(color1, color2, 0.5);
    } else if (mode_in == 11) {
        // multiply
        middle = color1 * color2;
    } else if (mode_in == 12) {
        // negation
        middle = float4(1.0,1.0,1.0,1.0) - abs(float4(1.0,1.0,1.0,1.0) - color1 - color2);
    } else if (mode_in == 13) {
        // overlay
        middle = float4(blendOverlay(color1.r, color2.r),
                        blendOverlay(color1.g, color2.g),
                        blendOverlay(color1.b, color2.b),
                        lerp(color1.a, color2.a, 0.5));
    } else if (mode_in == 14) {
        // phoenix
        middle = min(color1, color2) - max(color1, color2) + float4(1.0,1.0,1.0,1.0);
    } else if (mode_in == 15) {
        // reflect
        if (vec4_eq(color1, float4(1.0,1.0,1.0,1.0))) {
            middle = color1;
        } else {
            middle = min(color2 * color2 / (1.0 - color1), float4(1.0,1.0,1.0,1.0));
        }
    } else if (mode_in == 16) {
        // screen
        middle = 1.0 - ((1.0 - color1) * (1.0 - color2));
    } else if (mode_in == 17) {
        // soft light
        middle = float4(blendSoftLight(color1.r, color2.r),
                        blendSoftLight(color1.g, color2.g),
                        blendSoftLight(color1.b, color2.b),
                        lerp(color1.a, color2.a, 0.5));
    } else if (mode_in == 18) {
        // subtract
        middle = max(color1 + color2 - 1.0, float4(0.0,0.0,0.0,0.0));
    } else if (mode_in == 1000) {
        // hue a->b
        middle = float4(hsv2rgb(float3(b.r, a.g, a.b)), 1.0);
    } else if (mode_in == 1001) {
        // hue b->a
        middle = float4(hsv2rgb(float3(a.r, b.g, b.b)), 1.0);
    } else if (mode_in == 1002) {
        // saturation a->b
        middle = float4(hsv2rgb(float3(a.r, b.g, a.b)), 1.0);
    } else if (mode_in == 1003) {
        // saturation b->a
        middle = float4(hsv2rgb(float3(b.r, a.g, b.b)), 1.0);
    } else if (mode_in == 1004) {
        // brightness a->b
        middle = float4(hsv2rgb(float3(a.r, a.g, b.b)), 1.0);
    } else {
        // brightness b->a (mode == 1005)
        middle = float4(hsv2rgb(float3(b.r, b.g, a.b)), 1.0);
    }

    if (mode_in >= 1000) {
        middle.a = lerp(color1.a, color2.a, 0.5);
    }

    if (factor == 0.5) {
        color = middle;
    } else if (factor < 0.5) {
        factor = map_range(amt, 0.0, 0.5, 0.0, 1.0);
        color = lerp(color1, middle, factor);
    } else {
        factor = map_range(amt, 0.5, 1.0, 0.0, 1.0);
        color = lerp(middle, color2, factor);
    }

    return color.rgb;
}

// =============================================================================
// nm_coalesce — entry point called from the fragment shader.
// st: normalized UV derived from inputTex's own dimensions.
// =============================================================================
float4 nm_coalesce(float2 st)
{
    float4 color = float4(0.0, 0.0, 1.0, 1.0);

    if (blendMode == 100) {
        color = nm_coalesce_cloak(st);
    } else {
        float ra = map_range(refractAAmt, 0.0, 100.0, 0.0, 0.125);
        float rb = map_range(refractBAmt, 0.0, 100.0, 0.0, 0.125);

        float4 leftColor  = inputTex.Sample(sampler_inputTex, st);
        float4 rightColor = tex.Sample(sampler_tex, st);

        // refract a->b
        float2 leftUV  = st;
        float rightLen = length(rightColor.rgb) + refractADir / 360.0;
        leftUV.x = leftUV.x + cos(rightLen * NM_TAU) * ra;
        leftUV.y = leftUV.y + sin(rightLen * NM_TAU) * ra;

        // refract b->a
        float2 rightUV = st;
        float leftLen  = length(leftColor.rgb) + refractBDir / 360.0;
        rightUV.x = rightUV.x + cos(leftLen * NM_TAU) * rb;
        rightUV.y = rightUV.y + sin(leftLen * NM_TAU) * rb;

        float4 color1 = inputTex.Sample(sampler_inputTex, leftUV);
        float4 color2 = tex.Sample(sampler_tex, rightUV);

        color = float4(nm_blend_colors(color1, color2, blendMode, mixAmt), max(color1.a, color2.a));
    }

    return color;
}

#endif // NM_COALESCE_INCLUDED
