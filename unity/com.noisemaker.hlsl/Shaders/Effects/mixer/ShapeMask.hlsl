#ifndef NM_SHAPEMASK_INCLUDED
#define NM_SHAPEMASK_INCLUDED

// =============================================================================
// ShapeMask.hlsl — mixer/shapeMask, ported PIXEL-IDENTICALLY from the canonical
// WGSL:  shaders/effects/mixer/shapeMask/wgsl/shapeMask.wgsl
//
// Composites two inputs (A = inputTex, B = tex) inside/outside a geometric SDF
// shape. Single render pass (definition.js passes[].length == 1, prog "shapeMask").
//
// PORTING-GUIDE notes:
//  * All SDF helpers (rotate2D, sdfCircle, sdfPolygon, sdfTriangle, sdfFlower,
//    sdfStar5, sdfRing) are this effect's OWN per-effect copies, ported VERBATIM
//    inline (golden rule 2). Do not substitute from any shared lib.
//  * sdfFlower uses WGSL `a % seg` — float modulo, translated as nm_mod(a,seg).
//    sdfStar5 uses WGSL p_in; HLSL requires explicit var-name matching; uses p_in.
//  * `shape`, `invert`, `speed`: int uniforms (definition.js type:"int"). Branch
//    at runtime with [branch] per porting-guide.
//  * UV/coord: WGSL derives `dims` from inputTex, `st = position.xy / dims`, and
//    uses the SAME st to sample BOTH inputTex and tex. `aspect = dims.x / dims.y`
//    from inputTex's own dimensions (NOT fullResolution) to match WGSL exactly.
//  * Position p: centered `(st - 0.5) * 2`, x scaled by aspect, then offset by
//    (posX*aspect, -posY), then rotated. Follow WGSL literally.
//  * `time` provided by NMFullscreen.hlsl alias for _NM_Time (identical binding).
//  * mix -> lerp; a % b -> nm_mod(a,b); atan2(x,y) arg order preserved literally.
//  * No PRNG/PCG in this effect — no bit-cast hazards.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
int   shape;       // 0=circle 1=triangle 2=square 3=pentagon 4=hexagon 5=flower 6=ring 7=star
float radius;      // 0..1, default 0.7
float edgeSmooth;  // 0..0.25, default 0.01
float rotation;    // -180..180 degrees, default 0
float posX;        // -1..1, default 0
float posY;        // -1..1, default 0
int   invert;      // 0=sourceA inside, 1=sourceB inside, default 0
int   speed;       // 0..4, default 0

// ---- Constants (mirroring WGSL `const`) -----
static const float NM_SM_PI  = 3.14159265359;
static const float NM_SM_TAU = 6.28318530718;

// -----------------------------------------------------------------------------
// rotate2D — ported VERBATIM from shapeMask.wgsl. Per-effect copy.
// -----------------------------------------------------------------------------
float2 rotate2D(float2 p, float angle)
{
    float c = cos(angle);
    float s = sin(angle);
    return float2(p.x * c - p.y * s, p.x * s + p.y * c);
}

// -----------------------------------------------------------------------------
// sdfCircle — ported VERBATIM from shapeMask.wgsl. Per-effect copy.
// -----------------------------------------------------------------------------
float sdfCircle(float2 p, float r)
{
    return length(p) - r;
}

// -----------------------------------------------------------------------------
// sdfPolygon — ported VERBATIM from shapeMask.wgsl. Per-effect copy.
// WGSL: atan2(p.x, p.y)  — arg order preserved literally (H3).
// -----------------------------------------------------------------------------
float sdfPolygon(float2 p, float r, float sides)
{
    float a = atan2(p.x, p.y) + NM_SM_PI;
    float seg = NM_SM_TAU / sides;
    return cos(floor(0.5 + a / seg) * seg - a) * length(p) - r;
}

// -----------------------------------------------------------------------------
// sdfTriangle — ported VERBATIM from shapeMask.wgsl. Per-effect copy.
// WGSL uses a mutable `p` var (p.x and p.y reassigned). Translated to a local
// float2 var.
// -----------------------------------------------------------------------------
float sdfTriangle(float2 p_in, float r)
{
    float k = 1.732050808; // sqrt(3)
    float2 p = float2(abs(p_in.x) - r, p_in.y + r / k);
    if (p.x + k * p.y > 0.0) { p = float2(p.x - k * p.y, -k * p.x - p.y) / 2.0; }
    p.x -= clamp(p.x, -2.0 * r, 0.0);
    return -length(p) * sign(p.y);
}

// -----------------------------------------------------------------------------
// sdfFlower — ported VERBATIM from shapeMask.wgsl. Per-effect copy.
// WGSL `a % seg` is float modulo -> nm_mod(a, seg) (never fmod, rule H6).
// WGSL: atan2(p.x, p.y) — arg order preserved literally (H3).
// WGSL: mix -> lerp.
// -----------------------------------------------------------------------------
float sdfFlower(float2 p, float r)
{
    float outerR = r;
    float innerR = r * 0.45;
    float a = atan2(p.x, p.y) + NM_SM_PI;
    float seg = NM_SM_TAU / 5.0;
    float halfSeg = seg * 0.5;
    float segAngle = nm_mod(a, seg);
    float t = abs(segAngle - halfSeg) / halfSeg;
    float starR = lerp(innerR, outerR, t);
    return length(p) - starR;
}

// -----------------------------------------------------------------------------
// sdfStar5 — ported VERBATIM from shapeMask.wgsl. Per-effect copy.
// WGSL: `var p = vec2<f32>(abs(p_in.x), p_in.y)` — copy of p_in, then mutated.
// -----------------------------------------------------------------------------
float sdfStar5(float2 p_in, float r)
{
    float rf = 0.4;
    float2 k1 = float2(0.809016994375, -0.587785252292);
    float2 k2 = float2(-k1.x, k1.y);
    float2 p = float2(abs(p_in.x), p_in.y);
    p -= 2.0 * max(dot(k1, p), 0.0) * k1;
    p -= 2.0 * max(dot(k2, p), 0.0) * k2;
    p.x = abs(p.x);
    p.y -= r;
    float2 ba = rf * float2(-k1.y, k1.x) - float2(0.0, 1.0);
    float h = clamp(dot(p, ba) / dot(ba, ba), 0.0, r);
    return length(p - ba * h) * sign(p.y * ba.x - p.x * ba.y);
}

// -----------------------------------------------------------------------------
// sdfRing — ported VERBATIM from shapeMask.wgsl. Per-effect copy.
// -----------------------------------------------------------------------------
float sdfRing(float2 p, float r)
{
    float ringWidth = r * 0.15;
    return abs(length(p) - r) - ringWidth;
}

// -----------------------------------------------------------------------------
// nm_shapeMask — core per-pixel evaluation. Takes the two already-sampled input
// colors plus the fragment's SDF coordinate (aspect-correct, centered, rotated)
// and the animated radius. Returns composited RGBA.
// Ported VERBATIM from shapeMask.wgsl main() lines 99-131.
// -----------------------------------------------------------------------------
float4 nm_shapeMask(float4 colorA, float4 colorB, float2 p, float r)
{
    // Evaluate SDF
    float d = 0.0;
    [branch] if (shape == 0) {
        d = sdfCircle(p, r);
    } else if (shape == 1) {
        d = sdfTriangle(p, r);
    } else if (shape == 2) {
        d = sdfPolygon(p, r, 4.0);
    } else if (shape == 3) {
        d = sdfPolygon(p, r, 5.0);
    } else if (shape == 4) {
        d = sdfPolygon(p, r, 6.0);
    } else if (shape == 5) {
        d = sdfFlower(p, r);
    } else if (shape == 6) {
        d = sdfRing(p, r);
    } else if (shape == 7) {
        d = sdfStar5(p, r);
    }

    // Smoothstep mask: 0 inside shape, 1 outside
    float mask = smoothstep(-edgeSmooth, edgeSmooth, d);

    // Invert swaps inside/outside
    [branch] if (invert == 1) {
        mask = 1.0 - mask;
    }

    // A inside shape, B outside (before invert)
    float4 color = lerp(colorA, colorB, mask);
    color.a = max(colorA.a, colorB.a);

    return color;
}

#endif // NM_SHAPEMASK_INCLUDED
