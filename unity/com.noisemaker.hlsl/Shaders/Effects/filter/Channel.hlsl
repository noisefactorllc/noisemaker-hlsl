#ifndef NM_CHANNEL_INCLUDED
#define NM_CHANNEL_INCLUDED

// =============================================================================
// Channel.hlsl — filter/channel, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/channel/wgsl/channel.wgsl
//
// Extracts a single RGBA channel (r=0, g=1, b=2, a=3) as grayscale, then
// applies fract(v * scale + offset).
//
// WGSL main():
//   let st = position.xy / vec2<f32>(textureDimensions(inputTex, 0));
//   let c = textureSample(inputTex, samp, st);
//   var v: f32;
//   if (channel == 0) { v = c.r; }
//   else if (channel == 1) { v = c.g; }
//   else if (channel == 2) { v = c.b; }
//   else { v = c.a; }
//   v = fract(v * scale + offset);
//   return vec4<f32>(vec3<f32>(v), 1.0);
//
// PORTING-GUIDE notes:
//  * uv divides by the INPUT TEXTURE's own dimensions (textureDimensions(inputTex,0)),
//    NOT fullResolution. Mirror that exactly with GetDimensions.
//  * channel is i32 in WGSL — declared int here.
//  * WGSL fract -> HLSL frac.
//  * No per-effect helper functions; no PRNG or math hazards.
//  * No per-effect Y flip needed (ported from WGSL, top-left canonical).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// Per-effect named uniforms (definition.js globals[*].uniform)
int   channel;  // 0=r, 1=g, 2=b, 3=a  (default: 0 = "channel.r")
float scale;    // default: 1.0
float offset;   // default: 0.0

// -----------------------------------------------------------------------------
// nm_channel — core per-pixel evaluation.
// c: sampled input color
// Returns grayscale vec4 with the selected channel value after scale+offset+frac.
// -----------------------------------------------------------------------------
float4 nm_channel(float4 c)
{
    // WGSL: if/else chain selecting one component
    float v;
    [branch]
    if (channel == 0) {
        v = c.r;
    } else if (channel == 1) {
        v = c.g;
    } else if (channel == 2) {
        v = c.b;
    } else {
        v = c.a;
    }

    // WGSL: v = fract(v * scale + offset);
    v = frac(v * scale + offset);

    // WGSL: return vec4<f32>(vec3<f32>(v), 1.0);
    return float4(v, v, v, 1.0);
}

#endif // NM_CHANNEL_INCLUDED
