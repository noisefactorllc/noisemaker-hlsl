#ifndef NM_SG_ZOOMBLUR_INCLUDED
#define NM_SG_ZOOMBLUR_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for filter/zoomBlur.
//
// Drops the effect into Shader Graph as a node. Each global param from
// definition.js maps to a named input:
//   strength -> Strength (float, strength) [0,1] default 0.5
// InputTex/SS/UV provide the source surface. UV must be the input texture's own
// 0..1 UV (the runtime path divides fragCoord by the input texture dimensions;
// the WGSL uv = position.xy / textureDimensions(inputTex) and position.xy =
// UV * dims, so the supplied UV is the identity sample-center coordinate).
//
// Self-contained (does NOT include NMFullscreen.hlsl / NMCore.hlsl) so it is
// safe to drop into a Shader Graph Custom Function node. Helpers/core are
// mirrored VERBATIM from Shaders/Effects/filter/ZoomBlur.hlsl, name-prefixed
// `nmsg_` to avoid symbol clashes with the runtime include.
//
// PRNG parity (H11): this effect's prng does NOT sign-fold (unlike NMCore
// nm_prng); it casts vec3<u32>(p) directly (truncation). Divisor 4294967295.0.
// =============================================================================

// PCG 3D PRNG (riccardoscalco/glsl-pcg-prng, MIT). Verbatim from WGSL `pcg`.
uint3 nmsg_zoomBlur_pcg(uint3 v)
{
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return v;
}

// prng — VERBATIM from this effect's WGSL `prng(p)` (NO sign-fold).
//   return vec3<f32>(pcg(vec3<u32>(p))) / f32(0xffffffffu);
float3 nmsg_zoomBlur_prng(float3 p)
{
    return float3(nmsg_zoomBlur_pcg((uint3)p)) / 4294967295.0;
}

// Core nm_zoomBlur (param-injected), verbatim from ZoomBlur.hlsl nm_zoomBlur().
float4 nmsg_zoomBlur(float2 uv, Texture2D inTex, SamplerState ss, float strength)
{
    float3 color = float3(0.0, 0.0, 0.0);
    float total = 0.0;
    float2 toCenter = uv - 0.5;

    float offset = nmsg_zoomBlur_prng(float3(12.9898, 78.233, 151.7182)).x;

    for (float t = 0.0; t <= 40.0; t = t + 1.0)
    {
        float percent = (t + offset) / 40.0;
        float weight = 4.0 * (percent - percent * percent);
        float4 tex = inTex.SampleLevel(ss, uv + toCenter * percent * strength, 0.0);
        color = color + tex.rgb * weight;
        total = total + weight;
    }

    color = color / total;

    return float4(color, 1.0);
}

// Shader Graph Custom Function entry. Uses UV as the sample-center coordinate
// (identity of WGSL `uv = position.xy / dims`), then applies the zoom blur.
// TODO(verify): SS must be a clamp, non-sRGB (linear) sampler state so it matches
// the runtime's bilinear/clamp/linear path (H7).
void NM_ZoomBlur_float(
    float             Strength,
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    out float4        Out)
{
    Out = nmsg_zoomBlur(UV, InputTex.tex, SS.samplerstate, Strength);
}

#endif // NM_SG_ZOOMBLUR_INCLUDED
