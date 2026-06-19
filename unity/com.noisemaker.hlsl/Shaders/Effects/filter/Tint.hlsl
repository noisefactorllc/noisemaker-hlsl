#ifndef NM_TINT_INCLUDED
#define NM_TINT_INCLUDED

// =============================================================================
// Tint.hlsl — filter/tint, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/tint/wgsl/colorize.wgsl
//
// Colorize the input texture with a color overlay. Three modes:
//   0 overlay  (default): tinted = color
//   1 multiply          : tinted = base_rgb * color
//   2 recolor           : replace hue with the tint color's hue, keep base sat/val
// Final: rgb = mix(base_rgb, tinted, alpha); alpha channel passed through.
//
// PORTING-GUIDE notes:
//  * Single render pass (definition.js passes[].length == 1, program "colorize").
//  * rgb_to_hsv / hsv_to_rgb are this effect's OWN copies — ported VERBATIM inline
//    here, NOT hoisted to a shared color lib (PORTING-GUIDE golden rule 2; same-named
//    helpers differ per effect). Do not substitute a generic hsv conversion.
//  * uv is fragCoord / the INPUT TEXTURE's own dimensions. WGSL line 45-46:
//      let size = max(textureDimensions(inputTex, 0), vec2<u32>(1, 1));
//      let st   = position.xy / vec2<f32>(size);
//    We mirror exactly: NM_FragCoord(i) (top-left, +0.5) divided by the input tex
//    size, clamped to a minimum of (1,1). tileOffset does NOT enter the sample uv
//    (the WGSL does not add it; H8 handled by NMFullscreen top-left UV — no flip).
//  * mode: WGSL declares `mode: f32` and does `let m = i32(mode)` (truncate toward
//    zero). definition.js types it `int` with choices {overlay:0,multiply:1,
//    recolor:2}. We declare an `int` uniform — exact for the non-negative values.
//    Branch with [branch] to mirror the WGSL if/else chain.
//  * color: vec3 uniform (RGB, linear, non-sRGB). alpha: f32 uniform.
//  * No PRNG / no atan2 / no select in this effect — no bit hazards.
//  * Linear, clamp-to-edge, non-sRGB sampler (H7) — set on the SamplerState in
//    Tint.shader / supplied by the Shader Graph node.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
// Bound by the runtime via MaterialPropertyBlock under these exact names.
float3 color;   // globals.color.uniform "color",  default (1,1,1)
float  alpha;   // globals.alpha.uniform "alpha",  default 0.5
int    mode;    // globals.mode.uniform  "mode",   default 0 (overlay)

// -----------------------------------------------------------------------------
// rgb_to_hsv — ported VERBATIM from colorize.wgsl (rgb_to_hsv). Per-effect copy.
// WGSL:
//   let r = rgb.x; let g = rgb.y; let b = rgb.z;
//   let max_c = max(max(r, g), b);
//   let min_c = min(min(r, g), b);
//   let delta = max_c - min_c;
//   var hue = 0.0;
//   if (delta != 0.0) {
//       if (max_c == r) {
//           var raw = (g - b) / delta;
//           raw = raw - floor(raw / 6.0) * 6.0;
//           if (raw < 0.0) { raw = raw + 6.0; }
//           hue = raw;
//       } else if (max_c == g) { hue = (b - r) / delta + 2.0; }
//       else { hue = (r - g) / delta + 4.0; }
//   }
//   hue = hue / 6.0;
//   if (hue < 0.0) { hue = hue + 1.0; }
//   var sat = 0.0;
//   if (max_c != 0.0) { sat = delta / max_c; }
//   return vec3<f32>(hue, sat, max_c);
// -----------------------------------------------------------------------------
float3 rgb_to_hsv(float3 rgb)
{
    float r = rgb.x; float g = rgb.y; float b = rgb.z;
    float max_c = max(max(r, g), b);
    float min_c = min(min(r, g), b);
    float delta = max_c - min_c;
    float hue = 0.0;
    if (delta != 0.0) {
        if (max_c == r) {
            float raw = (g - b) / delta;
            raw = raw - floor(raw / 6.0) * 6.0;
            if (raw < 0.0) { raw = raw + 6.0; }
            hue = raw;
        } else if (max_c == g) {
            hue = (b - r) / delta + 2.0;
        } else {
            hue = (r - g) / delta + 4.0;
        }
    }
    hue = hue / 6.0;
    if (hue < 0.0) { hue = hue + 1.0; }
    float sat = 0.0;
    if (max_c != 0.0) { sat = delta / max_c; }
    return float3(hue, sat, max_c);
}

// -----------------------------------------------------------------------------
// hsv_to_rgb — ported VERBATIM from colorize.wgsl (hsv_to_rgb). Per-effect copy.
// WGSL:
//   let h = hsv.x; let s = hsv.y; let v = hsv.z;
//   let dh = h * 6.0;
//   let dr = clamp(abs(dh - 3.0) - 1.0, 0.0, 1.0);
//   let dg = clamp(-abs(dh - 2.0) + 2.0, 0.0, 1.0);
//   let db = clamp(-abs(dh - 4.0) + 2.0, 0.0, 1.0);
//   let oms = 1.0 - s;
//   return vec3<f32>((oms + s * dr) * v, (oms + s * dg) * v, (oms + s * db) * v);
// -----------------------------------------------------------------------------
float3 hsv_to_rgb(float3 hsv)
{
    float h = hsv.x; float s = hsv.y; float v = hsv.z;
    float dh = h * 6.0;
    float dr = clamp(abs(dh - 3.0) - 1.0, 0.0, 1.0);
    float dg = clamp(-abs(dh - 2.0) + 2.0, 0.0, 1.0);
    float db = clamp(-abs(dh - 4.0) + 2.0, 0.0, 1.0);
    float oms = 1.0 - s;
    return float3((oms + s * dr) * v, (oms + s * dg) * v, (oms + s * db) * v);
}

// -----------------------------------------------------------------------------
// nm_tint — core per-pixel evaluation. Takes the already-sampled base color and
// returns the tinted RGBA. Pure function so the Shader Graph wrapper and the
// render pass share identical math. Ported VERBATIM from colorize.wgsl main().
//   let base_rgb = clamp(base.rgb, vec3<f32>(0.0), vec3<f32>(1.0));
//   let m = i32(mode);
//   ... (overlay / multiply / recolor) ...
//   let rgb = mix(base_rgb, tinted, vec3<f32>(alpha));
//   return vec4<f32>(rgb, base.a);
// -----------------------------------------------------------------------------
float4 nm_tint(float4 base)
{
    float3 base_rgb = clamp(base.rgb, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));

    int m = (int)mode;   // WGSL: i32(mode) — truncate toward zero.
    float3 tinted;
    [branch]
    if (m == 1) {
        // Multiply
        tinted = base_rgb * color;
    } else if (m == 2) {
        // Recolor: replace hue with tint color's hue
        float tintHue = rgb_to_hsv(color).x;
        float3 base_hsv = rgb_to_hsv(base_rgb);
        tinted = clamp(hsv_to_rgb(float3(tintHue, clamp(base_rgb.y, 0.0, 1.0), clamp(base_hsv.z, 0.0, 1.0))), float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
    } else {
        // Overlay (default)
        tinted = color;
    }

    float3 rgb = lerp(base_rgb, tinted, float3(alpha, alpha, alpha));
    return float4(rgb, base.a);
}

#endif // NM_TINT_INCLUDED
