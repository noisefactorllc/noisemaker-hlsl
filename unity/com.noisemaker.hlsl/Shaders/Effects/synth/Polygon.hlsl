#ifndef NM_POLYGON_INCLUDED
#define NM_POLYGON_INCLUDED

// =============================================================================
// Polygon.hlsl — synth/polygon, ported PIXEL-IDENTICALLY from the canonical
// WGSL source:
//   shaders/effects/synth/polygon/wgsl/shape.wgsl
//
// Geometric polygon shape generator using a regular polygon SDF built from
// polar math. Single fullscreen pass ("shape"), no texture inputs.
//
// No per-effect helpers beyond the inline polygon() SDF — no shared color/dist
// libs are needed. The atan2 call copies WGSL arg order literally (y, x).
// The triangle-up rotation branch uses [branch] to match WGSL if (sides==3).
//
// NUMERIC HAZARDS handled:
//  * st = position.xy / resolution  (divides by resolution vec2; WGSL main uses
//    resolution, not fullResolution — followed literally)
//  * st = (st - 0.5) * 2.0, then st.x *= aspect
//  * rotation in degrees; converted to radians as rotation * PI / 180.0
//  * polygon SDF uses atan2(st.y, st.x) + 3.14159265 (PI literal from WGSL)
//  * nm_mod not used here (no float-mod in this effect)
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
int    sides;      // [3,64], default 3
float  radius;     // [0,1],  default 0.5
float  smoothing;  // [0,1],  default 0.01  (uniform name "smoothing", param "smooth")
float  rotation;   // [-180,180], default 0 (degrees)
float3 fgColor;    // default (1,1,1)
float  fgAlpha;    // [0,1],  default 1.0
float3 bgColor;    // default (0,0,0)
float  bgAlpha;    // [0,1],  default 1.0

static const float NMP_PI = 3.14159265359;

// ---- polygon SDF (verbatim from WGSL, atan2 arg order literal) --------------
// Returns the polygon distance field value for a point `st` and `sides` sides.
float nm_polygon_sdf(float2 st, float sides_f)
{
    float a = atan2(st.y, st.x) + 3.14159265;
    float r = 6.2831853 / sides_f;
    return cos(floor(0.5 + a / r) * r - a) * length(st);
}

// =============================================================================
// nm_polygon — core per-pixel evaluation. `globalCoord` is the fragment's
// pixel coordinate (i.e. NM_GlobalCoord(i)). `res` is the resolution vec2.
// Returns premultiplied RGBA, matching WGSL main() exactly.
// =============================================================================
float4 nm_polygon(float2 globalCoord, float2 res, float aspect_in)
{
    float2 st = globalCoord / res;
    st = (st - float2(0.5, 0.5)) * 2.0;
    st.x *= aspect_in;

    // Apply rotation (degrees -> radians)
    float c = cos(rotation * NMP_PI / 180.0);
    float s = sin(rotation * NMP_PI / 180.0);
    st = float2(st.x * c - st.y * s, st.x * s + st.y * c);

    float sidesF = (float)max(sides, 3);

    // Rotate triangle so vertex points up (WGSL: if (sides == 3))
    [branch]
    if (sides == 3)
    {
        st = float2(st.y, -st.x);
    }

    // Normalize by inradius so all shapes have consistent size
    float d = nm_polygon_sdf(st, sidesF) / cos(NMP_PI / sidesF);
    float m = smoothstep(radius, radius - smoothing, d);

    // fgAlpha scales foreground visibility, bgAlpha scales background visibility
    float fgMask    = m * fgAlpha;
    float bgMask    = (1.0 - m) * bgAlpha;
    float totalAlpha = fgMask + bgMask;

    // Compute color as weighted blend (for non-zero alpha)
    float3 outColor;
    // WGSL: if (totalAlpha > 0.0) { ... } else { vec3(0.0) }
    [branch]
    if (totalAlpha > 0.0)
    {
        outColor = (fgColor * fgMask + bgColor * bgMask) / totalAlpha;
    }
    else
    {
        outColor = float3(0.0, 0.0, 0.0);
    }

    // Output premultiplied alpha for correct compositing
    return float4(outColor * totalAlpha, totalAlpha);
}

#endif // NM_POLYGON_INCLUDED
