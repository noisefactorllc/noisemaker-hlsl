#ifndef NM_PATTERN_INCLUDED
#define NM_PATTERN_INCLUDED

// =============================================================================
// Pattern.hlsl — synth/pattern, ported PIXEL-IDENTICALLY from the canonical
// WGSL source:
//   shaders/effects/synth/pattern/wgsl/pattern.wgsl
//
// Geometric pattern generator: checkerboard, concentricRings, dots, grid,
// hearts, hexagons, radialLines, spiral, stripes, triangularGrid, waves, zigzag.
//
// All helpers (rotate2D, stripes, checkerboard, grid, dots, hexDist, hexagons,
// concentricRings, radialLines, triangularGrid, spiralPattern, heartSDF, hearts,
// waves, zigzag) are ported VERBATIM and INLINE per PORTING-GUIDE.
//
// NUMERIC HAZARDS handled:
//  * nm_mod used for float % (hexagons a/b = p % s), not fmod.
//  * atan2(y,x) arg order copied literally from WGSL.
//  * WGSL select(falseVal, trueVal, cond) -> HLSL ternary cond ? trueVal : falseVal.
//  * floor(u.speed) — speed is int; cast to float before floor.
//  * st computed as (position.xy / resolution) centered/aspect, divides by resolution
//    (not fullResolution) matching the WGSL which uses u.resolution directly.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
int    patternType;     // enum 0..11                     (global "type")
float  scale;           // [1,20], default 15             (global "scale")
float  thickness;       // [0,1], default 0.5             (global "thickness")
float  smoothness;      // [0,1], default 0.02            (global "smoothness")
float  rotation;        // degrees [-180,180], default 0  (global "rotation")
float  skew;            // [-2,2], default 0              (global "skew")
int    animation;       // enum 0=none,1=pan,2=rotate     (global "animation")
int    speed;           // [-5,5], default 1              (global "speed")
float3 fgColor;         // default (1,1,1)                (global "fgColor")
float3 bgColor;         // default (0,0,0)                (global "bgColor")

// Local constants exactly as the WGSL declares them.
static const float NMP_PI    = 3.14159265359;
static const float NMP_SQRT3 = 1.7320508075688772;
static const float NMP_TAU   = 6.28318530718;

// Pattern-type constants (mirrors WGSL)
#define NMP_CHECKERBOARD   0
#define NMP_CONCENTRIC     1
#define NMP_DOTS           2
#define NMP_GRID           3
#define NMP_HEXAGONS       4
#define NMP_RADIAL_LINES   5
#define NMP_SPIRAL         6
#define NMP_STRIPES        7
#define NMP_TRIANGULAR     8
#define NMP_HEARTS         9
#define NMP_WAVES          10
#define NMP_ZIGZAG         11

// ---- rotate2D (verbatim from WGSL) ------------------------------------------
float2 nmp_rotate2D(float2 p, float angle)
{
    float c = cos(angle);
    float s = sin(angle);
    return float2(p.x * c - p.y * s, p.x * s + p.y * c);
}

// ---- stripes (verbatim) -----------------------------------------------------
float nmp_stripes(float2 p, float t, float sm)
{
    float stripe = frac(p.x);
    float edge1 = smoothstep(0.5 - t * 0.5 - sm, 0.5 - t * 0.5 + sm, stripe);
    float edge2 = smoothstep(0.5 + t * 0.5 - sm, 0.5 + t * 0.5 + sm, stripe);
    return edge1 - edge2;
}

// ---- checkerboard (verbatim) ------------------------------------------------
float nmp_checkerboard(float2 p, float sm)
{
    float2 f = frac(p);
    float d = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
    float2 cell = floor(p);
    // WGSL: (cell.x + cell.y) % 2.0  — float modulo via nm_mod
    float check = nm_mod(cell.x + cell.y, 2.0);
    float edge = smoothstep(0.0, sm * 0.5, d);
    return lerp(1.0 - check, check, edge);
}

// ---- grid (verbatim) --------------------------------------------------------
float nmp_grid(float2 p, float t, float sm)
{
    float2 f = frac(p);
    float lineX = smoothstep(t * 0.5 - sm, t * 0.5 + sm, abs(f.x - 0.5));
    float lineY = smoothstep(t * 0.5 - sm, t * 0.5 + sm, abs(f.y - 0.5));
    return 1.0 - min(lineX, lineY);
}

// ---- dots (verbatim) --------------------------------------------------------
float nmp_dots(float2 p, float t, float sm)
{
    float2 f = frac(p) - float2(0.5, 0.5);
    float d = length(f);
    float radius = t * 0.5;
    return 1.0 - smoothstep(radius - sm, radius + sm, d);
}

// ---- hexDist (verbatim) -----------------------------------------------------
float nmp_hexDist(float2 p)
{
    float2 ap = abs(p);
    return max(ap.x * 0.5 + ap.y * (NMP_SQRT3 / 2.0), ap.x);
}

// ---- hexagons (verbatim; WGSL % on float2 = nm_mod per axis) ----------------
float nmp_hexagons(float2 p, float t, float sm)
{
    float2 s = float2(1.0, NMP_SQRT3);
    float2 h = s * 0.5;

    // WGSL: (p % s) - h  and  ((p + h) % s) - h
    float2 a = float2(nm_mod(p.x, s.x), nm_mod(p.y, s.y)) - h;
    float2 b = float2(nm_mod(p.x + h.x, s.x), nm_mod(p.y + h.y, s.y)) - h;

    float2 g;
    [branch]
    if (length(a) < length(b))
        g = a;
    else
        g = b;

    float d = nmp_hexDist(g);
    float edge = 0.5 * t;
    return smoothstep(edge + sm, edge - sm, d);
}

// ---- concentricRings (verbatim) ---------------------------------------------
float nmp_concentricRings(float2 p, float t, float sm, float timeOffset)
{
    float d = frac(length(p) + timeOffset);
    float edge1 = smoothstep(0.5 - t * 0.5 - sm, 0.5 - t * 0.5 + sm, d);
    float edge2 = smoothstep(0.5 + t * 0.5 - sm, 0.5 + t * 0.5 + sm, d);
    return edge1 - edge2;
}

// ---- radialLines (verbatim; uses global u.scale via floor(scale)) -----------
float nmp_radialLines(float2 p, float t, float sm, float timeOffset)
{
    float lineCount = floor(scale);
    float angle = atan2(p.y, p.x) + timeOffset * NMP_TAU;
    float d = frac(angle / NMP_TAU * lineCount);
    float edge1 = smoothstep(0.5 - t * 0.5 - sm, 0.5 - t * 0.5 + sm, d);
    float edge2 = smoothstep(0.5 + t * 0.5 - sm, 0.5 + t * 0.5 + sm, d);
    return edge1 - edge2;
}

// ---- triangularGrid (verbatim) ----------------------------------------------
float nmp_triangularGrid(float2 p, float t, float sm)
{
    float2 skewed = float2(p.x - p.y / NMP_SQRT3, p.y * 2.0 / NMP_SQRT3);
    // float2 cell = floor(skewed);  // unused but present in WGSL
    float2 f = frac(skewed);

    float d;
    [branch]
    if (f.x + f.y < 1.0)
        d = min(min(f.x, f.y), 1.0 - f.x - f.y);
    else
        d = min(min(1.0 - f.x, 1.0 - f.y), f.x + f.y - 1.0);

    float edge = (1.0 - t) * 0.4;
    return smoothstep(edge - sm, edge + sm, d);
}

// ---- spiralPattern (verbatim) -----------------------------------------------
float nmp_spiralPattern(float2 p, float t, float sm, float timeOffset)
{
    float dist = length(p);
    float angle = atan2(p.y, p.x) + timeOffset * NMP_TAU;
    float d = frac(angle / NMP_TAU + dist);
    float edge1 = smoothstep(0.5 - t * 0.5 - sm, 0.5 - t * 0.5 + sm, d);
    float edge2 = smoothstep(0.5 + t * 0.5 - sm, 0.5 + t * 0.5 + sm, d);
    return edge1 - edge2;
}

// ---- heartSDF (verbatim; based on Inigo Quilez) -----------------------------
float nmp_heartSDF(float2 p_in)
{
    float2 p = float2(abs(p_in.x), p_in.y);
    [branch]
    if (p.y + p.x > 1.0)
    {
        float2 d = p - float2(0.25, 0.75);
        return sqrt(dot(d, d)) - sqrt(2.0) / 4.0;
    }
    float2 d1 = p - float2(0.0, 1.0);
    float proj = 0.5 * max(p.x + p.y, 0.0);
    float2 d2 = p - proj;
    return sqrt(min(dot(d1, d1), dot(d2, d2))) * sign(p.x - p.y);
}

// ---- hearts (verbatim) ------------------------------------------------------
float nmp_hearts(float2 p, float t, float sm)
{
    float2 cell = frac(p) - 0.5;
    cell.y += 0.25;
    float d = nmp_heartSDF(cell * 2.4);
    float radius = 0.15 - (t * 0.15);
    float s = min(sm, radius + 0.15);
    return 1.0 - smoothstep(-radius - s, -radius + s, d);
}

// ---- waves (verbatim) -------------------------------------------------------
float nmp_waves(float2 p, float t, float sm)
{
    float y = frac(p.y) - 0.5;
    y -= cos(p.x * NMP_TAU) * 0.15;
    float dist = abs(y);
    float halfW = t * 0.2;
    float s = min(sm, halfW + 0.01);
    return 1.0 - smoothstep(halfW - s, halfW + s, dist);
}

// ---- zigzag (verbatim) ------------------------------------------------------
float nmp_zigzag(float2 p, float t, float sm)
{
    float2 f = frac(p);
    float lineY = 1.0 - 2.0 * abs(f.x - 0.5);
    float dist = abs(f.y - lineY * 0.5 - 0.25);
    float halfW = t * 0.12;
    float s = min(sm, max(0.24 - halfW, 0.005));
    return 1.0 - smoothstep(halfW - s, halfW + s, dist);
}

// =============================================================================
// nm_pattern — core per-pixel evaluation. `fragCoord` is position.xy (pixel
// center, top-left). Returns RGBA. Mirrors WGSL main() exactly.
// =============================================================================
float4 nm_pattern(float2 fragCoord)
{
    // Normalize coordinates: WGSL uses u.resolution (the render-target size).
    float2 st = fragCoord / resolution;
    st = (st - float2(0.5, 0.5)) * 2.0;
    // WGSL: st.x = st.x * u.aspect. pipeline.js sets u.aspect == aspectRatio ==
    // fullResolution.x/fullResolution.y (verified), so the NMFullscreen alias matches.
    st.x = st.x * aspectRatio;

    // Apply rotation
    float rad = rotation * NMP_PI / 180.0;
    st = nmp_rotate2D(st, rad);

    // centered types check
    bool centered = (patternType == NMP_CONCENTRIC) ||
                    (patternType == NMP_RADIAL_LINES) ||
                    (patternType == NMP_SPIRAL);

    // Animation rotate (non-centered only)
    [branch]
    if (!centered && animation == 2)
    {
        st = nmp_rotate2D(st, time * NMP_TAU * floor((float)speed));
    }

    // Horizontal shear
    st.x = st.x + st.y * skew;

    // Apply scale
    float2 p = st * (21.0 - scale);

    [branch]
    if (!centered && animation == 1)
    {
        // WGSL: select(1.0, 2.0, patternType == CHECKERBOARD)
        // select(falseVal, trueVal, cond) -> HLSL: cond ? trueVal : falseVal
        float panPeriod = (patternType == NMP_CHECKERBOARD) ? 2.0 : 1.0;
        p.x += time * -floor((float)speed) * panPeriod;
    }

    // Compute pattern value
    float m = 0.0;

    [branch]
    if (patternType == NMP_CHECKERBOARD)
        m = nmp_checkerboard(p, smoothness);
    else if (patternType == NMP_CONCENTRIC)
        m = nmp_concentricRings(p, thickness, smoothness, -time * floor((float)speed));
    else if (patternType == NMP_DOTS)
        m = nmp_dots(p, thickness, smoothness);
    else if (patternType == NMP_GRID)
        m = nmp_grid(p, thickness, smoothness);
    else if (patternType == NMP_HEXAGONS)
        m = nmp_hexagons(p, thickness, smoothness);
    else if (patternType == NMP_RADIAL_LINES)
        m = nmp_radialLines(p, thickness, smoothness, time * floor((float)speed));
    else if (patternType == NMP_SPIRAL)
        m = nmp_spiralPattern(p, thickness, smoothness, -time * floor((float)speed));
    else if (patternType == NMP_STRIPES)
        m = nmp_stripes(p, thickness, smoothness);
    else if (patternType == NMP_TRIANGULAR)
        m = nmp_triangularGrid(p, thickness, smoothness);
    else if (patternType == NMP_HEARTS)
        m = nmp_hearts(p, thickness, smoothness);
    else if (patternType == NMP_WAVES)
        m = nmp_waves(p, thickness, smoothness);
    else if (patternType == NMP_ZIGZAG)
        m = nmp_zigzag(p, thickness, smoothness);

    // Mix colors
    float3 color = lerp(bgColor, fgColor, m);
    return float4(color, 1.0);
}

#endif // NM_PATTERN_INCLUDED
