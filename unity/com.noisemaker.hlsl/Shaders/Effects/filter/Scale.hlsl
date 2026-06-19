#ifndef NM_SCALE_INCLUDED
#define NM_SCALE_INCLUDED

// =============================================================================
// Scale.hlsl — filter/scale, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/scale/wgsl/scale.wgsl
//
// Scales UVs around an arbitrary center point with aspect-correct stretch and
// three wrap modes (mirror/repeat/clamp).
//
// WGSL main() logic (verbatim translation):
//   var st = position.xy / resolution;
//   let center = vec2<f32>(-centerX, centerY);
//   st -= center;
//   st.x *= aspect;
//   st /= vec2<f32>(scaleX, scaleY);
//   st.x /= aspect;
//   st += center;
//   if (wrap == 0) { st = abs(((st + 1.0) % 2.0 + 2.0) % 2.0 - 1.0); }
//   else if (wrap == 1) { st = (st % 1.0 + 1.0) % 1.0; }
//   else { st = clamp(st, vec2(0.0), vec2(1.0)); }
//   return vec4<f32>(textureSample(inputTex, samp, st).rgb, 1.0);
//
// PORTING-GUIDE notes:
//  * Single render pass (definition.js passes[0].program "scale").
//  * uv = position.xy / resolution (render target size). WGSL uses `resolution`
//    (the current tile/target size), NOT `fullResolution`. NM_FragCoord(i) divided
//    by resolution exactly mirrors this.
//  * center.x is negated in the WGSL: vec2<f32>(-centerX, centerY). Ported verbatim.
//  * WGSL float `%` is floor-based modulo (same as GLSL mod). Map to nm_mod (never fmod).
//  * wrap is an i32 uniform. Declared as int; branch with [branch] exactly as the
//    WGSL if/else chain.
//  * aspect alias = fullResolution.x / fullResolution.y (provided by NMFullscreen.hlsl).
//  * No PRNG / no atan2 / no per-effect helpers needed beyond nm_mod from NMCore.
//  * Linear, clamp-to-edge, non-sRGB sampler (H7) — declared in Scale.shader.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
float scaleX;   // globals.x.uniform "scaleX",     default 0.5
float scaleY;   // globals.y.uniform "scaleY",     default 0.5
float centerX;  // globals.centerX.uniform "centerX", default 0.5
float centerY;  // globals.centerY.uniform "centerY", default 0.5
int   wrap;     // globals.wrap.uniform "wrap",     default 1 (repeat)
                //   choices: mirror=0, repeat=1, clamp=2

// -----------------------------------------------------------------------------
// nm_scale — core per-pixel UV remapping. Takes fragCoord (top-left, +0.5),
// samples inputTex, and returns RGBA. Ported VERBATIM from scale.wgsl main().
// Caller passes the render-target dimensions (resolution.xy) and the input
// texture + sampler separately so the Shader Graph wrapper can reuse this fn.
// -----------------------------------------------------------------------------
float4 nm_scale(
    float2       fragCoord,   // NM_FragCoord(i) — top-left pixel center
    float2       res,         // resolution.xy (render target size)
    Texture2D    inputTex,
    SamplerState sampler_inputTex)
{
    // WGSL: var st = position.xy / resolution;
    float2 st = fragCoord / res;

    // WGSL: let center = vec2<f32>(-centerX, centerY);
    float2 center = float2(-centerX, centerY);

    // WGSL: st -= center;  st.x *= aspect;  st /= vec2(scaleX,scaleY);  st.x /= aspect;  st += center;
    st -= center;
    st.x *= aspectRatio;
    st /= float2(scaleX, scaleY);
    st.x /= aspectRatio;
    st += center;

    // WGSL wrap modes — float % is floor-based: map to nm_mod (never fmod).
    [branch]
    if (wrap == 0) {
        // mirror: abs(((st + 1.0) % 2.0 + 2.0) % 2.0 - 1.0)
        st = abs(nm_mod(nm_mod(st + 1.0, 2.0) + 2.0, 2.0) - 1.0);
    } else if (wrap == 1) {
        // repeat: (st % 1.0 + 1.0) % 1.0
        st = nm_mod(nm_mod(st, 1.0) + 1.0, 1.0);
    } else {
        // clamp
        st = clamp(st, float2(0.0, 0.0), float2(1.0, 1.0));
    }

    // WGSL: return vec4<f32>(textureSample(inputTex, samp, st).rgb, 1.0);
    float3 color = inputTex.Sample(sampler_inputTex, st).rgb;
    return float4(color, 1.0);
}

#endif // NM_SCALE_INCLUDED
