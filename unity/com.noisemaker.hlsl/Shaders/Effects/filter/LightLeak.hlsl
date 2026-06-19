#ifndef NM_EFFECT_LIGHTLEAK_INCLUDED
#define NM_EFFECT_LIGHTLEAK_INCLUDED

// =============================================================================
// LightLeak.hlsl — filter/lightLeak (func: "lightLeak")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/filter/lightLeak/wgsl/lightLeak.wgsl
//
// Film light leak overlay: Voronoi-based colored regions, wormhole distortion,
// bloom approximation, screen blend, Chebyshev center mask, and a "vaseline"
// soft blur via 4 neighbor texel loads. Single render pass. Alpha passed through.
//
// PORTING-GUIDE notes / hazards handled:
//  * TWO distinct coordinate spaces, mirrored from the WGSL literally:
//      - Sample coord = pos.xy / textureDimensions(inputTex)  (the INPUT
//        texture's OWN size, NOT fullResolution). Used for base textureSample.
//      - Pattern uv    = (pos.xy + tileOffset) / fullResolution. Used for the
//        Voronoi pattern + center mask so it is continuous across tiles.
//    The WGSL uses the unconditional `fullResolution` form (no GLSL fallback);
//    we mirror the WGSL, not the GLSL's `fullResolution.x > 0 ? ... : tileDims`.
//  * `pcg`/`hash33`/`hash31` are bit-identical to NMCore nm_pcg/nm_prng: same
//    sign-fold (`p>=0 ? p*2 : -p*2+1`), same (uint3) TRUNCATION, same divisor
//    4294967295.0 (H11). hash33 -> nm_prng; hash31 -> nm_prng(.).x. luminance,
//    voronoiCell, centerMask are per-effect and copied verbatim.
//  * WGSL `select(b, a, cond)` is reversed vs ternary; the fold reproduced here
//    via nm_prng matches exactly. textureLoad(t, coord, 0) -> t.Load(int3(c,0)).
//  * `fract`->`frac`, `mix`->`lerp`, `vec3<f32>(x)` splat -> float3(x,x,x).
//  * `exp(-d*12.0)`, `pow(mask,4.0)`, `sqrt`, `clamp`, `dot`, `min`, `abs`,
//    `sin`/`cos` map 1:1; no reassociation (H: keep redundant expressions).
//  * Loop bound POINT_COUNT=6, inclusive-style `i < 6` reproduced literally.
//  * Linear, clamp-to-edge, non-sRGB sampler (H7) — set in LightLeak.shader.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (reference binding: sampler@0, inputTex@1) ------
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
// Bound by the runtime via MaterialPropertyBlock by these exact names.
float  alpha;   // globals.alpha.uniform, [0,1]            default 1
float3 color;   // globals.color.uniform, rgb              default (1, 0.8, 0.3)
float  speed;   // globals.speed.uniform, [0,5]            default 0.5
int    seed;    // globals.seed.uniform,  [1,100] int      default 1

static const float TAU = 6.28318530717958647692;
static const uint  POINT_COUNT = 6u;

// hash33(p) — verbatim WGSL fold; bit-identical to NMCore nm_prng.
float3 nm_lightLeak_hash33(float3 p)
{
    return nm_prng(p);
}

// luminance(c) — per-effect (Rec.601-ish weights). Copy verbatim.
float nm_lightLeak_luminance(float3 c)
{
    return dot(c, float3(0.299, 0.587, 0.114));
}

// voronoiCell(uv, seed_f, t, user_color):
//   find nearest of 6 seed-based oscillating points; return cell color in .rgb
//   and squared toroidal distance in .w. Verbatim from WGSL.
float4 nm_lightLeak_voronoiCell(float2 uv, float seed_f, float t, float3 user_color)
{
    float best_dist = 1e9;
    uint  best_index = 0u;
    float drift = 0.05;

    uint i = 0u;
    [loop]
    for (; i < POINT_COUNT; i = i + 1u)
    {
        float3 s = float3(seed_f, (float)i * 7.31, 0.0);
        float2 base = nm_lightLeak_hash33(s).xy;
        float2 osc = float2(
            sin(t * 0.7 + (float)i * 1.618),
            cos(t * 0.5 + (float)i * 2.236)
        ) * drift;
        float2 pt = frac(base + osc);
        float2 delta = abs(uv - pt);
        float2 wd = min(delta, 1.0 - delta);
        float dist = dot(wd, wd);
        if (dist < best_dist)
        {
            best_dist = dist;
            best_index = i;
        }
    }

    float3 cs = float3(seed_f + 100.0, (float)best_index * 13.37, 5.0);
    float3 cell_color = lerp(nm_lightLeak_hash33(cs), user_color, 0.6);
    return float4(cell_color, best_dist);
}

// centerMask(uv) — Chebyshev distance from center, 0 at center, 1 at edges.
float nm_lightLeak_centerMask(float2 uv)
{
    float2 centered = abs(uv - 0.5);
    float dist = max(centered.x, centered.y);
    return clamp(dist * 2.0, 0.0, 1.0);
}

// ---- Pass: "lightLeak" (progName "lightLeak") --------------------------------
float4 NMFrag_lightLeak(NMVaryings i) : SV_Target
{
    // WGSL: texSize = vec2<f32>(textureDimensions(inputTex)); pos = position.xy.
    uint tw, th;
    inputTex.GetDimensions(tw, th);
    float2 texSize = float2((float)tw, (float)th);

    float2 pos = NM_FragCoord(i);  // @builtin(position).xy analog, top-left +0.5

    // Global UV for the leak pattern (Voronoi / center mask), continuous across
    // tiles; texel fetches below stay tile-local.
    float2 uv = (pos + tileOffset) / fullResolution;
    int2 coords = int2((int)pos.x, (int)pos.y);
    int2 dims = int2((int)tw, (int)th);

    float4 base = inputTex.Sample(sampler_inputTex, pos / texSize);
    float blend_alpha = clamp(alpha, 0.0, 1.0);
    if (blend_alpha <= 0.0)
    {
        return base;
    }

    float seed_f = (float)seed;
    float t = time * speed;
    float3 user_color = color;

    // Voronoi at current position (for wormhole direction)
    float4 base_vor = nm_lightLeak_voronoiCell(uv, seed_f, t, user_color);

    // Wormhole distortion
    float luma = nm_lightLeak_luminance(base_vor.rgb);
    float angle = luma * TAU + t * speed * 0.5;
    float2 warp = float2(cos(angle), sin(angle)) * 0.25;
    float2 warped_uv = frac(uv + warp);

    // Voronoi at warped position
    float4 warp_vor = nm_lightLeak_voronoiCell(warped_uv, seed_f, t, user_color);

    // Approximate bloom using distance falloff
    float glow = exp(-warp_vor.w * 12.0);
    float3 bloom_color = lerp(warp_vor.rgb, warp_vor.rgb * 1.3, glow);

    // Mix wormhole result with bloom
    float3 leak = clamp(
        lerp(sqrt(clamp(warp_vor.rgb, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0))), bloom_color, 0.55),
        float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0)
    );

    // Screen blend: 1 - (1 - base) * (1 - leak)
    float3 screened = float3(1.0, 1.0, 1.0) - (float3(1.0, 1.0, 1.0) - base.rgb) * (float3(1.0, 1.0, 1.0) - leak);

    // Center mask: leak is stronger away from center
    float mask = pow(nm_lightLeak_centerMask(uv), 4.0);
    float3 masked = lerp(base.rgb, screened, mask);

    // Vaseline-style soft blur via neighbor texel loads
    float3 soft_accum = masked * 4.0;
    float soft_w = 4.0;
    int2 max_coord = dims - int2(1, 1);
    int2 nb0 = clamp(coords + int2(2, 0),  int2(0, 0), max_coord);
    int2 nb1 = clamp(coords + int2(-2, 0), int2(0, 0), max_coord);
    int2 nb2 = clamp(coords + int2(0, 2),  int2(0, 0), max_coord);
    int2 nb3 = clamp(coords + int2(0, -2), int2(0, 0), max_coord);
    soft_accum = soft_accum + inputTex.Load(int3(nb0, 0)).rgb;
    soft_accum = soft_accum + inputTex.Load(int3(nb1, 0)).rgb;
    soft_accum = soft_accum + inputTex.Load(int3(nb2, 0)).rgb;
    soft_accum = soft_accum + inputTex.Load(int3(nb3, 0)).rgb;
    soft_w = soft_w + 4.0;
    float3 vaseline = soft_accum / soft_w;

    // Final blend with alpha
    float3 final_color = lerp(base.rgb, lerp(masked, vaseline, blend_alpha), blend_alpha);
    float3 clamped = clamp(final_color, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
    return float4(clamped, base.a);
}

#endif // NM_EFFECT_LIGHTLEAK_INCLUDED
