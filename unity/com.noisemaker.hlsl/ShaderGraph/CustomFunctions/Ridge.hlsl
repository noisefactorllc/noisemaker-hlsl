#ifndef NM_RIDGE_SG_INCLUDED
#define NM_RIDGE_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Ridge.hlsl
//
// Shader Graph Custom Function wrapper for filter/ridge. Add a Custom Function
// node, point it at this file, select NM_Ridge_float, and wire:
//   InputTex  — source UnityTexture2D
//   SS        — UnitySamplerState (bilinear, clamp, linear/non-sRGB)
//   UV        — float2 fragment UV (0..1, top-left origin, WGSL convention)
//   Level     — float [0,1] default 0.5  (definition.js globals.level)
//
// Output: Out (float4) — ridged RGBA, alpha forced to 1.0.
//
// ridge_transform is mirrored VERBATIM from the WGSL, name-prefixed `nmsg_`
// to avoid symbol clashes with the runtime include (Ridge.hlsl).
// =============================================================================

// nm_ridge_transform — verbatim WGSL ridge_transform(), name-prefixed.
float4 nmsg_ridge_transform(float4 value, float lvl)
{
    float denom = max(lvl, 1.0 - lvl);
    float4 result = float4(1.0, 1.0, 1.0, 1.0) - abs(value - float4(lvl, lvl, lvl, lvl)) / denom;
    return clamp(result, float4(0.0, 0.0, 0.0, 0.0), float4(1.0, 1.0, 1.0, 1.0));
}

// InputTex : source surface to apply ridge to
// SS       : sampler state (bilinear, clamp, linear/non-sRGB) for InputTex
// UV       : 0..1 fragment UV (top-left origin, WGSL convention)
// Level    : midpoint level (float, [0,1], default 0.5)
void NM_Ridge_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             Level,
    out float4        Out)
{
    float4 texel  = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, UV);
    float4 ridged = nmsg_ridge_transform(texel, Level);
    // WGSL: out_color = vec4(ridged.xyz, 1.0)
    Out = float4(ridged.xyz, 1.0);
}

#endif // NM_RIDGE_SG_INCLUDED
