#ifndef NM_EFFECT_TUNNEL_INCLUDED
#define NM_EFFECT_TUNNEL_INCLUDED

// =============================================================================
// Tunnel.hlsl — filter/tunnel (func: "tunnel")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/filter/tunnel/wgsl/tunnel.wgsl
//
// Perspective tunnel effect. Computes polar/shape radius from centered UV,
// maps into a tiling smod2 coordinate, samples inputTex (with optional 4-tap
// RGSS antialias), then applies an optional center vignette. Single pass.
//
// PORTING-GUIDE notes / hazards handled:
//  * Sample coord uses textureDimensions(inputTex), i.e. NM_FragCoord(i) /
//    float2(w,h) — NOT fullResolution. WGSL is canonical.
//  * atan2(x,y) argument ORDER: WGSL polygonShape uses atan2(uv.x, uv.y) —
//    reversed from HLSL atan2(y,x) convention. We replicate literally:
//    atan2(uv.x, uv.y).  The main-body a uses atan2(centered.y, centered.x)
//    (standard order) — also replicated literally.
//  * smod2 is per-effect (not in NMCore); copied verbatim.
//  * polygonShape is per-effect; copied verbatim including the reversed atan2.
//  * shape / antialias / aspectLens are boolean-style ints (int uniforms +
//    [branch] comparisons instead of compile-time defines per PORTING-GUIDE).
//  * dpdx/dpdy -> ddx/ddy (H6 mapping).
//  * mix -> lerp; vec2/vec3/vec4 -> float2/float3/float4.
//  * nm_mod not needed here (no modulo on values); smod2 uses frac (fract).
//  * PI / TAU as float constants.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (reference binding: inputTex) ------------------
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
int   shape;       // 0=circle 1=triangle 2=roundedRect 3=square 4=hexagon 5=octagon
float scale;       // [-1,1]   default 0
float speed;       // [-5,5]   default 1  (passed as float in WGSL struct: f32)
float rotation;    // [-2,2]   default 0  (passed as float in WGSL struct: f32)
float center;      // [-100,100] default 100
int   aspectLens;  // bool     default 1 (true)
int   antialias;   // bool     default 1 (true)

// ---- Constants ---------------------------------------------------------------
static const float NM_TUNNEL_PI  = 3.14159265359;
static const float NM_TUNNEL_TAU = 6.28318530718;

// ---- polygonShape — verbatim from WGSL (note reversed atan2 arg order) ------
// WGSL: let a = atan2(uv.x, uv.y) + PI;
//        let r = TAU / f32(sides);
//        return cos(floor(0.5 + a / r) * r - a) * length(uv);
float nm_tunnel_polygonShape(float2 uv, int sides)
{
    float a = atan2(uv.x, uv.y) + NM_TUNNEL_PI;
    float r = NM_TUNNEL_TAU / (float)sides;
    return cos(floor(0.5 + a / r) * r - a) * length(uv);
}

// ---- smod2 — verbatim from WGSL ---------------------------------------------
// WGSL: return m * (0.75 - abs(fract(v) - 0.5) - 0.25);
float2 nm_tunnel_smod2(float2 v, float m)
{
    return m * (0.75 - abs(frac(v) - 0.5) - 0.25);
}

// =============================================================================
// NMFrag_tunnel — fragment entry for pass "tunnel".
// Mirrors WGSL main() body exactly.
// =============================================================================
float4 NMFrag_tunnel(NMVaryings i) : SV_Target
{
    // WGSL: let texSize = vec2<f32>(textureDimensions(inputTex));
    //       let uv = pos.xy / texSize;
    uint w, h;
    inputTex.GetDimensions(w, h);
    float2 texSize = float2((float)w, (float)h);
    float2 uv = NM_FragCoord(i) / texSize;

    // Center the coordinates
    float2 centered = uv - 0.5;

    // Optional aspect ratio correction
    // NOTE: `aspectRatio` is a #define alias in NMFullscreen.hlsl, so we use a
    // distinct local name (tunnelAspect) to avoid the macro expanding into the
    // declaration / assignment l-value.
    float tunnelAspect = texSize.x / texSize.y;
    [branch] if (aspectLens != 0)
    {
        centered.x = centered.x * tunnelAspect;
    }

    float a = atan2(centered.y, centered.x);
    float r;

    [branch] if (shape == 0)
    {
        // Circle
        r = length(centered);
    }
    else if (shape == 1)
    {
        // Triangle
        r = nm_tunnel_polygonShape(centered * 2.0, 3);
    }
    else if (shape == 2)
    {
        // Rounded square (superellipse)
        float2 p = centered * centered * centered * centered *
                   centered * centered * centered * centered;
        r = pow(p.x + p.y, 1.0 / 8.0);
    }
    else if (shape == 3)
    {
        // Square
        r = nm_tunnel_polygonShape(centered * 2.0, 4);
    }
    else if (shape == 4)
    {
        // Hexagon
        r = nm_tunnel_polygonShape(centered * 2.0, 6);
    }
    else
    {
        // Octagon
        r = nm_tunnel_polygonShape(centered * 2.0, 8);
    }

    // Apply scale
    r -= scale * 0.15;

    // Create tunnel coordinates
    float2 tunnelCoords = nm_tunnel_smod2(float2(
        0.3 / r + time * speed,
        a / NM_TUNNEL_PI + time * rotation
    ), 1.0);

    float4 color;
    [branch] if (antialias != 0)
    {
        float2 dx = ddx(tunnelCoords);
        float2 dy = ddy(tunnelCoords);
        color = float4(0.0, 0.0, 0.0, 0.0);
        color += inputTex.Sample(sampler_inputTex, tunnelCoords + dx * -0.375 + dy * -0.125);
        color += inputTex.Sample(sampler_inputTex, tunnelCoords + dx *  0.125 + dy * -0.375);
        color += inputTex.Sample(sampler_inputTex, tunnelCoords + dx *  0.375 + dy *  0.125);
        color += inputTex.Sample(sampler_inputTex, tunnelCoords + dx * -0.125 + dy *  0.375);
        color = color * 0.25;
    }
    else
    {
        color = inputTex.Sample(sampler_inputTex, tunnelCoords);
    }

    // Center vignette: smooth falloff to hide moiré at vanishing point
    // WGSL: if (uniforms.center != 0.0) { ... }
    [branch] if (center != 0.0)
    {
        float centerMask = smoothstep(0.0, 0.5, r);
        float amt = center / 100.0;
        [branch] if (amt < 0.0)
        {
            color = float4(color.rgb * lerp(1.0, centerMask, -amt), color.a);
        }
        else
        {
            color = float4(lerp(color.rgb, float3(1.0, 1.0, 1.0), (1.0 - centerMask) * amt), color.a);
        }
    }

    return color;
}

#endif // NM_EFFECT_TUNNEL_INCLUDED
