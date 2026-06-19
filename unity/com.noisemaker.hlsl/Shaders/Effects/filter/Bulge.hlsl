#ifndef NM_EFFECT_BULGE_INCLUDED
#define NM_EFFECT_BULGE_INCLUDED

// =============================================================================
// Bulge.hlsl — filter/bulge (func: "bulge")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/filter/bulge/wgsl/bulge.wgsl
//
// Bulge distortion from center. Single render pass ("bulge").
//
// PORTING-GUIDE notes / hazards handled:
//  * UV derived from pos.xy / textureDimensions(inputTex) in the WGSL — i.e.
//    fragCoord divided by the INPUT TEXTURE's own dimensions. NM_FragCoord(i)
//    (top-left, +0.5 centered) is the @builtin(position) analog.
//  * aspectRatio computed from texSize (not fullResolution) — matches WGSL.
//  * rotate2D: this effect's own version (scales x by aspectRatio, rotates
//    around (0.5*aspectRatio, 0.5)). Copied verbatim — do NOT substitute.
//  * WGSL wrap uses `% 2.0` / `% 1.0` (WGSL modulo = floor-mod, not fmod).
//    In HLSL we must use nm_mod from NMCore (never fmod).
//  * select() args in WGSL: select(falseVal, trueVal, cond) — reversed from
//    ternary. WGSL source uses if/else here, so no select translation needed.
//  * Booleans (aspectLens, antialias) declared int; tested > 0 matching WGSL
//    `!= 0` comparison.
//  * dpdx/dpdy -> ddx/ddy (HLSL screen-space derivative intrinsics).
//  * Linear, clamp-to-edge, non-sRGB sampler (H7) — set in Bulge.shader.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (definition.js passes[0].inputs.inputTex) ------
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
float strength;    // default 25, [0,100]
int   aspectLens;  // boolean as int, default 1 (true)
int   wrap;        // 0=mirror 1=repeat 2=clamp, default 0
float rotation;    // degrees, default 0, [-180,180]
int   antialias;   // boolean as int, default 1 (true)

// const PI (matches WGSL `const PI: f32 = 3.14159265359;`)
static const float NM_BULGE_PI = 3.14159265359;

// -----------------------------------------------------------------------------
// rotate2D — verbatim from WGSL rotate2D(st_in, rot, aspectRatio).
//   st.x *= aspectRatio
//   angle = rot * PI
//   st -= (0.5*aspectRatio, 0.5)
//   (c*st.x - s*st.y,  s*st.x + c*st.y)
//   st += (0.5*aspectRatio, 0.5)
//   st.x /= aspectRatio
// This is THIS effect's own rotate2D — do not substitute with any shared version.
// -----------------------------------------------------------------------------
// NOTE: param named `asp` (NOT `aspectRatio`) — NMFullscreen.hlsl #defines
// `aspectRatio` as a macro, so a local/param with that name fails to compile.
float2 nm_bulge_rotate2D(float2 st, float rot, float asp)
{
    st.x = st.x * asp;
    float angle = rot * NM_BULGE_PI;
    float c = cos(angle);
    float s = sin(angle);
    st = st - float2(0.5 * asp, 0.5);
    st = float2(c * st.x - s * st.y, s * st.x + c * st.y);
    st = st + float2(0.5 * asp, 0.5);
    st.x = st.x / asp;
    return st;
}

// =============================================================================
// NMFrag_bulge — core per-pixel evaluation; verbatim port of WGSL main().
// Pass: "bulge" (definition.js passes[0].program = "bulge").
// =============================================================================
float4 NMFrag_bulge(NMVaryings i) : SV_Target
{
    // WGSL: let texSize = vec2<f32>(textureDimensions(inputTex));
    //       let aspectRatio = texSize.x / texSize.y;
    //       var uv = pos.xy / texSize;
    uint tw, th;
    inputTex.GetDimensions(tw, th);
    float2 texSize = float2((float)tw, (float)th);
    float asp = texSize.x / texSize.y;  // local (NOT macro `aspectRatio`)
    float2 uv = NM_FragCoord(i) / texSize;

    // Apply rotation before distortion
    // WGSL: uv = rotate2D(uv, uniforms.rotation / 180.0, aspectRatio);
    uv = nm_bulge_rotate2D(uv, rotation / 180.0, asp);

    // WGSL: let intensity = uniforms.strength * -0.01;
    float intensity = strength * -0.01;

    // WGSL: uv = uv - 0.5;
    uv = uv - 0.5;

    // WGSL: if (uniforms.aspectLens != 0) { uv.x = uv.x * aspectRatio; }
    if (aspectLens != 0)
    {
        uv.x = uv.x * asp;
    }

    // WGSL: let r = length(uv);
    //       let effect = pow(r, 1.0 - intensity);
    //       uv = normalize(uv) * effect;
    float r = length(uv);
    float effect = pow(r, 1.0 - intensity);
    uv = normalize(uv) * effect;

    // WGSL: if (uniforms.aspectLens != 0) { uv.x = uv.x / aspectRatio; }
    if (aspectLens != 0)
    {
        uv.x = uv.x / asp;
    }

    // WGSL: uv = uv + 0.5;
    uv = uv + 0.5;

    // Apply wrap mode
    // WGSL uses WGSL modulo (floor-mod) `%`; HLSL must use nm_mod (never fmod).
    [branch]
    if (wrap == 0)
    {
        // mirror: abs(((uv + 1.0) % 2.0 + 2.0) % 2.0 - 1.0)
        uv = abs(nm_mod(nm_mod(uv + 1.0, float2(2.0, 2.0)) + 2.0, float2(2.0, 2.0)) - 1.0);
    }
    else if (wrap == 1)
    {
        // repeat: (uv % 1.0 + 1.0) % 1.0
        uv = nm_mod(nm_mod(uv, float2(1.0, 1.0)) + 1.0, float2(1.0, 1.0));
    }
    else
    {
        // clamp
        uv = clamp(uv, float2(0.0, 0.0), float2(1.0, 1.0));
    }

    // Reverse rotation after distortion
    // WGSL: uv = rotate2D(uv, -uniforms.rotation / 180.0, aspectRatio);
    uv = nm_bulge_rotate2D(uv, -rotation / 180.0, asp);

    // Antialias: 4x supersample using distortion derivatives
    [branch]
    if (antialias != 0)
    {
        // WGSL: let dx = dpdx(uv); let dy = dpdy(uv);
        float2 dx = ddx(uv);
        float2 dy = ddy(uv);
        float4 col = float4(0.0, 0.0, 0.0, 0.0);
        col += inputTex.Sample(sampler_inputTex, uv + dx * -0.375 + dy * -0.125);
        col += inputTex.Sample(sampler_inputTex, uv + dx *  0.125 + dy * -0.375);
        col += inputTex.Sample(sampler_inputTex, uv + dx *  0.375 + dy *  0.125);
        col += inputTex.Sample(sampler_inputTex, uv + dx * -0.125 + dy *  0.375);
        return col * 0.25;
    }
    else
    {
        return inputTex.Sample(sampler_inputTex, uv);
    }
}

#endif // NM_EFFECT_BULGE_INCLUDED
