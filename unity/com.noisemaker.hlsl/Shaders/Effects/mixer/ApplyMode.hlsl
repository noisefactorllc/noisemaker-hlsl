#ifndef NM_APPLYMODE_INCLUDED
#define NM_APPLYMODE_INCLUDED

// =============================================================================
// ApplyMode.hlsl — mixer/applyMode, ported PIXEL-IDENTICALLY from the canonical
// WGSL:  shaders/effects/mixer/applyMode/wgsl/applyMode.wgsl
//
// Apply brightness, hue, or saturation from source B (tex) to source A
// (inputTex), then cross-fade with a single `mixAmt` slider. Single render
// pass (definition.js passes[0], program "applyMode").
//
// PORTING-GUIDE notes:
//  * rgb2hsv / hsv2rgb are this effect's OWN copies — ported VERBATIM inline
//    here, NOT hoisted to NMCore (golden rule 2). The WGSL uses branching
//    if/else for rgb2hsv (NOT the GLSL step()-based version); we reproduce
//    the WGSL form exactly.
//  * map_range is also this effect's own local copy (same math as nm_map but
//    the WGSL ships its own local fn; we keep it inline to mirror source 1:1).
//  * `mode`: WGSL declares `mode : i32` uniform with 3 values (0 brightness,
//    1 hue, 2 saturation). Declared as `int mode`; if/else chain verbatim.
//  * `mixAmt`: WGSL `mixAmt : f32` uniform. definition.js key is `mix` with
//    uniform name `mixAmt` (paramAliases.mixAmt = 'mix'). Declared as
//    `float mixAmt`.
//  * uv: WGSL line 38-39 divides position.xy by inputTex's own dimensions:
//        let dims = vec2<f32>(textureDimensions(inputTex, 0));
//        var st   = position.xy / dims;
//    Same `st` samples BOTH textures. tileOffset is NOT added.
//  * Alpha: WGSL line 71 sets `color.a = max(color1.a, color2.a)` — verbatim.
//    This differs from BlendMode's Porter-Duff alpha; reproduce as written.
//  * No PRNG / no nm_mod / no atan2 / no select — no bit hazards.
//  * Full 32-bit float (parity requirement H4). No half/min16float.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
int   mode;     // globals.mode.uniform "mode",   default 0 (brightness)
float mixAmt;   // globals.mix.uniform  "mixAmt",  default 0

// -----------------------------------------------------------------------------
// map_range — ported VERBATIM from applyMode.wgsl. Per-effect copy.
// WGSL: return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
// -----------------------------------------------------------------------------
float map_range(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

// -----------------------------------------------------------------------------
// rgb2hsv — ported VERBATIM from applyMode.wgsl. Per-effect copy.
// Uses if/else branching form (WGSL canonical). The GLSL uses step()-based
// branchless form — we use the WGSL form per porting rules.
// WGSL:
//   let K = vec4<f32>(0.0, -1.0/3.0, 2.0/3.0, -1.0);
//   var p : vec4<f32>;
//   if (c.b > c.g) { p = vec4<f32>(c.bg, K.wz); } else { p = vec4<f32>(c.gb, K.xy); }
//   var q : vec4<f32>;
//   if (p.x > c.r) { q = vec4<f32>(p.xyw, c.r); } else { q = vec4<f32>(c.r, p.yzx); }
//   let d = q.x - min(q.w, q.y);
//   let e = 1.0e-10;
//   return vec3<f32>(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
// -----------------------------------------------------------------------------
float3 rgb2hsv(float3 c)
{
    float4 K = float4(0.0, -1.0/3.0, 2.0/3.0, -1.0);
    float4 p;
    if (c.b > c.g) {
        p = float4(c.b, c.g, K.w, K.z);
    } else {
        p = float4(c.g, c.b, K.x, K.y);
    }
    float4 q;
    if (p.x > c.r) {
        q = float4(p.x, p.y, p.w, c.r);
    } else {
        q = float4(c.r, p.y, p.z, p.x);
    }
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

// -----------------------------------------------------------------------------
// hsv2rgb — ported VERBATIM from applyMode.wgsl. Per-effect copy.
// WGSL:
//   let K = vec4<f32>(1.0, 2.0/3.0, 1.0/3.0, 3.0);
//   let p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
//   return c.z * mix(K.xxx, clamp(p - K.xxx, vec3<f32>(0.0), vec3<f32>(1.0)), c.y);
// -----------------------------------------------------------------------------
float3 hsv2rgb(float3 c)
{
    float4 K = float4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
    float3 p = abs(frac(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * lerp(K.xxx, clamp(p - K.xxx, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0)), c.y);
}

// -----------------------------------------------------------------------------
// nm_applyMode — core per-pixel evaluation. Takes two already-sampled input
// colors (color1 = inputTex/A, color2 = tex/B) and returns the blended RGBA.
// Ported VERBATIM from applyMode.wgsl main() lines 44-72.
// -----------------------------------------------------------------------------
float4 nm_applyMode(float4 color1, float4 color2)
{
    float3 a = rgb2hsv(color1.rgb);
    float3 b = rgb2hsv(color2.rgb);
    float3 resultHSV;

    if (mode == 0) {
        // brightness: hue/sat from A, value from B
        resultHSV = float3(a.x, a.y, b.z);
    } else if (mode == 1) {
        // hue: hue from B, sat/value from A
        resultHSV = float3(b.x, a.y, a.z);
    } else {
        // saturation: hue/value from A, saturation from B
        resultHSV = float3(a.x, b.y, a.z);
    }

    float4 middle = float4(hsv2rgb(resultHSV), 1.0);

    float amt = map_range(mixAmt, -100.0, 100.0, 0.0, 1.0);
    float4 color;
    if (amt < 0.5) {
        float factor = amt * 2.0;
        color = lerp(color1, middle, factor);
    } else {
        float factor = (amt - 0.5) * 2.0;
        color = lerp(middle, color2, factor);
    }

    color.a = max(color1.a, color2.a);
    return color;
}

#endif // NM_APPLYMODE_INCLUDED
