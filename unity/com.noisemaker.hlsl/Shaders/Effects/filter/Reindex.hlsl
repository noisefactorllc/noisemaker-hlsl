#ifndef NM_EFFECT_REINDEX_INCLUDED
#define NM_EFFECT_REINDEX_INCLUDED

// =============================================================================
// Reindex.hlsl — filter/reindex (func: "reindex")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL sources:
//   shaders/effects/filter/reindex/wgsl/nmReindexStats.wgsl   (progName "nmReindexStats")
//   shaders/effects/filter/reindex/wgsl/nmReindexReduce.wgsl  (progName "nmReindexReduce")
//   shaders/effects/filter/reindex/wgsl/nmReindexApply.wgsl   (progName "nmReindexApply")
//
// Three-pass palette reindex (multi-pass, with a persistent/global state tex):
//   1. stats  (nmReindexStats) : inputTex -> statsTiles (transient). Each 8x8 tile's
//      top-left anchor pixel computes (minL, maxL) of the OkLab L of its tile; all
//      other pixels return 0.
//   2. reduce (nmReindexReduce): statsTiles -> global_stats (PERSISTENT 1x1 global).
//      Only fragment (0,0) collapses every tile anchor to one global (min,max) pair.
//   3. apply  (nmReindexApply) : inputTex + global_stats -> outputTex. Normalizes each
//      pixel's L into [0,1] using the global range, builds an offset, and reindexes
//      (gathers) a source texel by integer-wrapping that offset on both axes.
//
// NOTE: this effect is multi-pass with a persistent global state texture and ships
// as a runtime-rendered Texture2D. No Shader Graph Custom Function wrapper is
// provided (Shader Graph cannot drive the multi-pass + global-state pipeline).
//
// PORTING-GUIDE notes / hazards handled:
//  * Ported from WGSL (top-left, canonical). No per-effect Y flip.
//  * textureLoad(tex, ivec2, 0) -> tex.Load(int3(x, y, 0)) (integer texel fetch, no
//    sampler). textureDimensions(tex) -> tex.GetDimensions(w,h). All non-sRGB linear.
//  * Integer fragment coord: WGSL `i32(position.x)` (position = pixel-centered top-left
//    builtin). HLSL analog is `(int)NM_FragCoord(i).x`, which truncates the +0.5
//    pixel-centered coordinate to the pixel index — matching `i32(position.x)`.
//  * `%` here is integer modulo on non-negative pixel indices (matches WGSL i32 `%`).
//  * select(-1.0, 1.0, cond) -> cond ? 1.0 : -1.0 (WGSL select(false_val, true_val, cond)).
//  * cube_root magic exponent kept as the source `1.0 / 3.0` (NOT a truncated literal).
//  * F32_MAX/F32_MIN literals copied verbatim (3.402823466e38).
//  * Reduce uses the engine `resolution` uniform (WGSL: var<uniform> resolution:vec2<f32>),
//    aliased by NMFullscreen to _NM_Resolution.xy. WGSL rounds it: round(resolution.x/.y).
//  * Apply's wrap math follows the WGSL exactly (wrap_float / wrap_index with floor),
//    which DIFFERS from the GLSL apply (which used fract()-based wrapping). WGSL is
//    canonical per PORTING-GUIDE golden rule 1.
//  * Loop bounds inclusive/exclusive exactly as written (oy<TILE_SIZE, ty<MAX_TILE_DIM).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input/state textures (integer texel fetch only; no SamplerState needed) -
// stats pass : inputTex (effect input).
// reduce pass: statsTex (the statsTiles render target from pass 1).
// apply pass : inputTex (effect input) + statsTex (the global_stats 1x1 target).
// The runtime rebinds these per pass by these exact reference names.
Texture2D inputTex;   // stats.inputTex, apply.inputTex
Texture2D statsTex;   // reduce.statsTex (= statsTiles), apply.statsTex (= global_stats)

// ---- Per-effect named uniform (definition.js globals[*].uniform) -------------
float uDisplacement;  // globals.displacement.uniform, [0,2] step 0.01, default 0.5

// -----------------------------------------------------------------------------
// Shared OkLab-L helpers — ported VERBATIM from the WGSL (identical across passes).
// -----------------------------------------------------------------------------
static const int   TILE_SIZE   = 8;
static const float F32_MAX     = 3.402823466e38;
static const float F32_MIN     = -3.402823466e38;
static const int   MAX_TILE_DIM = 512;   // reduce pass: supports up to 4096px
static const float F32_EPSILON = 0.0001; // apply pass

float reindex_clamp01(float value)
{
    return clamp(value, 0.0, 1.0);
}

float reindex_srgb_to_linear(float value)
{
    if (value <= 0.04045)
    {
        return value / 12.92;
    }
    return pow((value + 0.055) / 1.055, 2.4);
}

float reindex_cube_root(float value)
{
    if (value == 0.0)
    {
        return 0.0;
    }
    float sign_value = (value >= 0.0) ? 1.0 : -1.0;
    return sign_value * pow(abs(value), 1.0 / 3.0);
}

float reindex_oklab_l_component(float3 rgb)
{
    float r_lin = reindex_srgb_to_linear(reindex_clamp01(rgb.x));
    float g_lin = reindex_srgb_to_linear(reindex_clamp01(rgb.y));
    float b_lin = reindex_srgb_to_linear(reindex_clamp01(rgb.z));

    float l = 0.4121656120 * r_lin + 0.5362752080 * g_lin + 0.0514575653 * b_lin;
    float m = 0.2118591070 * r_lin + 0.6807189584 * g_lin + 0.1074065790 * b_lin;
    float s = 0.0883097947 * r_lin + 0.2818474174 * g_lin + 0.6302613616 * b_lin;

    float l_c = reindex_cube_root(l);
    float m_c = reindex_cube_root(m);
    float s_c = reindex_cube_root(s);

    float lightness = 0.2104542553 * l_c + 0.7936177850 * m_c - 0.0040720468 * s_c;
    return reindex_clamp01(lightness);
}

float reindex_value_map_component(float4 texel)
{
    return reindex_oklab_l_component(texel.xyz);
}

// Apply-pass wrap helpers (verbatim from nmReindexApply.wgsl).
float reindex_wrap_float(float value, float range)
{
    if (range <= 0.0)
    {
        return 0.0;
    }
    return value - range * floor(value / range);
}

int reindex_wrap_index(float value, int dimension)
{
    if (dimension <= 0)
    {
        return 0;
    }
    float dimension_f = (float)dimension;
    float wrapped = reindex_wrap_float(value, dimension_f);
    float max_index = (float)(dimension - 1);
    return (int)clamp(floor(wrapped), 0.0, max_index);
}

// ---- Pass: "nmReindexStats" — per-8x8-tile OkLab-L min/max --------------------
float4 frag_nmReindexStats(NMVaryings i) : SV_Target
{
    uint dw, dh;
    inputTex.GetDimensions(dw, dh);
    if (dw == 0u || dh == 0u)
    {
        return float4(0.0, 0.0, 0.0, 0.0);
    }

    int2 coord = int2((int)NM_FragCoord(i).x, (int)NM_FragCoord(i).y);
    if (coord.x < 0 || coord.y < 0)
    {
        return float4(0.0, 0.0, 0.0, 0.0);
    }

    int local_x = coord.x % TILE_SIZE;
    int local_y = coord.y % TILE_SIZE;
    if (local_x != 0 || local_y != 0)
    {
        return float4(0.0, 0.0, 0.0, 0.0);
    }

    float min_value = F32_MAX;
    float max_value = F32_MIN;
    int2 tile_origin = coord;
    int width  = (int)dw;
    int height = (int)dh;

    [loop]
    for (int oy = 0; oy < TILE_SIZE; oy = oy + 1)
    {
        int py = tile_origin.y + oy;
        if (py >= height)
        {
            break;
        }
        [loop]
        for (int ox = 0; ox < TILE_SIZE; ox = ox + 1)
        {
            int px = tile_origin.x + ox;
            if (px >= width)
            {
                break;
            }
            float4 smp = inputTex.Load(int3(px, py, 0));
            float value = reindex_value_map_component(smp);
            min_value = min(min_value, value);
            max_value = max(max_value, value);
        }
    }

    return float4(min_value, max_value, 0.0, 1.0);
}

// ---- Pass: "nmReindexReduce" — collapse tile stats to one global (min,max) ----
float4 frag_nmReindexReduce(NMVaryings i) : SV_Target
{
    if ((int)NM_FragCoord(i).x != 0 || (int)NM_FragCoord(i).y != 0)
    {
        return float4(0.0, 0.0, 0.0, 0.0);
    }

    uint dw, dh;
    statsTex.GetDimensions(dw, dh);
    if (dw == 0u || dh == 0u)
    {
        return float4(0.0, 0.0, 0.0, 0.0);
    }

    int width_px  = max((int)round(resolution.x), 0);
    int height_px = max((int)round(resolution.y), 0);
    int2 tile_count = int2(
        (width_px + TILE_SIZE - 1) / TILE_SIZE,
        (height_px + TILE_SIZE - 1) / TILE_SIZE
    );

    float global_min = F32_MAX;
    float global_max = F32_MIN;
    int tex_width  = (int)dw;
    int tex_height = (int)dh;

    [loop]
    for (int ty = 0; ty < MAX_TILE_DIM; ty = ty + 1)
    {
        if (ty >= tile_count.y)
        {
            break;
        }
        [loop]
        for (int tx = 0; tx < MAX_TILE_DIM; tx = tx + 1)
        {
            if (tx >= tile_count.x)
            {
                break;
            }
            int2 sample_coord = int2(tx * TILE_SIZE, ty * TILE_SIZE);
            if (sample_coord.x >= tex_width || sample_coord.y >= tex_height)
            {
                continue;
            }
            float2 tile_stats = statsTex.Load(int3(sample_coord.x, sample_coord.y, 0)).xy;
            global_min = min(global_min, tile_stats.x);
            global_max = max(global_max, tile_stats.y);
        }
    }

    return float4(global_min, global_max, 0.0, 1.0);
}

// ---- Pass: "nmReindexApply" — remap/gather using the global (min,max) ---------
float4 frag_nmReindexApply(NMVaryings i) : SV_Target
{
    uint dw, dh;
    inputTex.GetDimensions(dw, dh);
    if (dw == 0u || dh == 0u)
    {
        return float4(0.0, 0.0, 0.0, 0.0);
    }

    int2 coord = int2((int)NM_FragCoord(i).x, (int)NM_FragCoord(i).y);
    if (coord.x < 0 || coord.y < 0 || coord.x >= (int)dw || coord.y >= (int)dh)
    {
        return float4(0.0, 0.0, 0.0, 0.0);
    }

    float4 texel = inputTex.Load(int3(coord.x, coord.y, 0));
    float reference_value = reindex_value_map_component(texel);

    float2 min_max = statsTex.Load(int3(0, 0, 0)).xy;
    float range = min_max.y - min_max.x;

    float normalized = reference_value;
    if (range > F32_EPSILON)
    {
        normalized = reindex_clamp01((reference_value - min_max.x) / range);
    }

    float mod_range = (float)min(dw, dh);
    float offset_value = normalized * uDisplacement * mod_range + normalized;
    int sample_x = reindex_wrap_index(offset_value, (int)dw);
    int sample_y = reindex_wrap_index(offset_value, (int)dh);

    return inputTex.Load(int3(sample_x, sample_y, 0));
}

#endif // NM_EFFECT_REINDEX_INCLUDED
