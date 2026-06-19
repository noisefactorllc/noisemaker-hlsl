#ifndef NM_HS_INCLUDED
#define NM_HS_INCLUDED

// =============================================================================
// Hs.hlsl — filter/hs, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/hs/wgsl/hs.wgsl
//
// Hue rotation and saturation adjustment.
//
// WGSL main():
//   let rotation   = uniforms.data[0].x;
//   let hueRange   = uniforms.data[0].y;
//   let saturation = uniforms.data[0].z;
//   let texSize = vec2<f32>(textureDimensions(inputTex));
//   let uv = pos.xy / texSize;
//   var color = textureSample(inputTex, inputSampler, uv);
//   var hsv = rgb2hsv(color.rgb);
//   hsv.x = fract(hsv.x * mapVal(hueRange, 0.0, 200.0, 0.0, 2.0) + (rotation / 360.0));
//   hsv.y = hsv.y * saturation;
//   color = vec4<f32>(hsv2rgb(hsv), color.a);
//   return color;
//
// PORTING-GUIDE notes:
//  * uv is fragCoord / the INPUT TEXTURE's own dimensions (WGSL divides by
//    textureDimensions(inputTex), NOT fullResolution). Mirror exactly.
//  * rgb2hsv / hsv2rgb / floorMod / mapVal are THIS effect's own per-effect helpers —
//    ported VERBATIM inline. Do not substitute a shared/generic version (golden rule 2).
//  * floorMod is nm_mod equivalent here but implemented inline as x - y*floor(x/y);
//    matches the WGSL floorMod exactly.
//  * No PRNG / no atan2 / no select in this effect — no bit hazards.
//  * Full 32-bit float; no half/min16float (H4).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
float rotation;    // globals.rotation.uniform "rotation",   default 0,   min -180, max 180
float hueRange;    // globals.hueRange.uniform "hueRange",   default 100, min 0,    max 200
float saturation;  // globals.saturation.uniform "saturation", default 1, min 0,    max 4

// -----------------------------------------------------------------------------
// floorMod — per-effect helper, ported VERBATIM from hs.wgsl.
// WGSL: fn floorMod(x: f32, y: f32) -> f32 { return x - y * floor(x / y); }
// -----------------------------------------------------------------------------
float hs_floorMod(float x, float y)
{
    return x - y * floor(x / y);
}

// -----------------------------------------------------------------------------
// mapVal — per-effect helper, ported VERBATIM from hs.wgsl.
// WGSL: fn mapVal(value: f32, inMin: f32, inMax: f32, outMin: f32, outMax: f32) -> f32 {
//           return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
//       }
// -----------------------------------------------------------------------------
float hs_mapVal(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

// -----------------------------------------------------------------------------
// rgb2hsv — per-effect helper, ported VERBATIM from hs.wgsl.
// WGSL:
//   let r = rgb.r; let g = rgb.g; let b = rgb.b;
//   let maxC = max(r, max(g, b));
//   let minC = min(r, min(g, b));
//   let delta = maxC - minC;
//   var h = 0.0;
//   if (delta != 0.0) {
//       if (maxC == r) { h = floorMod((g - b) / delta, 6.0) / 6.0; }
//       else if (maxC == g) { h = ((b - r) / delta + 2.0) / 6.0; }
//       else { h = ((r - g) / delta + 4.0) / 6.0; }
//   }
//   var s = 0.0;
//   if (maxC != 0.0) { s = delta / maxC; }
//   return vec3<f32>(h, s, maxC);
// -----------------------------------------------------------------------------
float3 hs_rgb2hsv(float3 rgb)
{
    float r = rgb.r; float g = rgb.g; float b = rgb.b;
    float maxC = max(r, max(g, b));
    float minC = min(r, min(g, b));
    float delta = maxC - minC;

    float h = 0.0;
    if (delta != 0.0) {
        if (maxC == r) {
            h = hs_floorMod((g - b) / delta, 6.0) / 6.0;
        } else if (maxC == g) {
            h = ((b - r) / delta + 2.0) / 6.0;
        } else {
            h = ((r - g) / delta + 4.0) / 6.0;
        }
    }
    float s = 0.0;
    if (maxC != 0.0) { s = delta / maxC; }
    return float3(h, s, maxC);
}

// -----------------------------------------------------------------------------
// hsv2rgb — per-effect helper, ported VERBATIM from hs.wgsl.
// WGSL:
//   let h = fract(hsv.x);
//   let s = hsv.y;
//   let v = hsv.z;
//   let c = v * s;
//   let x = c * (1.0 - abs(floorMod(h * 6.0, 2.0) - 1.0));
//   let m = v - c;
//   var rgb: vec3<f32>;
//   if (h < 1.0/6.0) { rgb = vec3<f32>(c, x, 0.0); }
//   else if (h < 2.0/6.0) { rgb = vec3<f32>(x, c, 0.0); }
//   else if (h < 3.0/6.0) { rgb = vec3<f32>(0.0, c, x); }
//   else if (h < 4.0/6.0) { rgb = vec3<f32>(0.0, x, c); }
//   else if (h < 5.0/6.0) { rgb = vec3<f32>(x, 0.0, c); }
//   else { rgb = vec3<f32>(c, 0.0, x); }
//   return rgb + m;
// -----------------------------------------------------------------------------
float3 hs_hsv2rgb(float3 hsv)
{
    float h = frac(hsv.x);
    float s = hsv.y;
    float v = hsv.z;
    float c = v * s;
    float x = c * (1.0 - abs(hs_floorMod(h * 6.0, 2.0) - 1.0));
    float m = v - c;
    float3 rgb;
    if (h < 1.0/6.0) { rgb = float3(c, x, 0.0); }
    else if (h < 2.0/6.0) { rgb = float3(x, c, 0.0); }
    else if (h < 3.0/6.0) { rgb = float3(0.0, c, x); }
    else if (h < 4.0/6.0) { rgb = float3(0.0, x, c); }
    else if (h < 5.0/6.0) { rgb = float3(x, 0.0, c); }
    else { rgb = float3(c, 0.0, x); }
    return rgb + m;
}

// -----------------------------------------------------------------------------
// nm_hs — core per-pixel evaluation. Ported VERBATIM from hs.wgsl main().
// Takes the already-sampled input color plus the three uniforms (pulled from
// globals) and returns the hue/saturation-adjusted RGBA.
// -----------------------------------------------------------------------------
float4 nm_hs(float4 color)
{
    // WGSL: var hsv = rgb2hsv(color.rgb);
    float3 hsv = hs_rgb2hsv(color.rgb);

    // WGSL: hsv.x = fract(hsv.x * mapVal(hueRange, 0.0, 200.0, 0.0, 2.0) + (rotation / 360.0));
    hsv.x = frac(hsv.x * hs_mapVal(hueRange, 0.0, 200.0, 0.0, 2.0) + (rotation / 360.0));

    // WGSL: hsv.y = hsv.y * saturation;
    hsv.y = hsv.y * saturation;

    // WGSL: color = vec4<f32>(hsv2rgb(hsv), color.a);
    return float4(hs_hsv2rgb(hsv), color.a);
}

#endif // NM_HS_INCLUDED
