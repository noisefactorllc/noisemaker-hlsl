#ifndef NM_REPEAT_INCLUDED
#define NM_REPEAT_INCLUDED

// =============================================================================
// Repeat.hlsl — filter/repeat, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/repeat/wgsl/repeat.wgsl
//
// Tiles the input texture across the screen with configurable repeat count,
// offset, and wrap mode (mirror / repeat / clamp).
//
// WGSL main() summary:
//   var st = position.xy / resolution;
//   st.x = st.x * aspect;
//   st = st * vec2<f32>(x, y) + vec2<f32>(offsetX * aspect, offsetY);
//   st.x = st.x / aspect;
//   // wrap mode applied to st
//   return vec4<f32>(textureSample(inputTex, samp, st).rgb, 1.0);
//
// PORTING-GUIDE notes:
//  * Single render pass (definition.js passes.length == 1, program "repeat").
//  * `position.xy / resolution` in WGSL equals `i.uv` in HLSL because
//    NM_FragCoord(i) = i.uv * resolution, so the division cancels.
//  * `aspect` in WGSL is bound as a f32 uniform from fullResolution.x/y.
//    We use the `aspectRatio` alias from NMFullscreen.hlsl (same value).
//  * WGSL `%` on floats is floor-based modulo — use nm_mod, never fmod (H6).
//  * Mirror wrap:  abs(((st + 1.0) % 2.0 + 2.0) % 2.0 - 1.0)  → two nm_mod calls.
//  * Repeat wrap:  (st % 1.0 + 1.0) % 1.0                       → two nm_mod calls.
//  * No PRNG / no atan2 / no select / no hsv helpers in this effect.
//  * Alpha is always 1.0 (WGSL: return ...rgb, 1.0).
//  * Linear, clamp-to-edge, non-sRGB sampler (H7) — set on SamplerState in
//    Repeat.shader / supplied by the Shader Graph node.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
float x;       // globals.x.uniform "x",       default 3, range [1, 20]
float y;       // globals.y.uniform "y",        default 3, range [1, 20]
float offsetX; // globals.offsetX.uniform "offsetX", default 0, range [-1, 1]
float offsetY; // globals.offsetY.uniform "offsetY", default 0, range [-1, 1]
int   wrap;    // globals.wrap.uniform "wrap",   default 1 (repeat); choices: mirror=0, repeat=1, clamp=2

// -----------------------------------------------------------------------------
// nm_repeat — core per-pixel evaluation. Returns RGBA (alpha always 1.0).
// Ported VERBATIM from repeat.wgsl main(), with coordinate derivation from i.uv.
// -----------------------------------------------------------------------------
float4 nm_repeat(NMVaryings i, Texture2D inputTex, SamplerState sampler_inputTex)
{
    // WGSL: var st = position.xy / resolution;
    // NM_FragCoord(i) = i.uv * resolution, so / resolution = i.uv exactly.
    float2 st = i.uv;

    // WGSL: st.x = st.x * aspect;
    float aspect = aspectRatio;
    st.x = st.x * aspect;

    // WGSL: st = st * vec2<f32>(x, y) + vec2<f32>(offsetX * aspect, offsetY);
    st = st * float2(x, y) + float2(offsetX * aspect, offsetY);

    // WGSL: st.x = st.x / aspect;
    st.x = st.x / aspect;

    // Apply wrap mode
    [branch]
    if (wrap == 0) {
        // WGSL mirror: st = abs(((st + 1.0) % 2.0 + 2.0) % 2.0 - 1.0);
        st = abs(nm_mod(nm_mod(st + 1.0, float2(2.0, 2.0)) + 2.0, float2(2.0, 2.0)) - 1.0);
    } else if (wrap == 1) {
        // WGSL repeat: st = (st % 1.0 + 1.0) % 1.0;
        st = nm_mod(nm_mod(st, float2(1.0, 1.0)) + 1.0, float2(1.0, 1.0));
    } else {
        // WGSL clamp: st = clamp(st, vec2<f32>(0.0), vec2<f32>(1.0));
        st = clamp(st, float2(0.0, 0.0), float2(1.0, 1.0));
    }

    // WGSL: return vec4<f32>(textureSample(inputTex, samp, st).rgb, 1.0);
    return float4(inputTex.Sample(sampler_inputTex, st).rgb, 1.0);
}

#endif // NM_REPEAT_INCLUDED
