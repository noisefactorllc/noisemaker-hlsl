#ifndef NM_TILE_INCLUDED
#define NM_TILE_INCLUDED

// =============================================================================
// Tile.hlsl — filter/tile, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/tile/wgsl/tile.wgsl
//
// Symmetry-based kaleidoscope tiler. Single render pass. Samples inputTex using
// a folded/tiled UV derived from the input texture's own dimensions.
//
// WGSL coordinate model:
//   texSize = vec2<f32>(textureDimensions(inputTex))   // input tex px size
//   uv      = position.xy / texSize                    // 0..1 over input tex
//   asp     = texSize.x / texSize.y                    // input tex aspect ratio
//
// NOTE: the GLSL uses globalCoord / fullResolution; the WGSL uses
// position.xy / textureDimensions(inputTex). WGSL is canonical — we follow it.
//
// Helpers rot, mirrorFold, fract2, mod2, hexCoord, rotationalFold are all
// private to this effect and are inlined verbatim from the WGSL.
//
// PORTING-GUIDE notes / hazards:
//  * WGSL select(b,a,c) is reversed vs ternary. Line:
//      rep = select(vec2<f32>(repeat), vec2<f32>(repeat*asp,repeat), doAspect)
//    means: doAspect ? (repeat*asp, repeat) : (repeat, repeat) — handled below.
//  * WGSL ((a + TAU) % TAU) % sectorAngle uses float %, which is nm_mod in HLSL.
//  * No PCG/PRNG in this effect.
//  * Full 32-bit float throughout.
//  * aspectLens is bool-as-int: declared int, tested != 0.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
int   symmetry;   // 0=mirrorXY, 1=rotate2, 2=rotate4, 3=rotate6  default 0
float scale;      // [0.1, 4.0]  default 1.0
float offsetX;    // [-1, 1]     default 0.0
float offsetY;    // [-1, 1]     default 0.0
float angle;      // [0, 360]    default 0.0
float repeat;     // [1, 10]     default 2.0
int   aspectLens; // bool-as-int (1 = true)                         default 1

static const float NM_TILE_PI  = 3.14159265359;
static const float NM_TILE_TAU = 6.28318530718;

// Rotate 2D point around origin by radians.
// WGSL: fn rot(p, a) -> vec2<f32>
float2 nm_tile_rot(float2 p, float a)
{
    float c = cos(a);
    float s = sin(a);
    return float2(p.x * c - p.y * s, p.x * s + p.y * c);
}

// Mirror fold: maps [0,1] so edges have the same value.
// WGSL: fn mirrorFold(t) -> 1.0 - abs(2.0 * fract(t * 0.5) - 1.0)
float nm_tile_mirrorFold(float t)
{
    return 1.0 - abs(2.0 * frac(t * 0.5) - 1.0);
}

// WGSL: fn fract2(v) -> v - floor(v)
float2 nm_tile_fract2(float2 v)
{
    return v - floor(v);
}

// WGSL: fn mod2(v, m) -> v - m * floor(v / m)
float2 nm_tile_mod2(float2 v, float2 m)
{
    return v - m * floor(v / m);
}

// Hex grid: returns local coords relative to nearest hex center.
// WGSL: fn hexCoord(uv) -> vec2<f32>
float2 nm_tile_hexCoord(float2 uv)
{
    float2 s = float2(1.0, 1.7320508);
    float2 h = s * 0.5;

    float2 a = nm_tile_mod2(uv,     s) - h;
    float2 b = nm_tile_mod2(uv + h, s) - h;

    if (dot(a, a) < dot(b, b))
        return a;
    else
        return b;
}

// Fold UV into the first sector of a rotational n-fold symmetry.
// WGSL: fn rotationalFold(uv, n: i32) -> vec2<f32>
// WGSL: a = ((a + TAU) % TAU) % sectorAngle  — float modulo -> nm_mod
float2 nm_tile_rotationalFold(float2 uv, int n)
{
    float fn_val = (float)n;
    float sectorAngle = NM_TILE_TAU / fn_val;

    float2 p = uv - 0.5;
    float a = atan2(p.y, p.x);  // WGSL: atan2(p.y, p.x) — arg order kept verbatim
    float r = length(p);

    a = nm_mod(nm_mod(a + NM_TILE_TAU, NM_TILE_TAU), sectorAngle);
    if (a > sectorAngle * 0.5)
    {
        a = sectorAngle - a;
    }

    return float2(r * cos(a), r * sin(a)) + 0.5;
}

// =============================================================================
// nm_tile_frag — core per-pixel evaluation. Mirror of the WGSL main() body.
//   texSize  : input texture pixel dimensions (float2)
//   fragCoord: NM_FragCoord(i) — top-left, +0.5 centered pixel coordinate
// =============================================================================
float4 nm_tile_frag(Texture2D inputTex, SamplerState samp, float2 fragCoord, float2 texSize)
{
    // WGSL: uv = position.xy / texSize
    float2 uv = fragCoord / texSize;
    // WGSL: asp = texSize.x / texSize.y
    float asp = texSize.x / texSize.y;
    bool doAspect = (aspectLens != 0);

    // Rotate in aspect-corrected space to avoid shearing on non-square canvases.
    // WGSL body verbatim (with bool branch):
    float2 st = uv - 0.5;
    if (doAspect) { st.x *= asp; }
    st = nm_tile_rot(st, angle * NM_TILE_PI / 180.0);
    if (doAspect) { st.x /= asp; }
    st += 0.5;

    // Aspect-corrected repeat count.
    // WGSL: select(vec2<f32>(repeat), vec2<f32>(repeat * asp, repeat), doAspect)
    //   = doAspect ? (repeat*asp, repeat) : (repeat, repeat)
    float2 rep = doAspect ? float2(repeat * asp, repeat) : float2(repeat, repeat);

    if (symmetry == 3)
    {
        // Hex tiling with 6-fold rotational symmetry.
        float2 local_hex    = nm_tile_hexCoord((st + float2(offsetX, offsetY)) * rep);
        float2 local_scaled = local_hex / scale;
        st = nm_tile_rotationalFold(local_scaled + 0.5, 6);
    }
    else
    {
        // Square tiling.
        st = nm_tile_fract2(st * rep);

        // mirrorXY needs half the range so edges match at default scale.
        float effectiveScale = scale;
        if (symmetry == 0) { effectiveScale = scale * 0.5; }
        st = (st - 0.5) / effectiveScale;
        st = st + 0.5 + float2(offsetX, offsetY);

        // Apply symmetry fold.
        if (symmetry == 0)
        {
            // mirrorXY
            st.x = nm_tile_mirrorFold(st.x);
            st.y = nm_tile_mirrorFold(st.y);
        }
        else if (symmetry == 1)
        {
            // rotate2
            st = nm_tile_rotationalFold(nm_tile_fract2(st), 2);
        }
        else
        {
            // rotate4
            st = nm_tile_rotationalFold(nm_tile_fract2(st), 4);
        }
    }

    // Clamp to valid texture range.
    st = clamp(st, float2(0.0, 0.0), float2(1.0, 1.0));

    // WGSL: textureSampleLevel(inputTex, samp, st, 0.0).rgb, alpha = 1.0
    return float4(inputTex.SampleLevel(samp, st, 0.0).rgb, 1.0);
}

#endif // NM_TILE_INCLUDED
