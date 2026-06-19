#ifndef NM_SG_WARP_INCLUDED
#define NM_SG_WARP_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for filter/warp.
//
// Drops the effect into Shader Graph as a node. Each global param from
// definition.js maps to a named input:
//   strength  -> Strength  (float) [0,100]  default 75
//   scale     -> Scale     (float) [0,5]    default 1
//   seed      -> Seed      (int)   [1,100]  default 1
//   speed     -> Speed     (int)   [0,5]    default 0
//   wrap      -> Wrap      (int)   0=mirror 1=repeat 2=clamp  default 0
//   antialias -> Antialias (int)   bool     default 1
// InputTex/SS/UV provide the source surface; Time is the engine animation time.
// UV must be the input texture's own 0..1 UV (the runtime path divides fragCoord
// by the input texture dimensions, and the WGSL uses that uv for warp + sample).
//
// Self-contained (does NOT include NMFullscreen.hlsl / NMCore.hlsl) so it is
// safe to drop into a Shader Graph Custom Function node. pcg/prng + all helpers
// are mirrored VERBATIM from Shaders/Effects/filter/Warp.hlsl (and NMCore's
// bit-exact pcg/prng), name-prefixed `nmsg_` to avoid symbol clashes.
// =============================================================================

#define NMSG_WARP_TAU 6.28318530718

// PCG 3D PRNG — bit-exact (riccardoscalco/glsl-pcg-prng, MIT), verbatim.
uint3 nmsg_warp_pcg(uint3 v)
{
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return v;
}

// prng(vec3 p) — sign-fold, hash, normalise by 0xffffffff (= 4294967295.0).
// (uint3)p is float->uint TRUNCATION toward zero, NOT asuint.
float3 nmsg_warp_prng(float3 p)
{
    p.x = p.x >= 0.0 ? p.x * 2.0 : -p.x * 2.0 + 1.0;
    p.y = p.y >= 0.0 ? p.y * 2.0 : -p.y * 2.0 + 1.0;
    p.z = p.z >= 0.0 ? p.z * 2.0 : -p.z * 2.0 + 1.0;
    return float3(nmsg_warp_pcg((uint3)p)) / 4294967295.0;
}

float nmsg_warp_smootherstep(float x)
{
    return x * x * x * (x * (x * 6.0 - 15.0) + 10.0);
}

float nmsg_warp_smoothlerp(float x, float a, float b)
{
    return a + nmsg_warp_smootherstep(x) * (b - a);
}

// grid(st, cell, t, speed) — verbatim; speed injected as a param.
float nmsg_warp_grid(float2 st, float2 cell, float t, int speed)
{
    float angle = nmsg_warp_prng(float3(cell, 1.0)).r * NMSG_WARP_TAU;
    angle = angle + t * NMSG_WARP_TAU * (float)speed;
    float2 gradient = float2(cos(angle), sin(angle));
    float2 dist = st - cell;
    return dot(gradient, dist);
}

float nmsg_warp_perlinNoise(float2 st_in, float2 noiseScale, float t, int speed)
{
    float2 st = st_in * noiseScale;
    float2 cell = floor(st);
    float tl = nmsg_warp_grid(st, cell, t, speed);
    float tr = nmsg_warp_grid(st, float2(cell.x + 1.0, cell.y), t, speed);
    float bl = nmsg_warp_grid(st, float2(cell.x, cell.y + 1.0), t, speed);
    float br = nmsg_warp_grid(st, cell + 1.0, t, speed);
    float upper = nmsg_warp_smoothlerp(st.x - cell.x, tl, tr);
    float lower = nmsg_warp_smoothlerp(st.x - cell.x, bl, br);
    float val = nmsg_warp_smoothlerp(st.y - cell.y, upper, lower);
    return val * 0.5 + 0.5;
}

// nm_mod (GLSL mod; sign of divisor) — NEVER fmod (H6).
float2 nmsg_warp_mod(float2 a, float2 b) { return a - b * floor(a / b); }

// Shader Graph Custom Function entry. UV is the input texture's own 0..1 UV;
// `aspectRatio` is derived from the bound texture (WGSL `texSize`).
// TODO(verify): SS must be clamp + non-sRGB (linear) to match the runtime's
// bilinear/clamp/linear sampling (H7). Antialias uses screen-space ddx/ddy of
// the warped UV, valid inside a fragment-stage Custom Function node.
void NM_Warp_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             Time,
    float             Strength,
    float             Scale,
    int               Seed,
    int               Speed,
    int               Wrap,
    int               Antialias,
    out float4        Out)
{
    float texW, texH;
    InputTex.GetDimensions(texW, texH);
    float2 texSize = float2(texW, texH);
    float aspectRatioLocal = texSize.x / texSize.y;

    float2 uv = UV;
    float t = Time;

    float2 noiseCoord = uv * float2(aspectRatioLocal, 1.0);
    float2 noiseScale = float2(abs(Scale * 3.0), abs(Scale * 3.0));
    float dx = (nmsg_warp_perlinNoise(noiseCoord + (float)Seed, noiseScale, t, Speed) - 0.5) * Strength * 0.01;
    float dy = (nmsg_warp_perlinNoise(noiseCoord + (float)Seed + 10.0, noiseScale, t, Speed) - 0.5) * Strength * 0.01;
    uv.x = uv.x + dx;
    uv.y = uv.y + dy;

    if (Wrap == 0)
    {
        uv = abs(nmsg_warp_mod(nmsg_warp_mod(uv + 1.0, float2(2.0, 2.0)) + 2.0, float2(2.0, 2.0)) - 1.0);
    }
    else if (Wrap == 1)
    {
        uv = nmsg_warp_mod(nmsg_warp_mod(uv, float2(1.0, 1.0)) + 1.0, float2(1.0, 1.0));
    }
    else
    {
        uv = clamp(uv, float2(0.0, 0.0), float2(1.0, 1.0));
    }

    if (Antialias != 0)
    {
        float2 ddxUv = ddx(uv);
        float2 ddyUv = ddy(uv);
        float4 col = float4(0.0, 0.0, 0.0, 0.0);
        col += SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv + ddxUv * -0.375 + ddyUv * -0.125);
        col += SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv + ddxUv *  0.125 + ddyUv * -0.375);
        col += SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv + ddxUv *  0.375 + ddyUv *  0.125);
        col += SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv + ddxUv * -0.125 + ddyUv *  0.375);
        Out = col * 0.25;
    }
    else
    {
        Out = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv);
    }
}

#endif // NM_SG_WARP_INCLUDED
