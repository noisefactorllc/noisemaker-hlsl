#ifndef NM_EFFECT_SPIRAL_INCLUDED
#define NM_EFFECT_SPIRAL_INCLUDED

// =============================================================================
// Spiral.hlsl — filter/spiral (func: "spiral")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/filter/spiral/wgsl/spiral.wgsl
//
// Single render pass. Applies a spiral/swirl distortion around the image
// center in polar-coordinate space, with optional aspect-correct lens,
// animation via `time`, configurable wrap mode, and 4-tap AA.
//
// PORTING-GUIDE notes / hazards handled:
//  * UV derived from @builtin(position) / textureDimensions(inputTex) — the
//    WGSL divides pos.xy by the INPUT texture's own size, not fullResolution.
//    We mirror exactly: NM_FragCoord(i) / float2(texW, texH).
//  * rotate2D — this effect has its OWN version (scales x by aspectRatio,
//    applies 2D rotation matrix, then unscales). Copied verbatim; does NOT
//    share any NMCore helper.
//  * WGSL wrap mode 0 (mirror): uv = abs(((uv + 1.0) % 2.0 + 2.0) % 2.0 - 1.0)
//    WGSL `%` on floats = floored modulo (matches nm_mod). We use nm_mod here.
//  * WGSL wrap mode 1 (repeat): uv = (uv % 1.0 + 1.0) % 1.0 — again nm_mod.
//  * aspectLens, antialias declared as `int`; tested `!= 0` (WGSL `!= 0`).
//  * speed declared as `int` (definition.js type: "int").
//  * atan2 arg order: WGSL `atan2(uv.y, uv.x)` -> HLSL `atan2(uv.y, uv.x)`.
//  * `time` is the NMFullscreen alias for _NM_Time (0..1 normalized).
//  * Antialias: 4-tap rotated grid via `dpdx`/`dpdy` (ddx/ddy in HLSL).
//  * No PRNG / no PCG / no float-bit hazards in this effect.
//  * Linear clamp-to-edge non-sRGB sampler (H7).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (reference binding: inputSampler@0, inputTex@1) -
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
float strength;    // float, default -100, [-100, 100]
int   speed;       // int,   default 0,    [-5, 5]
float rotation;    // float, default 0,    [-180, 180]
int   wrap;        // int,   default 0,    {mirror=0, repeat=1, clamp=2}
int   aspectLens;  // int (bool), default 1 (true)
int   antialias;   // int (bool), default 1 (true)

// =============================================================================
// rotate2D — verbatim from WGSL rotate2D(st_in, rot, aspectRatio).
//   st.x  = st.x * aspectRatio
//   angle = rot * PI
//   st    = st - vec2(0.5*aspectRatio, 0.5)
//   st    = vec2(cos*st.x - sin*st.y, sin*st.x + cos*st.y)
//   st    = st + vec2(0.5*aspectRatio, 0.5)
//   st.x  = st.x / aspectRatio
// =============================================================================
static const float NM_SPIRAL_PI  = 3.14159265359;
static const float NM_SPIRAL_TAU = 6.28318530718;

float2 nm_spiral_rotate2D(float2 st, float rot, float ar)
{
    st.x = st.x * ar;
    float angle = rot * NM_SPIRAL_PI;
    float c = cos(angle);
    float s = sin(angle);
    st = st - float2(0.5 * ar, 0.5);
    // GLSL golden: mat2(cos,-sin,sin,cos) * st. GLSL mat2 is COLUMN-MAJOR, so this
    // equals (c*st.x + s*st.y, -s*st.x + c*st.y) — the opposite rotation direction
    // from the WGSL transcription (c*x-s*y, s*x+c*y). rotation=0 (s=0) hides it.
    st = float2(c * st.x + s * st.y, -s * st.x + c * st.y);
    st = st + float2(0.5 * ar, 0.5);
    st.x = st.x / ar;
    return st;
}

// =============================================================================
// NMFrag_spiral — fragment pass "spiral".
// Mirrors the WGSL main() body verbatim.
// =============================================================================
float4 NMFrag_spiral(NMVaryings i) : SV_Target
{
    // WGSL: texSize = vec2<f32>(textureDimensions(inputTex))
    //       uv      = pos.xy / texSize
    uint tw, th;
    inputTex.GetDimensions(tw, th);
    float2 texSize   = float2((float)tw, (float)th);
    float  ar        = texSize.x / texSize.y;
    float2 uv        = NM_FragCoord(i) / texSize;

    float t = time;

    // Apply rotation before distortion
    uv = nm_spiral_rotate2D(uv, rotation / 180.0, ar);

    uv = uv - 0.5;

    if (aspectLens != 0)
    {
        uv.x = uv.x * ar;
    }

    // Convert to polar coordinates
    float r = length(uv);
    float a = atan2(uv.y, uv.x);

    // Apply spiral distortion
    float spiralAmt = (strength * 0.05) * r;
    a = a + spiralAmt - (t * NM_SPIRAL_TAU * (float)speed * sign(strength));

    // Convert back to cartesian coordinates
    uv = float2(cos(a), sin(a)) * r;

    if (aspectLens != 0)
    {
        uv.x = uv.x / ar;
    }

    uv = uv + 0.5;

    // Apply wrap mode
    // WGSL wrap==0 (mirror): uv = abs(((uv + 1.0) % 2.0 + 2.0) % 2.0 - 1.0)
    // WGSL wrap==1 (repeat): uv = (uv % 1.0 + 1.0) % 1.0
    // WGSL uses floored % — use nm_mod
    if (wrap == 0)
    {
        uv = abs(nm_mod(nm_mod(uv + float2(1.0, 1.0), float2(2.0, 2.0)) + float2(2.0, 2.0), float2(2.0, 2.0)) - float2(1.0, 1.0));
    }
    else if (wrap == 1)
    {
        uv = nm_mod(nm_mod(uv, float2(1.0, 1.0)) + float2(1.0, 1.0), float2(1.0, 1.0));
    }
    else
    {
        uv = clamp(uv, float2(0.0, 0.0), float2(1.0, 1.0));
    }

    // Reverse rotation after distortion
    uv = nm_spiral_rotate2D(uv, -rotation / 180.0, ar);

    [branch]
    if (antialias != 0)
    {
        float2 dx = ddx(uv);
        float2 dy = ddy(uv);
        float4 col = float4(0.0, 0.0, 0.0, 0.0);
        col += inputTex.SampleLevel(sampler_inputTex, uv + dx * -0.375 + dy * -0.125, 0.0);
        col += inputTex.SampleLevel(sampler_inputTex, uv + dx *  0.125 + dy * -0.375, 0.0);
        col += inputTex.SampleLevel(sampler_inputTex, uv + dx *  0.375 + dy *  0.125, 0.0);
        col += inputTex.SampleLevel(sampler_inputTex, uv + dx * -0.125 + dy *  0.375, 0.0);
        return col * 0.25;
    }
    else
    {
        return inputTex.SampleLevel(sampler_inputTex, uv, 0.0);
    }
}

#endif // NM_EFFECT_SPIRAL_INCLUDED
