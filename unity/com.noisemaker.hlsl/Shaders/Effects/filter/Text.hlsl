#ifndef NM_TEXT_INCLUDED
#define NM_TEXT_INCLUDED

// =============================================================================
// Text.hlsl — filter/text, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/text/wgsl/text.wgsl
//
// Blends a CPU-rendered text texture (textTex, RGBA, canvas alpha) over the
// input image, with an optional matte background.
//
// WGSL main():
//   let size = max(textureDimensions(inputTex, 0), vec2<u32>(1, 1));
//   let uv = position.xy / vec2<f32>(size);
//   let inputColor = textureSample(inputTex, texSampler, uv);
//   let text       = textureSample(textTex,  texSampler, uv);
//   let textPresence = text.a;
//   let matteAlpha   = matteOpacity;
//   let rgb = text.rgb * textPresence
//           + inputColor.rgb * (1.0 - textPresence) * (1.0 - matteAlpha)
//           + matteColor * matteAlpha * (1.0 - textPresence);
//   let alpha = max(textPresence, mix(inputColor.a, 1.0, matteAlpha));
//   return vec4<f32>(rgb, alpha);
//
// PORTING-GUIDE notes:
//  * Two input textures: inputTex (the scene) and textTex (CPU-rendered text).
//  * uv = fragCoord / inputTex dimensions (WGSL divides by textureDimensions of
//    inputTex, NOT fullResolution). textTex is sampled at the same uv.
//  * matteColor is vec3<f32> uniform; matteOpacity is f32 uniform.
//  * No PRNG / no per-effect math helpers. mix -> lerp.
//  * Linear, clamp-to-edge, non-sRGB sampler for both textures.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// Per-effect named uniforms (definition.js globals with explicit "uniform" field)
float3 matteColor;    // uniform "matteColor", default #000000 -> float3(0,0,0)
float  matteOpacity;  // uniform "matteOpacity", default 0.0

// -----------------------------------------------------------------------------
// nm_text — core composite. Kept as a pure function so the render pass and any
// future Shader Graph wrapper share identical math.
// -----------------------------------------------------------------------------
float4 nm_text(float4 inputColor, float4 text, float3 mColor, float mOpacity)
{
    float textPresence = text.a;
    float matteAlpha   = mOpacity;

    // WGSL:
    // rgb = text.rgb * textPresence
    //     + inputColor.rgb * (1.0 - textPresence) * (1.0 - matteAlpha)
    //     + matteColor * matteAlpha * (1.0 - textPresence);
    float3 rgb = text.rgb * textPresence
               + inputColor.rgb * (1.0 - textPresence) * (1.0 - matteAlpha)
               + mColor * matteAlpha * (1.0 - textPresence);

    // WGSL: alpha = max(textPresence, mix(inputColor.a, 1.0, matteAlpha));
    float alpha = max(textPresence, lerp(inputColor.a, 1.0, matteAlpha));

    return float4(rgb, alpha);
}

#endif // NM_TEXT_INCLUDED
