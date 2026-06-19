#ifndef NM_COMPOSITE_SG_INCLUDED
#define NM_COMPOSITE_SG_INCLUDED

// ShaderGraph Custom Function wrapper for classicNoisedeck/composite.
// Mixer: two texture inputs (InputTex = A, Tex = B).
// The core math lives in Shaders/Effects/classicNoisedeck/Composite.hlsl;
// this wrapper re-exposes it with UnityTexture2D / UnitySamplerState types so
// Shader Graph's "Custom Function (File)" node can wire it directly.
//
// NOTE: blendMode, range, inputColor, mixAmt are per-node inputs here rather
// than global uniforms (each SG node instance can have its own values).
// The runtime shader path uses the global uniforms declared in Composite.hlsl.

#include "Packages/com.noisemaker.hlsl/Shaders/Effects/classicNoisedeck/Composite.hlsl"

void NM_Composite_float(
    UnityTexture2D   InputTex,
    UnitySamplerState SS,
    UnityTexture2D   Tex,
    float2           UV,
    float3           InputColor,
    int              BlendMode,
    float            Range,
    float            MixAmt,
    out float4       Out)
{
    // Override module-level uniforms so blend_colors / nm_composite use the
    // per-node values supplied by Shader Graph.
    inputColor = InputColor;
    blendMode  = BlendMode;
    range      = Range;
    mixAmt     = MixAmt;

    float4 color1 = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, UV);
    float4 color2 = SAMPLE_TEXTURE2D(Tex.tex,      SS.samplerstate, UV);

    Out = nm_composite(color1, color2);
}

#endif // NM_COMPOSITE_SG_INCLUDED
