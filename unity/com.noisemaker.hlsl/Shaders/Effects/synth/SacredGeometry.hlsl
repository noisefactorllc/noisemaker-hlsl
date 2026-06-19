#ifndef NM_SACREDGEOMETRY_INCLUDED
#define NM_SACREDGEOMETRY_INCLUDED

// =============================================================================
// SacredGeometry.hlsl — synth/sacredGeometry, ported PIXEL-IDENTICALLY from:
//   shaders/effects/synth/sacredGeometry/wgsl/sacredGeometry.wgsl
//
// Generator (no texture inputs). Single render pass "sacredGeometry".
//
// All helpers (rotate2D, lineSegmentSDF, outlineEdge, ripplePulse, unfoldVis,
// flowerMask, fruitMask, vesicaMask, triquetraMask, borromeanMask,
// starPolygonMask) are per-effect and ported VERBATIM INLINE.
// No helpers are shared with NMCore for this effect.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
int    geometry;        // enum: flower=0,fruit=1,metatron=3,seed=4,vesica=5,borromean=6,starPolygon=7,triquetra=8
float  scale;           // [1,20] default 10
int    rings;           // [1,6] default 3
int    starPoints;      // [5,12] default 5
float  rotation;        // degrees [-180,180] default 0
float  thickness;       // [0,1] default 0.2
float  smoothness;      // [0,1] default 0.02
float3 fgColor;         // default (1,1,1)
float3 bgColor;         // default (0,0,0)
int    animation;       // enum: none=0,rotate=1,pulse=2,ripple=4,unfold=5
int    speed;           // [-5,5] default 1
float  pulseDepth;      // [0,1] default 0.15

// Local constants matching WGSL exactly.
static const float NMSG_PI    = 3.14159265359;
static const float NMSG_TAU   = 6.28318530718;
static const float NMSG_SQRT3 = 1.7320508075688772;

static const int NMSG_ANIM_ROTATE  = 1;
static const int NMSG_ANIM_PULSE   = 2;
static const int NMSG_ANIM_RIPPLE  = 4;
static const int NMSG_ANIM_UNFOLD  = 5;

static const int NMSG_GEOM_FLOWER    = 0;
static const int NMSG_GEOM_FRUIT     = 1;
static const int NMSG_GEOM_METATRON  = 3;
static const int NMSG_GEOM_SEED      = 4;
static const int NMSG_GEOM_VESICA    = 5;
static const int NMSG_GEOM_BORROMEAN = 6;
static const int NMSG_GEOM_STARPOLYGON = 7;
static const int NMSG_GEOM_TRIQUETRA = 8;

// fn rotate2D — verbatim from WGSL
float2 nmsg_rotate2D(float2 p, float angle)
{
    float c = cos(angle);
    float s = sin(angle);
    return float2(p.x * c - p.y * s, p.x * s + p.y * c);
}

// fn lineSegmentSDF — verbatim from WGSL
float nmsg_lineSegmentSDF(float2 p, float2 a, float2 b)
{
    float2 pa = p - a;
    float2 ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}

// fn outlineEdge — verbatim; reads `smoothness` uniform
float nmsg_outlineEdge(float d, float w)
{
    return smoothstep(w + smoothness, w - smoothness, abs(d));
}

// fn ripplePulse — verbatim; reads `pulseDepth`, `time`, `speed`
float nmsg_ripplePulse(float phase)
{
    return 1.0 + pulseDepth * sin(time * NMSG_TAU * floor((float)speed) - phase);
}

// fn unfoldVis — verbatim; reads `time`, `speed`
float nmsg_unfoldVis(float t_e)
{
    return max(0.0, sin((time - t_e * 0.5) * NMSG_TAU * floor((float)speed)));
}

// fn flowerMask — verbatim from WGSL
float nmsg_flowerMask(float2 p_in, int ringsN, float figureScale)
{
    float lineWidth = 0.04 + thickness * 0.12;
    float circleRadius = 1.0;
    float2 p = p_in * figureScale;

    float m = 0.0;
    [loop]
    for (int q = -6; q <= 6; q = q + 1)
    {
        if (q < -ringsN || q > ringsN) { continue; }
        [loop]
        for (int r = -6; r <= 6; r = r + 1)
        {
            if (r < -ringsN || r > ringsN) { continue; }
            if (q + r < -ringsN || q + r > ringsN) { continue; }

            float2 center = float2((float)q + (float)r * 0.5, (float)r * NMSG_SQRT3 * 0.5);
            float hexDist = max(max(abs((float)q), abs((float)r)), abs((float)(q + r)));

            float circleR = circleRadius;
            if (animation == NMSG_ANIM_RIPPLE)
            {
                circleR = circleR * nmsg_ripplePulse(hexDist * 1.4);
            }
            float d = length(p - center) - circleR;

            float vis = 1.0;
            if (animation == NMSG_ANIM_UNFOLD)
            {
                float t_e = hexDist / max((float)ringsN, 1.0);
                vis = nmsg_unfoldVis(t_e);
            }

            m = max(m, nmsg_outlineEdge(d, lineWidth) * vis);
        }
    }
    return m;
}

// fn fruitMask — verbatim from WGSL
float nmsg_fruitMask(float2 p_in, bool drawLines)
{
    float lineWidth = 0.04 + thickness * 0.12;
    float2 p = p_in * 0.5;

    float2 centers[13];
    centers[0] = float2(0.0, 0.0);
    [loop]
    for (int k = 0; k < 6; k = k + 1)
    {
        float angle = (float)k * NMSG_PI / 3.0;
        centers[1 + k] = 2.0 * float2(cos(angle), sin(angle));
    }
    [loop]
    for (int k2 = 0; k2 < 6; k2 = k2 + 1)
    {
        float angle2 = (float)k2 * NMSG_PI / 3.0 + NMSG_PI / 6.0;
        centers[7 + k2] = 2.0 * NMSG_SQRT3 * float2(cos(angle2), sin(angle2));
    }

    float maxCircleDist = 2.0 * NMSG_SQRT3;
    float circleUnfoldRange = 1.0;
    if (drawLines)
    {
        circleUnfoldRange = 0.6;
    }

    float m = 0.0;

    [loop]
    for (int i = 0; i < 13; i = i + 1)
    {
        float distFromOrigin = length(centers[i]);

        float circleR = 1.0;
        if (animation == NMSG_ANIM_RIPPLE)
        {
            circleR = circleR * nmsg_ripplePulse(distFromOrigin * 0.8);
        }
        float d = length(p - centers[i]) - circleR;

        float vis = 1.0;
        if (animation == NMSG_ANIM_UNFOLD)
        {
            float t_e = distFromOrigin / maxCircleDist * circleUnfoldRange;
            vis = nmsg_unfoldVis(t_e);
        }

        m = max(m, nmsg_outlineEdge(d, lineWidth) * vis);
    }

    if (drawLines)
    {
        float lineVis = 1.0;
        if (animation == NMSG_ANIM_UNFOLD)
        {
            lineVis = nmsg_unfoldVis(0.65);
        }
        [loop]
        for (int ii = 0; ii < 13; ii = ii + 1)
        {
            [loop]
            for (int jj = 0; jj < 13; jj = jj + 1)
            {
                if (jj <= ii) { continue; }
                float dL = nmsg_lineSegmentSDF(p, centers[ii], centers[jj]);
                m = max(m, nmsg_outlineEdge(dL, lineWidth * 0.5) * lineVis);
            }
        }
    }

    return m;
}

// fn vesicaMask — verbatim from WGSL
float nmsg_vesicaMask(float2 p_in)
{
    float lineWidth = 0.04 + thickness * 0.12;
    float2 p = p_in * 0.25;
    float r = 1.5;
    float sep = r * 0.5;

    float rA = r;
    float rB = r;
    if (animation == NMSG_ANIM_RIPPLE)
    {
        rA = rA * nmsg_ripplePulse(0.0);
        rB = rB * nmsg_ripplePulse(NMSG_PI);
    }

    float visA = 1.0;
    float visB = 1.0;
    if (animation == NMSG_ANIM_UNFOLD)
    {
        visA = nmsg_unfoldVis(0.0);
        visB = nmsg_unfoldVis(0.5);
    }

    float dA = length(p - float2(-sep, 0.0)) - rA;
    float dB = length(p - float2( sep, 0.0)) - rB;

    float m = 0.0;
    m = max(m, nmsg_outlineEdge(dA, lineWidth) * visA);
    m = max(m, nmsg_outlineEdge(dB, lineWidth) * visB);
    return m;
}

// fn triquetraMask — verbatim from WGSL
float nmsg_triquetraMask(float2 p_in)
{
    float lineWidth = 0.04 + thickness * 0.12;
    float2 p = p_in * 0.30;
    float r = 2.25;
    float dist = r / NMSG_SQRT3;

    float2 C0 = dist * float2(cos(NMSG_PI * 0.5),                         sin(NMSG_PI * 0.5));
    float2 C1 = dist * float2(cos(NMSG_PI * 0.5 + NMSG_TAU / 3.0),        sin(NMSG_PI * 0.5 + NMSG_TAU / 3.0));
    float2 C2 = dist * float2(cos(NMSG_PI * 0.5 + 2.0 * NMSG_TAU / 3.0),  sin(NMSG_PI * 0.5 + 2.0 * NMSG_TAU / 3.0));

    float r0 = r;
    float r1 = r;
    float r2 = r;
    if (animation == NMSG_ANIM_RIPPLE)
    {
        r0 = r0 * nmsg_ripplePulse(0.0);
        r1 = r1 * nmsg_ripplePulse(NMSG_TAU / 3.0);
        r2 = r2 * nmsg_ripplePulse(2.0 * NMSG_TAU / 3.0);
    }

    float d0 = length(p - C0) - r0;
    float d1 = length(p - C1) - r1;
    float d2 = length(p - C2) - r2;

    float v01 = 1.0;
    float v02 = 1.0;
    float v12 = 1.0;
    if (animation == NMSG_ANIM_UNFOLD)
    {
        v01 = nmsg_unfoldVis(0.0);
        v02 = nmsg_unfoldVis(0.33);
        v12 = nmsg_unfoldVis(0.66);
    }

    float m = 0.0;
    m = max(m, nmsg_outlineEdge(max(d0, d1), lineWidth) * v01);
    m = max(m, nmsg_outlineEdge(max(d0, d2), lineWidth) * v02);
    m = max(m, nmsg_outlineEdge(max(d1, d2), lineWidth) * v12);
    return m;
}

// fn borromeanMask — verbatim from WGSL
float nmsg_borromeanMask(float2 p_in)
{
    float lineWidth = 0.04 + thickness * 0.12;
    float2 p = p_in * 0.32;
    float r = 1.5;
    float dist = 1.4;

    float m = 0.0;
    [loop]
    for (int i = 0; i < 3; i = i + 1)
    {
        float angle = (float)i * NMSG_TAU / 3.0 + NMSG_PI * 0.5;
        float2 c = dist * float2(cos(angle), sin(angle));

        float circleR = r;
        if (animation == NMSG_ANIM_RIPPLE)
        {
            circleR = circleR * nmsg_ripplePulse((float)i * NMSG_TAU / 3.0);
        }
        float d = length(p - c) - circleR;

        float vis = 1.0;
        if (animation == NMSG_ANIM_UNFOLD)
        {
            vis = nmsg_unfoldVis((float)i / 3.0);
        }

        m = max(m, nmsg_outlineEdge(d, lineWidth) * vis);
    }
    return m;
}

// fn starPolygonMask — verbatim from WGSL
float nmsg_starPolygonMask(float2 p_in, int n)
{
    float lineWidth = 0.04 + thickness * 0.12;
    float2 p = p_in * 0.32;
    float radius = 2.8;

    if (animation == NMSG_ANIM_RIPPLE)
    {
        radius = radius * nmsg_ripplePulse(0.0);
    }

    float m = 0.0;
    [loop]
    for (int i = 0; i < 12; i = i + 1)
    {
        if (i >= n) { break; }
        int j = (i + 2) - ((i + 2) / n) * n;
        float angle1 = (float)i * NMSG_TAU / (float)n + NMSG_PI * 0.5;
        float angle2 = (float)j * NMSG_TAU / (float)n + NMSG_PI * 0.5;
        float2 a = radius * float2(cos(angle1), sin(angle1));
        float2 b = radius * float2(cos(angle2), sin(angle2));
        float dL = nmsg_lineSegmentSDF(p, a, b);

        float vis = 1.0;
        if (animation == NMSG_ANIM_UNFOLD)
        {
            vis = nmsg_unfoldVis((float)i / (float)n);
        }

        m = max(m, nmsg_outlineEdge(dL, lineWidth) * vis);
    }
    return m;
}

// =============================================================================
// nm_sacredGeometry — core evaluation. Mirrors WGSL @fragment main() exactly.
// =============================================================================
float4 nm_sacredGeometry(float2 globalCoord)
{
    // WGSL: var st = position.xy / u.resolution
    float2 st = globalCoord / resolution;
    // WGSL: st = (st - 0.5) * 2;  st.x *= aspect
    st = (st - float2(0.5, 0.5)) * 2.0;
    st.x = st.x * aspectRatio;  // u.aspect in WGSL = fullResolution.x/fullResolution.y

    float rad = rotation * NMSG_PI / 180.0;
    st = nmsg_rotate2D(st, rad);

    if (animation == NMSG_ANIM_ROTATE)
    {
        st = nmsg_rotate2D(st, time * NMSG_TAU * floor((float)speed));
    }

    float scaleFactor = 21.0 - scale;
    if (animation == NMSG_ANIM_PULSE)
    {
        scaleFactor = scaleFactor * (1.0 + pulseDepth * sin(time * NMSG_TAU * floor((float)speed)));
    }

    float2 p = st * scaleFactor;

    float m = 0.0;
    if (geometry == NMSG_GEOM_FLOWER)
    {
        m = nmsg_flowerMask(p, rings, 0.45);
    }
    else if (geometry == NMSG_GEOM_SEED)
    {
        m = nmsg_flowerMask(p, 1, 0.23);
    }
    else if (geometry == NMSG_GEOM_FRUIT)
    {
        m = nmsg_fruitMask(p, false);
    }
    else if (geometry == NMSG_GEOM_METATRON)
    {
        m = nmsg_fruitMask(p, true);
    }
    else if (geometry == NMSG_GEOM_VESICA)
    {
        m = nmsg_vesicaMask(p);
    }
    else if (geometry == NMSG_GEOM_BORROMEAN)
    {
        m = nmsg_borromeanMask(p);
    }
    else if (geometry == NMSG_GEOM_TRIQUETRA)
    {
        m = nmsg_triquetraMask(p);
    }
    else if (geometry == NMSG_GEOM_STARPOLYGON)
    {
        m = nmsg_starPolygonMask(p, starPoints);
    }

    m = clamp(m, 0.0, 1.0);
    float3 color = lerp(bgColor, fgColor, m);
    return float4(color, 1.0);
}

#endif // NM_SACREDGEOMETRY_INCLUDED
