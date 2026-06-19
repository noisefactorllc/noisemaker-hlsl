#ifndef NM_SG_LIGHTLEAK_INCLUDED
#define NM_SG_LIGHTLEAK_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for filter/lightLeak.
//
// Single render pass, so this wrapper IS provided (multi-pass effects ship as a
// runtime-rendered Texture2D instead). Each global param from definition.js maps
// to a named input:
//   alpha -> Alpha (float) [0,1] default 1
//   color -> Color (float3)      default (1, 0.8, 0.3)
//   speed -> Speed (float) [0,5] default 0.5
//   seed  -> Seed  (float; truncated to int as the WGSL does i32->f32)
// InputTex/SS/UV provide the source surface. The effect reads TWO coordinate
// spaces (see Shaders/Effects/filter/LightLeak.hlsl):
//   - sample coord  = FragCoord / texSize   (the input texture's own dims)
//   - pattern uv    = (FragCoord + tileOffset) / fullResolution
// Shader Graph nodes lack the engine globals, so Resolution / FullResolution /
// TileOffset / Time are exposed as explicit inputs. Pass:
//   Resolution     = the current render-target size (px)
//   FullResolution = the full untiled size (denominator for the pattern uv)
//   TileOffset     = (0,0) when not tiled
//   Time           = normalized animation time (the reference `time`)
// FragCoord is reconstructed as UV * Resolution (matches NM_FragCoord). The
// neighbor "vaseline" loads use UnityTexture2D.Load (texelFetch analog).
//
// Self-contained (does NOT include NMFullscreen.hlsl / NMCore.hlsl). Helpers/
// core are mirrored VERBATIM from Shaders/Effects/filter/LightLeak.hlsl, prefixed
// `nmsg_` to avoid symbol clashes with the runtime include. pcg/hash33 reproduce
// the NMCore nm_pcg/nm_prng bit-for-bit (same sign-fold, (uint3) truncation,
// divisor 4294967295.0 — H11).
// =============================================================================

static const float NMSG_LIGHTLEAK_TAU = 6.28318530717958647692;
static const uint  NMSG_LIGHTLEAK_POINT_COUNT = 6u;

// pcg — verbatim (riccardoscalco/glsl-pcg-prng), == NMCore nm_pcg.
uint3 nmsg_lightLeak_pcg(uint3 v)
{
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return v;
}

// hash33(p) — verbatim WGSL sign-fold + (uint3) TRUNCATION + 0xffffffff divisor.
float3 nmsg_lightLeak_hash33(float3 p)
{
    p.x = p.x >= 0.0 ? p.x * 2.0 : -p.x * 2.0 + 1.0;
    p.y = p.y >= 0.0 ? p.y * 2.0 : -p.y * 2.0 + 1.0;
    p.z = p.z >= 0.0 ? p.z * 2.0 : -p.z * 2.0 + 1.0;
    return float3(nmsg_lightLeak_pcg((uint3)p)) / 4294967295.0;
}

float nmsg_lightLeak_luminance(float3 c)
{
    return dot(c, float3(0.299, 0.587, 0.114));
}

float4 nmsg_lightLeak_voronoiCell(float2 uv, float seed_f, float t, float3 user_color)
{
    float best_dist = 1e9;
    uint  best_index = 0u;
    float drift = 0.05;

    uint i = 0u;
    [loop]
    for (; i < NMSG_LIGHTLEAK_POINT_COUNT; i = i + 1u)
    {
        float3 s = float3(seed_f, (float)i * 7.31, 0.0);
        float2 base = nmsg_lightLeak_hash33(s).xy;
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
    float3 cell_color = lerp(nmsg_lightLeak_hash33(cs), user_color, 0.6);
    return float4(cell_color, best_dist);
}

float nmsg_lightLeak_centerMask(float2 uv)
{
    float2 centered = abs(uv - 0.5);
    float dist = max(centered.x, centered.y);
    return clamp(dist * 2.0, 0.0, 1.0);
}

// Shader Graph Custom Function entry.
// TODO(verify): SS must be clamp, non-sRGB (linear), bilinear so it matches the
// runtime path (H7). TODO(verify): Resolution/FullResolution/TileOffset/Time
// must be wired from the same engine globals the runtime passes; otherwise the
// pattern uv (and animation) will not match the runtime render.
void NM_LightLeak_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float2            Resolution,
    float2            FullResolution,
    float2            TileOffset,
    float             Time,
    float             Alpha,
    float3            Color,
    float             Speed,
    float             Seed,
    out float4        Out)
{
    float tw, th;
    InputTex.GetDimensions(tw, th);
    float2 texSize = float2(tw, th);

    // @builtin(position).xy analog reconstructed from UV and the render size.
    float2 pos = UV * Resolution;

    float2 uv = (pos + TileOffset) / FullResolution;
    int2 coords = int2((int)pos.x, (int)pos.y);
    int2 dims = int2((int)tw, (int)th);

    float4 base = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, pos / texSize);
    float blend_alpha = clamp(Alpha, 0.0, 1.0);
    if (blend_alpha <= 0.0)
    {
        Out = base;
        return;
    }

    float seed_f = (float)((int)Seed);
    float t = Time * Speed;
    float3 user_color = Color;

    float4 base_vor = nmsg_lightLeak_voronoiCell(uv, seed_f, t, user_color);

    float luma = nmsg_lightLeak_luminance(base_vor.rgb);
    float angle = luma * NMSG_LIGHTLEAK_TAU + t * Speed * 0.5;
    float2 warp = float2(cos(angle), sin(angle)) * 0.25;
    float2 warped_uv = frac(uv + warp);

    float4 warp_vor = nmsg_lightLeak_voronoiCell(warped_uv, seed_f, t, user_color);

    float glow = exp(-warp_vor.w * 12.0);
    float3 bloom_color = lerp(warp_vor.rgb, warp_vor.rgb * 1.3, glow);

    float3 leak = clamp(
        lerp(sqrt(clamp(warp_vor.rgb, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0))), bloom_color, 0.55),
        float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0)
    );

    float3 screened = float3(1.0, 1.0, 1.0) - (float3(1.0, 1.0, 1.0) - base.rgb) * (float3(1.0, 1.0, 1.0) - leak);

    float mask = pow(nmsg_lightLeak_centerMask(uv), 4.0);
    float3 masked = lerp(base.rgb, screened, mask);

    float3 soft_accum = masked * 4.0;
    float soft_w = 4.0;
    int2 max_coord = dims - int2(1, 1);
    int2 nb0 = clamp(coords + int2(2, 0),  int2(0, 0), max_coord);
    int2 nb1 = clamp(coords + int2(-2, 0), int2(0, 0), max_coord);
    int2 nb2 = clamp(coords + int2(0, 2),  int2(0, 0), max_coord);
    int2 nb3 = clamp(coords + int2(0, -2), int2(0, 0), max_coord);
    soft_accum = soft_accum + InputTex.Load(int3(nb0, 0)).rgb;
    soft_accum = soft_accum + InputTex.Load(int3(nb1, 0)).rgb;
    soft_accum = soft_accum + InputTex.Load(int3(nb2, 0)).rgb;
    soft_accum = soft_accum + InputTex.Load(int3(nb3, 0)).rgb;
    soft_w = soft_w + 4.0;
    float3 vaseline = soft_accum / soft_w;

    float3 final_color = lerp(base.rgb, lerp(masked, vaseline, blend_alpha), blend_alpha);
    float3 clamped = clamp(final_color, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
    Out = float4(clamped, base.a);
}

#endif // NM_SG_LIGHTLEAK_INCLUDED
