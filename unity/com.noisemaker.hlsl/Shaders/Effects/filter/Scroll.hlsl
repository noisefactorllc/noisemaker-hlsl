#ifndef NM_SCROLL_INCLUDED
#define NM_SCROLL_INCLUDED

// =============================================================================
// Scroll.hlsl — filter/scroll, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/scroll/wgsl/scroll.wgsl
//
// Scrolls texture coordinates with wraparound (mirror / repeat / clamp).
//
// WGSL main():
//   var st = position.xy / resolution;
//   st.x *= aspect;
//   var offset = vec2<f32>(-x + time * -speedX, y + time * speedY);
//   offset.x *= aspect;
//   st += offset;
//   st.x /= aspect;
//   // apply wrap mode (% is WGSL positive-modulo = nm_mod equivalent)
//   if (wrap == 0)  { st = abs(((st + 1.0) % 2.0 + 2.0) % 2.0 - 1.0); }  // mirror
//   else if (wrap == 1) { st = (st % 1.0 + 1.0) % 1.0; }                  // repeat
//   else            { st = clamp(st, 0.0, 1.0); }                          // clamp
//   return vec4<f32>(textureSampleLevel(inputTex, samp, st, 0.0).rgb, 1.0);
//
// PORTING-GUIDE notes:
//  * st is derived from position.xy / resolution (render-target size), not
//    inputTex dimensions. `resolution` alias from NMFullscreen.hlsl = _NM_Resolution.xy.
//  * `aspect` in WGSL is a standalone uniform = fullResolution.x / fullResolution.y.
//    NMFullscreen.hlsl provides `aspectRatio` as that same value.
//  * WGSL `%` on floats is positive-remainder (equivalent to nm_mod). All three
//    wrap-mode expressions use nm_mod exactly as written in the WGSL.
//  * `time` alias from NMFullscreen.hlsl = _NM_Time.
//  * Offset sign conventions copied VERBATIM: x uses -(x) and -(speedX),
//    y uses +(y) and +(speedY).
//  * wrap is an int (definition.js type: "int", choices: mirror=0, repeat=1, clamp=2).
//  * Output alpha is always 1.0 (WGSL: vec4<f32>(color.rgb, 1.0)).
//  * No PRNG / no per-effect helper functions beyond nm_mod (from NMCore via NMFullscreen).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// Per-effect named uniforms (definition.js globals[*].uniform):
float x;       // offset x,   default 0,  range [-10..10]
float y;       // offset y,   default 0,  range [-10..10]
float speedX;  // speed x,    default 1,  range [-10..10]
float speedY;  // speed y,    default 1,  range [-10..10]
int   wrap;    // wrap mode:  0=mirror, 1=repeat, 2=clamp. default 1

// -----------------------------------------------------------------------------
// nm_scroll — core per-pixel evaluation.
// fragCoord : pixel-center coord in render-target space (NM_FragCoord output).
// Returns RGBA with alpha = 1.0.
// -----------------------------------------------------------------------------
float4 nm_scroll(float2 fragCoord, Texture2D inputTex, SamplerState samp_inputTex)
{
    // WGSL: var st = position.xy / resolution;
    float2 st = fragCoord / resolution;

    // WGSL: st.x *= aspect;
    st.x *= aspectRatio;

    // WGSL: var offset = vec2<f32>(-x + time * -speedX, y + time * speedY);
    float2 offset = float2(-x + time * -speedX, y + time * speedY);

    // WGSL: offset.x *= aspect;
    offset.x *= aspectRatio;

    // WGSL: st += offset;
    st += offset;

    // WGSL: st.x /= aspect;
    st.x /= aspectRatio;

    // Apply wrap mode.
    // WGSL `%` on f32 is nm_mod (positive-remainder). All branches copied verbatim.
    [branch]
    if (wrap == 0)
    {
        // WGSL: st = abs(((st + 1.0) % 2.0 + 2.0) % 2.0 - 1.0);
        st = abs(nm_mod(nm_mod(st + 1.0, (float2)2.0) + 2.0, (float2)2.0) - 1.0);
    }
    else if (wrap == 1)
    {
        // WGSL: st = (st % 1.0 + 1.0) % 1.0;
        st = nm_mod(nm_mod(st, (float2)1.0) + 1.0, (float2)1.0);
    }
    else
    {
        // WGSL: st = clamp(st, vec2<f32>(0.0), vec2<f32>(1.0));
        st = clamp(st, (float2)0.0, (float2)1.0);
    }

    // WGSL: textureSampleLevel(inputTex, samp, st, 0.0)
    float3 color = inputTex.SampleLevel(samp_inputTex, st, 0.0).rgb;

    // WGSL: return vec4<f32>(color, 1.0);
    return float4(color, 1.0);
}

#endif // NM_SCROLL_INCLUDED
