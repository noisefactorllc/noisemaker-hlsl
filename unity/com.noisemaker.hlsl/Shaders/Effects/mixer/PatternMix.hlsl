#ifndef NM_PATTERNMIX_INCLUDED
#define NM_PATTERNMIX_INCLUDED

// =============================================================================
// PatternMix.hlsl — mixer/patternMix, ported PIXEL-IDENTICALLY from the
// canonical WGSL: shaders/effects/mixer/patternMix/wgsl/patternMix.wgsl
//
// Mixes two inputs (colorA = inputTex, colorB = tex) using a geometric pattern
// mask driven by patternType. Single render pass (definition.js passes[0]).
//
// PORTING-GUIDE notes:
//  * All pattern helpers (rotate2D, stripes, checkerboard, grid, dots, hexDist,
//    hexagons, concentricRings, radialLines, triangularGrid, spiralPattern) are
//    THIS effect's own copies, ported VERBATIM inline (golden rule 2).
//  * patternType: definition.js `uniform: "patternType"` — declared int uniform.
//    Runtime branches with [branch] per compile-time-define → runtime-uniform
//    conversion rule.
//  * invert: definition.js `uniform: "invert"` — declared int uniform.
//  * WGSL `%` on float (hexagons `(p % s)`, checkerboard `(cell.x+cell.y) % 2.0`)
//    is the `%` OPERATOR, which the WGSL spec defines as TRUNCATED remainder
//    (e1 - e2*trunc(e1/e2)) — sign-of-dividend, == HLSL `fmod`. It is NOT the
//    floor-based `modulo()`/GLSL `mod()` that maps to nm_mod (H6). The operands
//    here are negative (centered/scaled p; floor(p) cells), so the two differ;
//    use `fmod` to match the canonical WGSL output exactly.
//  * atan2 arg order: WGSL atan2(y,x) → HLSL atan2(y,x) — copied literally.
//  * WGSL `select(b, a, cond)` appears in hexagons length comparison — translated
//    to a plain if/else matching the WGSL logic exactly.
//  * mix() → lerp(). fract() → frac(). vec2 → float2. const → static const.
//  * Sample coord: WGSL derives `st = position.xy / textureDimensions(inputTex)`
//    then uses the SAME st for both textures. Follow that exactly.
//  * Aspect-correction and scaling: WGSL uses `dims.x / dims.y` (inputTex aspect)
//    and `p * (21.0 - scale)`. Reproduced verbatim.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
int   patternType; // globals.type.uniform "patternType", default 7 (stripes)
float scale;       // globals.scale.uniform "scale",       default 18.0
float thickness;   // globals.thickness.uniform "thickness", default 0.5
float smoothness;  // globals.smoothness.uniform "smoothness", default 0.01
float rotation;    // globals.rotation.uniform "rotation",  default 0.0
int   invert;      // globals.invert.uniform "invert",     default 0

// ---- Pattern type integer constants (from WGSL const declarations) ----------
static const int CHECKERBOARD   = 0;
static const int CONCENTRIC_RINGS = 1;
static const int DOTS           = 2;
static const int GRID           = 3;
static const int HEXAGONS       = 4;
static const int RADIAL_LINES   = 5;
static const int SPIRAL_PATTERN = 6;
static const int STRIPES        = 7;
static const int TRIANGULAR_GRID = 8;

static const float NM_PM_PI   = 3.14159265359;
static const float NM_PM_SQRT3 = 1.7320508075688772;
static const float NM_PM_TAU  = 6.28318530718;

// -----------------------------------------------------------------------------
// rotate2D — ported VERBATIM from patternMix.wgsl lines 25-29.
// -----------------------------------------------------------------------------
float2 rotate2D(float2 p, float angle)
{
    float c = cos(angle);
    float s = sin(angle);
    return float2(p.x * c - p.y * s, p.x * s + p.y * c);
}

// -----------------------------------------------------------------------------
// stripes — ported VERBATIM from patternMix.wgsl lines 31-36.
// -----------------------------------------------------------------------------
float nm_pm_stripes(float2 p, float t, float sm)
{
    float stripe = frac(p.x);
    float edge1 = smoothstep(0.5 - t * 0.5 - sm, 0.5 - t * 0.5 + sm, stripe);
    float edge2 = smoothstep(0.5 + t * 0.5 - sm, 0.5 + t * 0.5 + sm, stripe);
    return edge1 - edge2;
}

// -----------------------------------------------------------------------------
// checkerboard — ported VERBATIM from patternMix.wgsl lines 38-45.
// WGSL `(cell.x + cell.y) % 2.0` is float modulo → nm_mod.
// -----------------------------------------------------------------------------
float nm_pm_checkerboard(float2 p, float sm)
{
    float2 f = frac(p);
    float d = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
    float2 cell = floor(p);
    // WGSL `(cell.x + cell.y) % 2.0` is the `%` OPERATOR = truncated remainder
    // (e1 - e2*trunc(e1/e2)), NOT floor-based modulo. That is HLSL `fmod`, not
    // nm_mod. cell can be negative, so the two differ; match the WGSL exactly.
    float check = fmod(cell.x + cell.y, 2.0);
    float edge = smoothstep(0.0, sm * 0.5, d);
    return lerp(1.0 - check, check, edge);
}

// -----------------------------------------------------------------------------
// grid — ported VERBATIM from patternMix.wgsl lines 47-52.
// -----------------------------------------------------------------------------
float nm_pm_grid(float2 p, float t, float sm)
{
    float2 f = frac(p);
    float lineX = smoothstep(t * 0.5 - sm, t * 0.5 + sm, abs(f.x - 0.5));
    float lineY = smoothstep(t * 0.5 - sm, t * 0.5 + sm, abs(f.y - 0.5));
    return 1.0 - min(lineX, lineY);
}

// -----------------------------------------------------------------------------
// dots — ported VERBATIM from patternMix.wgsl lines 54-59.
// -----------------------------------------------------------------------------
float nm_pm_dots(float2 p, float t, float sm)
{
    float2 f = frac(p) - float2(0.5, 0.5);
    float d = length(f);
    float r = t * 0.5;
    return 1.0 - smoothstep(r - sm, r + sm, d);
}

// -----------------------------------------------------------------------------
// hexDist — ported VERBATIM from patternMix.wgsl lines 61-64.
// -----------------------------------------------------------------------------
float hexDist(float2 p)
{
    float2 ap = abs(p);
    return max(ap.x * 0.5 + ap.y * (NM_PM_SQRT3 / 2.0), ap.x);
}

// -----------------------------------------------------------------------------
// hexagons — ported VERBATIM from patternMix.wgsl lines 66-80.
// WGSL `p % s` is the `%` operator (truncated remainder) on vec2 → fmod.
// WGSL `select(a,b,cond)` → if/else (note WGSL select(false_val,true_val,cond)).
// -----------------------------------------------------------------------------
float nm_pm_hexagons(float2 p, float t, float sm)
{
    float2 s = float2(1.0, NM_PM_SQRT3);
    float2 h = s * 0.5;
    // WGSL `p % s` is the `%` OPERATOR = truncated remainder per component
    // (e1 - e2*trunc(e1/e2)), NOT floor-based modulo. That is HLSL `fmod`, not
    // nm_mod. p is centered/scaled (negative), so they differ; match WGSL.
    float2 a = fmod(p, s) - h;
    float2 b = fmod(p + h, s) - h;
    float2 g;
    if (length(a) < length(b)) {
        g = a;
    } else {
        g = b;
    }
    float d = hexDist(g);
    float edge = 0.5 * t;
    return smoothstep(edge + sm, edge - sm, d);
}

// -----------------------------------------------------------------------------
// concentricRings — ported VERBATIM from patternMix.wgsl lines 83-88.
// -----------------------------------------------------------------------------
float nm_pm_concentricRings(float2 p, float t, float sm)
{
    float d = frac(length(p));
    float edge1 = smoothstep(0.5 - t * 0.5 - sm, 0.5 - t * 0.5 + sm, d);
    float edge2 = smoothstep(0.5 + t * 0.5 - sm, 0.5 + t * 0.5 + sm, d);
    return edge1 - edge2;
}

// -----------------------------------------------------------------------------
// radialLines — ported VERBATIM from patternMix.wgsl lines 91-98.
// WGSL atan2(p.y, p.x) → HLSL atan2(p.y, p.x) (same arg order).
// -----------------------------------------------------------------------------
float nm_pm_radialLines(float2 p, float t, float sm)
{
    float lineCount = max(1.0, floor(20.0 * t));
    float angle = atan2(p.y, p.x);
    float d = frac(angle / NM_PM_TAU * lineCount);
    float edge1 = smoothstep(0.5 - 0.25 - sm, 0.5 - 0.25 + sm, d);
    float edge2 = smoothstep(0.5 + 0.25 - sm, 0.5 + 0.25 + sm, d);
    return edge1 - edge2;
}

// -----------------------------------------------------------------------------
// triangularGrid — ported VERBATIM from patternMix.wgsl lines 101-115.
// -----------------------------------------------------------------------------
float nm_pm_triangularGrid(float2 p, float t, float sm)
{
    float2 skewed = float2(p.x - p.y / NM_PM_SQRT3, p.y * 2.0 / NM_PM_SQRT3);
    float2 cell = floor(skewed);
    float2 f = frac(skewed);

    float d;
    if (f.x + f.y < 1.0) {
        d = min(min(f.x, f.y), 1.0 - f.x - f.y);
    } else {
        d = min(min(1.0 - f.x, 1.0 - f.y), f.x + f.y - 1.0);
    }

    float edge = (1.0 - t) * 0.4;
    return smoothstep(edge - sm, edge + sm, d);
}

// -----------------------------------------------------------------------------
// spiralPattern — ported VERBATIM from patternMix.wgsl lines 118-125.
// WGSL atan2(p.y, p.x) → HLSL atan2(p.y, p.x).
// -----------------------------------------------------------------------------
float nm_pm_spiralPattern(float2 p, float t, float sm)
{
    float dist = length(p);
    float angle = atan2(p.y, p.x);
    float d = frac(angle / NM_PM_TAU + dist);
    float edge1 = smoothstep(0.5 - t * 0.5 - sm, 0.5 - t * 0.5 + sm, d);
    float edge2 = smoothstep(0.5 + t * 0.5 - sm, 0.5 + t * 0.5 + sm, d);
    return edge1 - edge2;
}

// -----------------------------------------------------------------------------
// nm_patternMix — core per-pixel evaluation. Ported VERBATIM from patternMix.wgsl
// main() lines 128-179. Takes the two already-sampled input colors and the
// fragment position (top-left, +0.5) plus inputTex dimensions.
// -----------------------------------------------------------------------------
float4 nm_patternMix(float4 colorA, float4 colorB, float2 fragPos, float2 dims)
{
    // Center and aspect-correct — WGSL lines 136-138
    float aspect = dims.x / dims.y;
    float2 st = fragPos / dims;
    float2 p = (st - float2(0.5, 0.5)) * 2.0;
    p.x = p.x * aspect;

    // Apply rotation — WGSL lines 141-142
    float rad = rotation * NM_PM_PI / 180.0;
    p = rotate2D(p, rad);

    // Apply scale — WGSL line 145
    p = p * (21.0 - scale);

    // Compute pattern mask — WGSL lines 148-167
    float m = 0.0;
    [branch] if (patternType == CHECKERBOARD) {
        m = nm_pm_checkerboard(p, smoothness);
    } else if (patternType == CONCENTRIC_RINGS) {
        m = nm_pm_concentricRings(p, thickness, smoothness);
    } else if (patternType == DOTS) {
        m = nm_pm_dots(p, thickness, smoothness);
    } else if (patternType == GRID) {
        m = nm_pm_grid(p, thickness, smoothness);
    } else if (patternType == HEXAGONS) {
        m = nm_pm_hexagons(p, thickness, smoothness);
    } else if (patternType == RADIAL_LINES) {
        m = nm_pm_radialLines(p, thickness, smoothness);
    } else if (patternType == SPIRAL_PATTERN) {
        m = nm_pm_spiralPattern(p, thickness, smoothness);
    } else if (patternType == STRIPES) {
        m = nm_pm_stripes(p, thickness, smoothness);
    } else if (patternType == TRIANGULAR_GRID) {
        m = nm_pm_triangularGrid(p, thickness, smoothness);
    }

    // Invert — WGSL lines 170-172
    if (invert == 1) {
        m = 1.0 - m;
    }

    // Mix: m=0 shows A, m=1 shows B — WGSL lines 175-177
    float4 color = lerp(colorA, colorB, m);
    color.a = max(colorA.a, colorB.a);

    return color;
}

#endif // NM_PATTERNMIX_INCLUDED
