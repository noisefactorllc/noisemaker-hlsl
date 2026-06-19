#ifndef NM_SG_VIGNETTE_INCLUDED
#define NM_SG_VIGNETTE_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for filter/vignette.
//
// Drops the effect into Shader Graph as a node. Each global param from
// definition.js maps to a named input:
//   brightness -> Brightness (float, vignetteBrightness) [0,1] default 0
//   alpha      -> Alpha      (float)                      [0,1] default 1
// InputTex/SS/UV provide the source surface. UV must be the input texture's own
// 0..1 UV (the runtime path divides fragCoord by the input texture dimensions,
// and the WGSL uses that same uv for both the sample and the vignette mask).
//
// Self-contained (does NOT include NMFullscreen.hlsl / NMCore.hlsl) so it is
// safe to drop into a Shader Graph Custom Function node. Helpers/core are
// mirrored VERBATIM from Shaders/Effects/filter/Vignette.hlsl, name-prefixed
// `nmsg_` to avoid symbol clashes with the runtime include.
// =============================================================================

// computeVignetteMask — verbatim from WGSL `computeVignetteMask(uv, dims)`.
float nmsg_vignette_computeMask(float2 uv, float2 dims)
{
    if (dims.x <= 0.0 || dims.y <= 0.0)
    {
        return 0.0;
    }

    float2 delta = abs(uv - float2(0.5, 0.5));
    float aspect = dims.x / max(dims.y, 1.0);
    float2 scaled = float2(delta.x * aspect, delta.y);
    float maxRadius = length(float2(aspect * 0.5, 0.5));

    if (maxRadius <= 0.0)
    {
        return 0.0;
    }

    float normalizedDist = clamp(length(scaled) / maxRadius, 0.0, 1.0);
    return normalizedDist * normalizedDist;
}

// Core nm_vignette (param-injected), verbatim from Vignette.hlsl nm_vignette().
//   mask          = computeVignetteMask(uv, dims)
//   brightnessRgb = vec3(vignetteBrightness)
//   edgeBlend     = mix(texel.rgb, brightnessRgb, mask)
//   finalRgb      = mix(texel.rgb, edgeBlend, alpha)
//   return vec4(finalRgb, texel.a)
float4 nmsg_vignette(float4 texel, float2 uv, float2 dims,
                     float vignetteBrightness, float alpha)
{
    float mask = nmsg_vignette_computeMask(uv, dims);

    float3 brightnessRgb = float3(vignetteBrightness, vignetteBrightness, vignetteBrightness);
    float3 edgeBlend = lerp(texel.rgb, brightnessRgb, mask);
    float3 finalRgb = lerp(texel.rgb, edgeBlend, alpha);

    return float4(finalRgb, texel.a);
}

// Shader Graph Custom Function entry. Samples InputTex at UV, derives `dims`
// from the bound texture (WGSL `texSize`), then applies the vignette.
// TODO(verify): SS must be a clamp, non-sRGB (linear) sampler state so it matches
// the runtime's bilinear/clamp/linear path (H7).
void NM_Vignette_float(
    float          Brightness,
    float          Alpha,
    UnityTexture2D InputTex,
    UnitySamplerState SS,
    float2         UV,
    out float4     Out)
{
    float texW, texH;
    InputTex.GetDimensions(texW, texH);
    float2 dims = float2(texW, texH);

    float4 texel = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, UV);
    Out = nmsg_vignette(texel, UV, dims, Brightness, Alpha);
}

#endif // NM_SG_VIGNETTE_INCLUDED
