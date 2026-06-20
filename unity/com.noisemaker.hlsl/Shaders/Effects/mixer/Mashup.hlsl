#ifndef NM_EFFECT_MASHUP_INCLUDED
#define NM_EFFECT_MASHUP_INCLUDED

// =============================================================================
// Mashup.hlsl — mixer/mashup, ported PIXEL-IDENTICALLY from the canonical GLSL/WGSL:
//   shaders/effects/mixer/mashup/{glsl,wgsl}
//
// Luminance-band router ("mega mixer"). The control input (`source`) is posterized
// by luminance into `layers` equal bands (boundaries at k/layers); each band routes
// to its own wired surface (layer0_tex..layer7_tex). Darkest band -> layer0,
// brightest -> layer(layers-1). `smoothness` feathers each band boundary (0 = hard
// posterize). A band whose source is unwired (layerN_active == 0) falls back to the
// control input. Starter effect: output size comes from the engine `resolution`
// global (NMFullscreen), as for synth/remap.
//
// Multi-input mixer, modeled on synth/remap: each input is an individual Texture2D,
// each layerN_active is an individual uniform set by the expander via the surface
// global's colorModeUniform (1 when wired, 0 when "none"). Conditional/looped
// samples use SampleLevel(..., 0.0) (RTs are non-mipmapped, so == texture()).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
int   layers;       // default 4, range [2,8]
float smoothness;   // default 0.1, range [0,0.5]

// Per-layer active flags (colorModeUniform; 1.0 when the layerN_tex surface is wired,
// 0.0 when "none"). Declared as float to match the binder's colorModeUniform path
// (mirrors synth/remap's zoneN_active); the GLSL int compare `== 1` becomes `>= 0.5`.
float layer0_active; float layer1_active; float layer2_active; float layer3_active;
float layer4_active; float layer5_active; float layer6_active; float layer7_active;

// ---- Inputs: the control source + one surface per band -----------------------
Texture2D source;     SamplerState sampler_source;       // control input (luminance picks the band)
Texture2D layer0_tex; SamplerState sampler_layer0_tex;
Texture2D layer1_tex; SamplerState sampler_layer1_tex;
Texture2D layer2_tex; SamplerState sampler_layer2_tex;
Texture2D layer3_tex; SamplerState sampler_layer3_tex;
Texture2D layer4_tex; SamplerState sampler_layer4_tex;
Texture2D layer5_tex; SamplerState sampler_layer5_tex;
Texture2D layer6_tex; SamplerState sampler_layer6_tex;
Texture2D layer7_tex; SamplerState sampler_layer7_tex;

// RGB -> luminosity (shared codebase weights).
float nm_mashup_luminosity(float3 color)
{
    return dot(color, float3(0.299, 0.587, 0.114));
}

float4 nm_mashup_sampleLayer(int i, float2 uv)
{
    [branch] if (i == 0) return layer0_tex.SampleLevel(sampler_layer0_tex, uv, 0.0);
    [branch] if (i == 1) return layer1_tex.SampleLevel(sampler_layer1_tex, uv, 0.0);
    [branch] if (i == 2) return layer2_tex.SampleLevel(sampler_layer2_tex, uv, 0.0);
    [branch] if (i == 3) return layer3_tex.SampleLevel(sampler_layer3_tex, uv, 0.0);
    [branch] if (i == 4) return layer4_tex.SampleLevel(sampler_layer4_tex, uv, 0.0);
    [branch] if (i == 5) return layer5_tex.SampleLevel(sampler_layer5_tex, uv, 0.0);
    [branch] if (i == 6) return layer6_tex.SampleLevel(sampler_layer6_tex, uv, 0.0);
    return layer7_tex.SampleLevel(sampler_layer7_tex, uv, 0.0);
}

float nm_mashup_layerActive(int i)
{
    [branch] if (i == 0) return layer0_active;
    [branch] if (i == 1) return layer1_active;
    [branch] if (i == 2) return layer2_active;
    [branch] if (i == 3) return layer3_active;
    [branch] if (i == 4) return layer4_active;
    [branch] if (i == 5) return layer5_active;
    [branch] if (i == 6) return layer6_active;
    return layer7_active;
}

// Band-boundary weight: 0 below the boundary, 1 above, with a symmetric smoothstep
// feather of half-width `smoothness`. smoothness <= 0 is a hard step.
float nm_mashup_bandWeight(float lum, float boundary)
{
    if (smoothness <= 0.0) return step(boundary, lum);
    return smoothstep(boundary - smoothness, boundary + smoothness, lum);
}

// =============================================================================
// PASS: mashup — posterize `source` luminance and route each band to layerN_tex.
// =============================================================================
float4 frag_mashup(NMVaryings i) : SV_Target
{
    float2 uv = NM_FragCoord(i) / resolution;
    float4 controlColor = source.SampleLevel(sampler_source, uv, 0.0);
    float lum = nm_mashup_luminosity(controlColor.rgb);

    int n = clamp(layers, 2, 8);

    // Base = darkest band's source (or the control input when unwired).
    float4 result = (nm_mashup_layerActive(0) >= 0.5) ? nm_mashup_sampleLayer(0, uv) : controlColor;

    // Each subsequent boundary at k/n cross-fades toward that band's source.
    [loop]
    for (int k = 1; k < 8; k = k + 1)
    {
        if (k >= n) { break; }
        float4 src = (nm_mashup_layerActive(k) >= 0.5) ? nm_mashup_sampleLayer(k, uv) : controlColor;
        float boundary = (float)k / (float)n;
        float w = nm_mashup_bandWeight(lum, boundary);
        result = lerp(result, src, w);
    }

    return result;
}

#endif // NM_EFFECT_MASHUP_INCLUDED
