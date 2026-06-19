#ifndef NM_NORMALIZE_INCLUDED
#define NM_NORMALIZE_INCLUDED

// =============================================================================
// Normalize.hlsl — filter/normalize, ported PIXEL-IDENTICALLY from canonical WGSL:
//   shaders/effects/filter/normalize/wgsl/{reduce,reduceMinmax,statsFinal,apply}.wgsl
//
// Multi-pass GPGPU value normalization:
//   1. reduce       : 16:1 pyramid reduction of the source; .r=min RGB, .g=max RGB
//   2. reduceMinmax : 16:1 reduction of the min/max texture
//   3. statsFinal   : full scan of the input down to a single 1x1 min/max
//   4. apply        : normalize each pixel using the global stats
//
// PORTING-GUIDE notes:
//  * No per-effect params (definition.js globals: {}). Nothing to declare here.
//  * The WGSL uses textureLoad(t, vec2<i32>(coord), 0) — an INTEGER texel fetch,
//    NOT a sampled lookup. HLSL analog is t.Load(int3(x, y, 0)). No sampler/uv is
//    used in any pass (so no divide-by-dimensions, no tileOffset).
//  * out pixel coord = vec2<i32>(input.position.xy). position.xy is top-left,
//    +0.5 centered; (int)(px+0.5) == px. NM_FragCoord(i) is the HLSL analog; we
//    truncate to int to match vec2<i32>(...).
//  * textureDimensions(t) -> t.GetDimensions(w, h) (unsigned), cast to int.
//  * Linear half-float render targets (rgba16f); .Load reads raw texels, no sRGB.
//  * Full 32-bit float. No reassociation.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// No per-effect named uniforms (definition.js globals: {}).

#endif // NM_NORMALIZE_INCLUDED
