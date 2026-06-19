#ifndef NM_BC_INCLUDED
#define NM_BC_INCLUDED

// =============================================================================
// Bc.hlsl — filter/bc, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/bc/wgsl/bc.wgsl
//
// Brightness and Contrast adjustment (deprecated; use filter/adjust instead).
//
// WGSL main():
//   let brightness = uniforms.data[0].x;
//   let contrast   = uniforms.data[0].y;
//   let texSize    = vec2<f32>(textureDimensions(inputTex));
//   let uv         = pos.xy / texSize;
//   var color      = textureSample(inputTex, inputSampler, uv);
//   color = vec4<f32>(color.rgb * brightness, color.a);
//   let contrastFactor = contrast * 2.0;
//   color = vec4<f32>((color.rgb - 0.5) * contrastFactor + 0.5, color.a);
//   return color;
//
// PORTING-GUIDE notes:
//  * uv = fragCoord / textureDimensions(inputTex) — INPUT texture dimensions,
//    NOT fullResolution. Mirrored exactly via NM_FragCoord(i) / texSize.
//  * No helpers beyond standard arithmetic; no pcg/prng needed.
//  * Full 32-bit float only; no half promotion.
//  * brightness uniform: definition.js default 1, range [0,10].
//  * contrast  uniform: definition.js default 0.5, range [0,1].
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// Per-effect named uniforms (definition.js globals).
float brightness;   // default 1, min 0, max 10
float contrast;     // default 0.5, min 0, max 1

// -----------------------------------------------------------------------------
// nm_bc — core per-pixel evaluation.
// color : already-sampled RGBA from inputTex.
// -----------------------------------------------------------------------------
float4 nm_bc(float4 color)
{
    // Apply brightness (multiply).
    // WGSL: color = vec4<f32>(color.rgb * brightness, color.a);
    color = float4(color.rgb * brightness, color.a);

    // Apply contrast (0..1 -> 0..2).
    // WGSL: let contrastFactor = contrast * 2.0;
    //       color = vec4<f32>((color.rgb - 0.5) * contrastFactor + 0.5, color.a);
    float contrastFactor = contrast * 2.0;
    color = float4((color.rgb - 0.5) * contrastFactor + 0.5, color.a);

    return color;
}

#endif // NM_BC_INCLUDED
