#ifndef NM_PIXELS_INCLUDED
#define NM_PIXELS_INCLUDED

// =============================================================================
// Pixels.hlsl — filter/pixels, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/pixels/wgsl/pixels.wgsl
//
// Pixelation effect: reduces image resolution for retro pixel art look.
// Tile-aware: pixel grid is computed in global coordinates so blocks align
// across tiles. The non-tiling branch (tileOffset == (0,0)) is byte-identical
// to the simple prior version.
//
// WGSL main() summary:
//   let texSize = vec2<f32>(textureDimensions(inputTex));
//   let uv = pos.xy / texSize;
//   if (uniforms.size < 1.0) { return textureSample(inputTex, inputSampler, uv); }
//   let pixelSize = uniforms.size;
//   let isTile = length(uniforms.tileOffset) > 0.0;
//   if (isTile) {
//     let resolution = select(texSize, uniforms.fullResolution, uniforms.fullResolution.x > 0.0);
//     let dx = pixelSize / resolution.x;
//     let dy = pixelSize / resolution.y;
//     let globalUV = (pos.xy + uniforms.tileOffset) / resolution;
//     let centered = globalUV - 0.5;
//     var gcoord = vec2<f32>(dx * floor(centered.x / dx), dy * floor(centered.y / dy));
//     gcoord = gcoord + 0.5;
//     let coord = (gcoord * resolution - uniforms.tileOffset) / texSize;
//     return textureSample(inputTex, inputSampler, coord);
//   }
//   // Non-tiling path
//   let dx = pixelSize / texSize.x;
//   let dy = pixelSize / texSize.y;
//   var centered = uv - 0.5;
//   var coord = vec2<f32>(dx * floor(centered.x / dx), dy * floor(centered.y / dy));
//   coord = coord + 0.5;
//   return textureSample(inputTex, inputSampler, coord);
//
// PORTING-GUIDE notes:
//  * Per-effect uniform: int size (definition.js globals.size.uniform = "size").
//  * tileOffset and fullResolution come from NMFullscreen.hlsl engine globals.
//  * uv = fragCoord / inputTex dimensions (WGSL divides by textureDimensions, NOT
//    fullResolution). NM_FragCoord(i) is top-left +0.5 centered, matching WGSL pos.xy.
//  * WGSL select(false_val, true_val, cond) — reversed from C ternary. Translated:
//      select(texSize, uniforms.fullResolution, uniforms.fullResolution.x > 0.0)
//      => (uniforms.fullResolution.x > 0.0) ? uniforms.fullResolution : texSize
//  * isTile = length(tileOffset) > 0.0: use float length, literal comparison.
//  * nm_mod not used here; floor-based quantization uses HLSL floor directly
//    (no negative-value hazard in this context).
//  * No PRNG / no shared color helpers needed.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// Per-effect named uniform (definition.js globals.size.uniform = "size").
// Declared int to match definition type; the WGSL stores it as f32 in the
// packed array but the value is always a whole number in [1,256].
int size;

#endif // NM_PIXELS_INCLUDED
