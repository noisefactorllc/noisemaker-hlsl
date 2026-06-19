#ifndef NM_SG_THRESHOLD_INCLUDED
#define NM_SG_THRESHOLD_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for filter/threshold.
//
// Drops the effect into Shader Graph as a node. Each global param from
// definition.js maps to a named input:
//   level     -> Level (float, default 0.5)     luminance midpoint of the step
//   sharpness -> Sharpness (float, default 0.5) half-width of the smoothstep band
// InputTex/SS/UV provide the source surface. UV must be the input texture's own
// 0..1 UV (the runtime path divides fragCoord by the input texture dimensions).
//
// Self-contained (does NOT include NMFullscreen.hlsl / NMCore.hlsl) so it is
// safe to drop into a Shader Graph Custom Function node. Core math is mirrored
// VERBATIM from Shaders/Effects/filter/Threshold.hlsl (nm_threshold), with the
// params injected as arguments. Name-prefixed `nmsg_` to avoid symbol clashes
// with the runtime include.
//
// Ported from thresh.wgsl main():
//   let l = dot(c.rgb, vec3<f32>(0.299, 0.587, 0.114));
//   let e = smoothstep(level - sharpness, level + sharpness, l);
//   return vec4<f32>(vec3<f32>(e), 1.0);
// =============================================================================

// Core nm_threshold (param-injected), verbatim from Threshold.hlsl nm_threshold().
float4 nmsg_threshold(float4 c, float level, float sharpness)
{
    float l = dot(c.rgb, float3(0.299, 0.587, 0.114));
    float e = smoothstep(level - sharpness, level + sharpness, l);
    return float4(e, e, e, 1.0);
}

// Shader Graph Custom Function entry. Samples InputTex at UV, then applies the
// threshold. // TODO(verify): SS must be a clamp, non-sRGB (linear) sampler
// state so it matches the runtime's bilinear/clamp/linear path (H7).
void NM_Threshold_float(float Level, float Sharpness,
                        UnityTexture2D InputTex, UnitySamplerState SS, float2 UV,
                        out float4 Out)
{
    float4 c = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, UV);
    Out = nmsg_threshold(c, Level, Sharpness);
}

#endif // NM_SG_THRESHOLD_INCLUDED
