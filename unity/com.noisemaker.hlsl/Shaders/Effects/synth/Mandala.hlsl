#ifndef NM_MANDALA_INCLUDED
#define NM_MANDALA_INCLUDED

// =============================================================================
// Mandala.hlsl — synth/mandala, ported PIXEL-IDENTICALLY from the canonical
// WGSL source:
//   shaders/effects/synth/mandala/wgsl/mandala.wgsl
//
// N-fold symmetric mandala generator. Single render pass, no texture inputs.
//
// Helpers (floorMod, rotate2D, sdEquilateralTriangle, fillEdge, mandalaMask)
// are ported VERBATIM and INLINE per PORTING-GUIDE. Only nm_mod from NMCore
// is a shared primitive; this effect uses its own floorMod (identical math,
// inlined). All branches for animation/shape enums use [branch] at runtime.
//
// NUMERIC NOTES:
//  * st built from position.xy / resolution, then remapped to [-1,1]*aspect
//    exactly as WGSL does — divides by resolution (NOT fullResolution).
//  * floorMod: a - b * floor(a/b), matching WGSL exactly.
//  * atan2(p.y, p.x) — arg order copied literally from WGSL.
//  * floor(u.speed) in WGSL — speed is an int uniform here, cast to float.
//  * WGSL loop `for i < 12; if i >= layers break` — reproduced with [loop].
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
float  scale;           // [1,20]   default 10
float  rotation;        // [-180,180] default 0
float  thickness;       // [0,1]    default 0.2
float  smoothness;      // [0,1]    default 0.02
int    symmetry;        // [3,24]   default 12
int    bindu;           // 0|1      default 0  (boolean)
int    shape;           // 0=petal,1=triangle,2=dot  default 0
int    layers;          // [1,12]   default 6
float  layerSpacing;    // [0.5,3]  default 1.5
float  twist;           // [-45,45] default 0
float  shapeGrowth;     // [-1,1]   default 0
float3 fgColor;         // default (1,1,1)
float3 bgColor;         // default (0,0,0)
int    animation;       // 0..6     default 0
int    speed;           // [-5,5]   default 1
float  pulseDepth;      // [0,1]    default 0.15

// ---- Constants (verbatim from WGSL) -----------------------------------------
static const float NMM_PI    = 3.14159265359;
static const float NMM_TAU   = 6.28318530718;
static const float NMM_SQRT3 = 1.7320508075688772;

static const int NMM_SHAPE_PETAL    = 0;
static const int NMM_SHAPE_TRIANGLE = 1;
static const int NMM_SHAPE_DOT      = 2;

static const int NMM_ANIM_ROTATE       = 1;
static const int NMM_ANIM_PULSE        = 2;
static const int NMM_ANIM_DIFFERENTIAL = 3;
static const int NMM_ANIM_COUNTERROTATE = 4;
static const int NMM_ANIM_SPIRALWAVE   = 5;
static const int NMM_ANIM_RIPPLE       = 6;

// ---- floorMod (GLSL-style mod, always non-negative when b > 0) --------------
// Verbatim from WGSL: a - b * floor(a / b)
float nmm_floorMod(float a, float b)
{
    return a - b * floor(a / b);
}

// ---- rotate2D (mandala's own version) ---------------------------------------
// WGSL: vec2<f32>(p.x*c - p.y*s, p.x*s + p.y*c)
float2 nmm_rotate2D(float2 p, float angle)
{
    float c = cos(angle);
    float s = sin(angle);
    return float2(p.x * c - p.y * s, p.x * s + p.y * c);
}

// ---- sdEquilateralTriangle --------------------------------------------------
// Verbatim from WGSL.
float nmm_sdEquilateralTriangle(float2 p_in, float r)
{
    float k = NMM_SQRT3;
    float2 p = float2(abs(p_in.x) - r, p_in.y + r / k);
    if (p.x + k * p.y > 0.0)
    {
        p = float2(p.x - k * p.y, -k * p.x - p.y) / 2.0;
    }
    p.x = p.x - clamp(p.x, -2.0 * r, 0.0);
    return -length(p) * sign(p.y);
}

// ---- fillEdge ---------------------------------------------------------------
// WGSL: smoothstep(u.smoothness, -u.smoothness, d)
float nmm_fillEdge(float d)
{
    return smoothstep(smoothness, -smoothness, d);
}

// ---- mandalaMask ------------------------------------------------------------
float nmm_mandalaMask(float2 p)
{
    float r = length(p);
    float theta = atan2(p.y, p.x) - NMM_PI * 0.5;
    float wedge = NMM_TAU / (float)symmetry;
    float twistRad = twist * NMM_PI / 180.0;
    float baseSize = 0.25 + thickness * 0.65;

    // spiralWave: twist oscillates over the cycle using `twist` as amplitude.
    float dynTwistRad = twistRad;
    [branch]
    if (animation == NMM_ANIM_SPIRALWAVE)
    {
        dynTwistRad = twistRad * sin(time * NMM_TAU * floor((float)speed));
    }

    float m = 0.0;

    [branch]
    if (bindu != 0)
    {
        float dBindu = length(p) - (0.15 + thickness * 0.15);
        m = max(m, nmm_fillEdge(dBindu));
    }

    [loop]
    for (int i = 0; i < 12; i = i + 1)
    {
        if (i >= layers) { break; }
        float Rlayer = (float)(i + 1) * layerSpacing;

        // Per-layer animation rotation.
        float layerAnimRot = 0.0;
        [branch]
        if (animation == NMM_ANIM_DIFFERENTIAL)
        {
            layerAnimRot = time * NMM_TAU * (floor((float)speed) + (float)i);
        }
        else if (animation == NMM_ANIM_COUNTERROTATE)
        {
            float dir = 1.0;
            if (nmm_floorMod((float)i, 2.0) >= 0.5)
            {
                dir = -1.0;
            }
            layerAnimRot = time * NMM_TAU * floor((float)speed) * dir;
        }

        float layerTheta = theta - (float)i * dynTwistRad - layerAnimRot;
        float folded = abs(nmm_floorMod(layerTheta + wedge * 0.5, wedge) - wedge * 0.5);
        float radial  = r - Rlayer;
        float tangent = folded * Rlayer;

        float lt = 0.0;
        if (layers > 1)
        {
            lt = (float)i / (float)(layers - 1) - 0.5;
        }
        float shapeSize = baseSize * (1.0 + shapeGrowth * lt);

        // ripple: per-layer pulse with phase offset.
        [branch]
        if (animation == NMM_ANIM_RIPPLE)
        {
            shapeSize = shapeSize * (1.0 + pulseDepth * sin(time * NMM_TAU * floor((float)speed) - (float)i * 0.6));
        }

        [branch]
        if (shape == NMM_SHAPE_PETAL)
        {
            float d = length(float2(radial * 0.55, tangent)) - shapeSize;
            m = max(m, nmm_fillEdge(d));
        }
        else if (shape == NMM_SHAPE_TRIANGLE)
        {
            float2 q = float2(tangent, -radial);
            float d = nmm_sdEquilateralTriangle(q, shapeSize);
            m = max(m, nmm_fillEdge(d));
        }
        else
        {
            float d = length(float2(radial, tangent)) - shapeSize * 0.7;
            m = max(m, nmm_fillEdge(d));
        }
    }
    return m;
}

// =============================================================================
// nm_mandala — core per-pixel evaluation. fragCoord is position.xy (top-left).
// Mirrors WGSL main() exactly.
// =============================================================================
float4 nm_mandala(float2 fragCoord)
{
    // WGSL: st = position.xy / resolution  (divides by current render-target size)
    float2 st = fragCoord / resolution;
    st = (st - float2(0.5, 0.5)) * 2.0;
    st.x = st.x * aspectRatio;

    float rad = rotation * NMM_PI / 180.0;
    st = nmm_rotate2D(st, rad);

    [branch]
    if (animation == NMM_ANIM_ROTATE)
    {
        st = nmm_rotate2D(st, time * NMM_TAU * floor((float)speed));
    }

    float scaleFactor = 21.0 - scale;
    [branch]
    if (animation == NMM_ANIM_PULSE)
    {
        scaleFactor = scaleFactor * (1.0 + pulseDepth * sin(time * NMM_TAU * floor((float)speed)));
    }

    float2 p = st * scaleFactor;

    float m = clamp(nmm_mandalaMask(p), 0.0, 1.0);
    float3 color = lerp(bgColor, fgColor, m);
    return float4(color, 1.0);
}

#endif // NM_MANDALA_INCLUDED
