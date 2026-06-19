#ifndef NM_INVERT_INCLUDED
#define NM_INVERT_INCLUDED

// =============================================================================
// Invert.hlsl — filter/invert, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/invert/wgsl/inv.wgsl
//
// Simple RGB inversion: out.rgb = 1.0 - color.rgb, alpha passed through.
//
// WGSL main():
//   let texSize = vec2<f32>(textureDimensions(inputTex));
//   let uv      = pos.xy / texSize;                 // pos = @builtin(position), top-left
//   var color   = textureSample(inputTex, inputSampler, uv);
//   color = vec4<f32>(1.0 - color.rgb, color.a);
//   return color;
//
// PORTING-GUIDE notes:
//  * No per-effect params (definition.js globals: {}). Nothing to declare here.
//  * uv is fragCoord / the INPUT TEXTURE's own dimensions (the WGSL divides by
//    textureDimensions(inputTex), NOT by fullResolution). We mirror that exactly:
//    NM_FragCoord(i) (top-left, +0.5 centered) divided by the input tex size.
//    The GLSL computes a globalCoord (fragCoord + tileOffset) but does NOT use it
//    for the sample uv — it samples with gl_FragCoord.xy / textureSize. WGSL is
//    canonical, so tileOffset does not enter the sample coordinate. (H8 handled by
//    NMFullscreen's top-left UV; no per-effect flip needed.)
//  * No PRNG / no math hazards in this effect.
//  * Linear, clamp-to-edge, non-sRGB sampler (H7) — set on the SamplerState in
//    Invert.shader / supplied by the Shader Graph node.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// No per-effect named uniforms (definition.js globals: {}).

// -----------------------------------------------------------------------------
// nm_invert — core per-pixel evaluation. Takes the already-sampled input color
// and returns the inverted RGBA. Kept as a pure function so the Shader Graph
// wrapper and the render pass share identical math.
// -----------------------------------------------------------------------------
float4 nm_invert(float4 color)
{
    // WGSL: color = vec4<f32>(1.0 - color.rgb, color.a);
    return float4(1.0 - color.rgb, color.a);
}

#endif // NM_INVERT_INCLUDED
