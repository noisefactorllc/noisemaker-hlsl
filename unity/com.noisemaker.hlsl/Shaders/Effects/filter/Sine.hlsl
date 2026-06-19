#ifndef NM_SINE_INCLUDED
#define NM_SINE_INCLUDED

// =============================================================================
// Sine.hlsl — filter/sine, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/sine/wgsl/sine.wgsl
//
// Applies a normalized sine curve to image channels.
// RGB mode: distort R, G, B independently.
// Non-RGB mode: convert to luminance, apply sine, output grayscale.
//
// WGSL main():
//   let amount   = uniforms.amount;
//   let use_rgb  = uniforms.colorMode > 0.5;
//   let texSize  = vec2<f32>(textureDimensions(inputTex));
//   let uv       = pos.xy / texSize;
//   var color    = textureSample(inputTex, inputSampler, uv);
//   if (use_rgb) {
//       color.r = normalized_sine(color.r * amount);
//       color.g = normalized_sine(color.g * amount);
//       color.b = normalized_sine(color.b * amount);
//   } else {
//       let lum    = 0.299 * color.r + 0.587 * color.g + 0.114 * color.b;
//       let result = normalized_sine(lum * amount);
//       color      = vec4<f32>(result, result, result, color.a);
//   }
//   return color;
//
// PORTING-GUIDE notes:
//  * colorMode is declared float in the WGSL Uniforms struct (f32). We declare
//    it float here and compare > 0.5, exactly matching WGSL (not > 0 like int).
//  * uv = fragCoord / textureDimensions(inputTex) — INPUT texture's own size,
//    NOT fullResolution. Mirrors WGSL literally.
//  * No PRNG / no shared helpers beyond what NMFullscreen provides.
//  * Linear, clamp-to-edge, non-sRGB sampler (H7).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// Per-effect named uniforms (definition.js globals).
float amount;      // default 7, range [0, 20]
float colorMode;   // default 1 (rgb=1, mono=0); WGSL stores as f32, compare > 0.5

// -----------------------------------------------------------------------------
// normalized_sine — WGSL: (sin(value) + 1.0) * 0.5
// -----------------------------------------------------------------------------
float normalized_sine(float value)
{
    return (sin(value) + 1.0) * 0.5;
}

// -----------------------------------------------------------------------------
// nm_sine — core per-pixel evaluation, verbatim from WGSL main().
// -----------------------------------------------------------------------------
float4 nm_sine(float4 color)
{
    bool use_rgb = colorMode > 0.5;

    [branch]
    if (use_rgb)
    {
        color.r = normalized_sine(color.r * amount);
        color.g = normalized_sine(color.g * amount);
        color.b = normalized_sine(color.b * amount);
    }
    else
    {
        float lum    = 0.299 * color.r + 0.587 * color.g + 0.114 * color.b;
        float result = normalized_sine(lum * amount);
        color = float4(result, result, result, color.a);
    }

    return color;
}

#endif // NM_SINE_INCLUDED
