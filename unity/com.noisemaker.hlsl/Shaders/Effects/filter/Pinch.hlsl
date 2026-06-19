#ifndef NM_EFFECT_PINCH_INCLUDED
#define NM_EFFECT_PINCH_INCLUDED

// =============================================================================
// Pinch.hlsl — filter/pinch (func: "pinch")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/filter/pinch/wgsl/pinch.wgsl
//
// Pinch distortion toward center with optional rotation, aspect-correct lens,
// and three wrap modes (mirror/repeat/clamp). Optional 4-tap rotated-grid AA.
// Single render pass.
//
// PORTING-GUIDE notes / hazards handled:
//  * UV is computed as pos.xy / textureDimensions(inputTex) in WGSL — i.e.
//    NM_FragCoord(i) divided by the INPUT TEXTURE's own dimensions. No
//    fullResolution involved in the sample coordinate.
//  * rotate2D is this effect's own helper — copied verbatim from WGSL inline.
//    Do NOT substitute any generic rotate.
//  * Wrap modes use nm_mod (float mod, floor-based) to match WGSL `%` on floats
//    which is also floor-based in WGSL (the `modulo` / `a - b*floor(a/b)` rule).
//    WGSL `%` for vec2<f32> is identical to nm_mod per the porting guide.
//  * aspectLens and antialias are booleans in definition.js; bound as int uniforms
//    and tested > 0 (matches WGSL `!= 0`).
//  * wrap is an int uniform; branched with [branch].
//  * pow(r, 1.0 - intensity): when r == 0 result is 0 regardless; normalize(0)
//    is undefined but the result is multiplied by 0 so pixel stays at origin.
//    WGSL has the same behaviour. // TODO(verify): check zero-vector normalize on
//    all Unity GPU backends (DX11/Metal/Vulkan) for centre-pixel artifact.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (reference binding: sampler@0, inputTex@1) ------
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
float strength;    // [0,100]  default 75
int   aspectLens;  // boolean  default 1 (true)
int   wrap;        // 0=mirror,1=repeat,2=clamp  default 0
float rotation;    // [-180,180] deg  default 0
int   antialias;   // boolean  default 1 (true)

// ---- Helpers -----------------------------------------------------------------
// rotate2D — verbatim from WGSL:
//   fn rotate2D(st_in: vec2<f32>, rot: f32, aspectRatio: f32) -> vec2<f32>
//   st.x = st.x * aspectRatio
//   angle = rot * PI
//   st = st - vec2(0.5 * aspectRatio, 0.5)
//   c = cos(angle); s = sin(angle)
//   st = vec2(c*st.x - s*st.y,  s*st.x + c*st.y)
//   st = st + vec2(0.5 * aspectRatio, 0.5)
//   st.x = st.x / aspectRatio
//   return st
static const float NM_PINCH_PI = 3.14159265359;

float2 nm_pinch_rotate2D(float2 st, float rot, float ar)
{
    st.x = st.x * ar;
    float angle = rot * NM_PINCH_PI;
    st = st - float2(0.5 * ar, 0.5);
    float c = cos(angle);
    float s = sin(angle);
    // GLSL golden: mat2(cos,-sin,sin,cos) * st. GLSL mat2 is COLUMN-MAJOR, so it
    // equals (c*st.x + s*st.y, -s*st.x + c*st.y) — opposite rotation direction from
    // the WGSL transcription (c*x-s*y, s*x+c*y). Only diverges for nonzero rotation.
    st = float2(c * st.x + s * st.y, -s * st.x + c * st.y);
    st = st + float2(0.5 * ar, 0.5);
    st.x = st.x / ar;
    return st;
}

// ---- Pass: "pinch" (progName "pinch") ----------------------------------------
float4 NMFrag_pinch(NMVaryings i) : SV_Target
{
    // WGSL: texSize = vec2<f32>(textureDimensions(inputTex))
    //       uv      = pos.xy / texSize
    uint tw, th;
    inputTex.GetDimensions(tw, th);
    float2 texSize = float2((float)tw, (float)th);
    float ar = texSize.x / texSize.y;

    float2 uv = NM_FragCoord(i) / texSize;

    // Apply rotation before distortion
    uv = nm_pinch_rotate2D(uv, rotation / 180.0, ar);

    float intensity = strength * 0.01;

    uv = uv - 0.5;

    [branch]
    if (aspectLens != 0)
    {
        uv.x = uv.x * ar;
    }

    float r = length(uv);
    float effect = pow(r, 1.0 - intensity);
    uv = normalize(uv) * effect;

    [branch]
    if (aspectLens != 0)
    {
        uv.x = uv.x / ar;
    }

    uv = uv + 0.5;

    // Apply wrap mode
    [branch]
    if (wrap == 0)
    {
        // mirror: abs(((uv + 1.0) % 2.0 + 2.0) % 2.0 - 1.0)
        // WGSL % on f32 is floor-based, same as nm_mod
        uv = abs(nm_mod(nm_mod(uv + 1.0, 2.0) + 2.0, 2.0) - 1.0);
    }
    else if (wrap == 1)
    {
        // repeat: (uv % 1.0 + 1.0) % 1.0
        uv = nm_mod(nm_mod(uv, 1.0) + 1.0, 1.0);
    }
    else
    {
        // clamp
        uv = clamp(uv, float2(0.0, 0.0), float2(1.0, 1.0));
    }

    // Reverse rotation after distortion
    uv = nm_pinch_rotate2D(uv, -rotation / 180.0, ar);

    [branch]
    if (antialias != 0)
    {
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

#endif // NM_EFFECT_PINCH_INCLUDED
