#ifndef NM_CHROMA_INCLUDED
#define NM_CHROMA_INCLUDED

// =============================================================================
// Chroma.hlsl — filter/chroma, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/chroma/wgsl/chroma.wgsl
//
// Isolate a specific hue range from the input texture. Outputs a mono mask
// (value = mask in RGB, alpha passed through).
//
// WGSL main():
//   let texSize = vec2<f32>(textureDimensions(inputTex));
//   let uv = pos.xy / texSize;
//   let color = textureSample(inputTex, inputSampler, uv);
//   let hsv = rgb2hsv(color.rgb);
//   let dist = hueDistance(hsv.x, targetHue);
//   var mask = 1.0 - smoothstep(inner, outer, dist);
//   mask *= sat;
//   return vec4<f32>(vec3<f32>(mask), color.a);
//
// PORTING-GUIDE notes:
//  * Three per-effect float uniforms: targetHue, range, feather.
//  * uv is fragCoord / the INPUT TEXTURE's own dimensions (WGSL divides by
//    textureDimensions(inputTex), NOT fullResolution). NM_FragCoord(i) (top-left,
//    +0.5) divided by input tex size. tileOffset does NOT enter the sample coord.
//  * rgb2hsv and hueDistance are this effect's OWN copies — ported VERBATIM inline.
//    Do not substitute any shared color helper.
//  * No PRNG / no atan2 / no select in this effect — no bit hazards.
//  * Linear, clamp-to-edge, non-sRGB sampler (H7) — set on the SamplerState in
//    Chroma.shader / supplied by the Shader Graph node.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
float targetHue;  // globals.targetHue.uniform "targetHue",  default 0.33
float range;      // globals.range.uniform     "range",      default 0.25
float feather;    // globals.feather.uniform   "feather",    default 0.05

// -----------------------------------------------------------------------------
// rgb2hsv — ported VERBATIM from chroma.wgsl. Per-effect copy.
// WGSL:
//   let K = vec4<f32>(0.0, -1.0/3.0, 2.0/3.0, -1.0);
//   let p = mix(vec4<f32>(c.bg, K.wz), vec4<f32>(c.gb, K.xy), step(c.b, c.g));
//   let q = mix(vec4<f32>(p.xyw, c.r), vec4<f32>(c.r, p.yzx), step(p.x, c.r));
//   let d = q.x - min(q.w, q.y);
//   let e = 1.0e-10;
//   return vec3<f32>(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
// -----------------------------------------------------------------------------
float3 rgb2hsv(float3 c)
{
    float4 K = float4(0.0, -1.0/3.0, 2.0/3.0, -1.0);
    float4 p = lerp(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = lerp(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

// -----------------------------------------------------------------------------
// hueDistance — ported VERBATIM from chroma.wgsl. Per-effect copy.
// WGSL:
//   let d = abs(h1 - h2);
//   return min(d, 1.0 - d);
// -----------------------------------------------------------------------------
float hueDistance(float h1, float h2)
{
    float d = abs(h1 - h2);
    return min(d, 1.0 - d);
}

// -----------------------------------------------------------------------------
// nm_chroma — core per-pixel evaluation. Takes the already-sampled input color
// and returns the chroma-masked RGBA. Pure function so the Shader Graph wrapper
// and the render pass share identical math. Ported VERBATIM from chroma.wgsl main().
//   let hsv = rgb2hsv(color.rgb);
//   let hue = hsv.x; let sat = hsv.y;
//   let dist = hueDistance(hue, targetHue);
//   let inner = range; let outer = range + feather;
//   var mask = 1.0 - smoothstep(inner, outer, dist);
//   mask *= sat;
//   return vec4<f32>(vec3<f32>(mask), color.a);
// -----------------------------------------------------------------------------
float4 nm_chroma(float4 color)
{
    float3 hsv = rgb2hsv(color.rgb);
    float hue = hsv.x;
    float sat = hsv.y;

    float dist = hueDistance(hue, targetHue);

    // Apply range and feather to create smooth mask
    float inner = range;
    float outer = range + feather;
    float mask = 1.0 - smoothstep(inner, outer, dist);

    // Scale by saturation - desaturated colors don't have meaningful hue
    mask *= sat;

    return float4(mask, mask, mask, color.a);
}

#endif // NM_CHROMA_INCLUDED
