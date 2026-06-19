#ifndef NM_SPLIT_INCLUDED
#define NM_SPLIT_INCLUDED

// =============================================================================
// Split.hlsl — mixer/split, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/mixer/split/wgsl/split.wgsl
//
// Wipes/splits between two inputs (colorA = inputTex, colorB = tex) along a
// rotatable line that can animate across the screen. Single render pass.
//
// PORTING-GUIDE notes:
//  * No per-effect helper functions — the WGSL uses only built-in math (cos, sin,
//    fract, floor, smoothstep, mix, max). Nothing is hoisted; logic is inline.
//  * Uniforms: position (f32), rotation (f32), softness (f32), invert (i32),
//    speed (f32 in WGSL — definition.js types it int but the WGSL binding uses
//    f32 for the > 0.0 comparison; we declare float to match the WGSL exactly).
//  * speed is typed i32 in definition.js but the WGSL binds it as f32 and uses
//    `speed > 0.0` — declare float to reproduce the comparison faithfully.
//  * flipCycle in WGSL: `i32(floor(cycle)) % 2 == 1` — integer modulo on a
//    truncating i32 is the plain HLSL `%` operator (H4 / trunc-toward-zero).
//    For non-negative floor(cycle) this equals positive-modulo; we replicate
//    the WGSL exactly: (int)floor(cycle) % 2 == 1.
//  * invert XOR flipCycle: `(invert == 1) != flipCycle` in WGSL. In HLSL we
//    reproduce as `((invert == 1) != flipCycle)` with bool comparison.
//  * Sample coord: WGSL divides pos.xy by inputTex's OWN dims for BOTH textures
//    (same st for both). Follow WGSL verbatim — same st samples both.
//  * globalUV uses (pos.xy + tileOffset) / fullResolution (the WGSL uses
//    fullResolution directly, not resolution). We follow the WGSL.
//  * No nm_mod / no pcg / no atan2 / no asuint — no bit hazards in this effect.
//  * PI defined as const f32 3.14159265359 in WGSL — replicated as #define.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
float position;    // globals.position.uniform "position", default 0.0, [-1, 1]
float rotation;    // globals.rotation.uniform "rotation", default 0.0, [-180, 180]
float softness;    // globals.softness.uniform "softness", default 0.0, [0, 1]
int   invert;      // globals.invert.uniform   "invert",   default 0 (0=off, 1=on)
float speed;       // globals.speed.uniform    "speed",    default 0.0, [0, 4]
                   //   (definition.js type=int but WGSL binds f32; keep float for
                   //    exact `speed > 0.0` comparison)

// PI — matches WGSL: `const PI: f32 = 3.14159265359;`
#define NM_SPLIT_PI 3.14159265359

// -----------------------------------------------------------------------------
// nm_split — core per-pixel evaluation. Takes the two already-sampled colors
// (colorA = inputTex, colorB = tex) and the screen-space position (pos.xy,
// top-left +0.5) and returns the wiped RGBA.
// Ported VERBATIM from split.wgsl @fragment main().
// -----------------------------------------------------------------------------
float4 nm_split(float4 colorA, float4 colorB, float2 pos)
{
    // globalUV — WGSL: (pos.xy + tileOffset) / fullResolution
    float2 globalUV = (pos + tileOffset) / fullResolution;
    float aspect = fullResolution.x / fullResolution.y;

    // centered — WGSL: (globalUV - vec2<f32>(0.5, 0.5)) * 2.0; centered.x *= aspect
    float2 centered = (globalUV - float2(0.5, 0.5)) * 2.0;
    centered.x = centered.x * aspect;

    // Rotate the split line
    float rad = rotation * NM_SPLIT_PI / 180.0;
    float c = cos(rad);
    float s = sin(rad);
    float2 rotated = float2(centered.x * c - centered.y * s,
                            centered.x * s + centered.y * c);

    // Compute visible extent of rotated.y for seamless scrolling
    float extent = aspect * abs(s) + abs(c) + softness;

    // Animate: continuous scroll across full visible range
    float animPos = position;
    bool flipCycle = false;
    if (speed > 0.0) {
        float cycle = time * speed * 2.0;
        float t = frac(cycle);
        // WGSL: i32(floor(cycle)) % 2 == 1  — truncating int modulo
        flipCycle = ((int)floor(cycle)) % 2 == 1;
        animPos = t * extent * 2.0 - extent;
    }

    // Signed distance from the split line
    float d = rotated.y - animPos;

    // Apply softness
    float halfSoft = max(softness * 0.5, 0.001);
    float mask = smoothstep(-halfSoft, halfSoft, d);

    // WGSL: if ((invert == 1) != flipCycle) { mask = 1.0 - mask; }
    if ((invert == 1) != flipCycle) {
        mask = 1.0 - mask;
    }

    // WGSL: mix(colorA, colorB, mask); color.a = max(colorA.a, colorB.a)
    float4 color = lerp(colorA, colorB, mask);
    color.a = max(colorA.a, colorB.a);

    return color;
}

#endif // NM_SPLIT_INCLUDED
