#ifndef NM_EFFECT_PALETTE3D_INCLUDED
#define NM_EFFECT_PALETTE3D_INCLUDED

// =============================================================================
// Palette3d.hlsl — filter3d/palette3d (func: "palette3d")
//
// 3D port of filter/palette: recolors a volume (stored as a 2D atlas) per-voxel by
// luminance → one of 55 cosine palettes (RGB/HSV/OkLab). The palette math is
// IDENTICAL to the 2D effect — this #includes the ported filter/Palette.hlsl and
// calls nm_palette() verbatim; only the I/O is volume-based (read inputTex3d, write
// the volumeCache atlas). The reference confirms this: palette3d.glsl == palette.glsl
// with the sampler swapped (inputTex -> inputTex3d).
//
// Single fullscreen pass over the atlas — each atlas texel IS one voxel, so the
// shader is dimension-agnostic (no x/y/z decode). uv = NM_FragCoord / atlas size,
// sampled with the SAME normalized-UV path as the 2D palette. Geometry (normals +
// density) passes through unchanged via the runtime's outputGeo:"inputGeo" — nothing
// geometric happens here. volumeSize is inherited from the upstream 3D generator.
// =============================================================================

#include "../filter/Palette.hlsl"   // -> NMFullscreen + palette uniforms/table + nm_palette

// volumeSize: inherited from the upstream volume effect (definition.js control=false).
// Declared for the runtime binding contract; UNUSED in the body (the atlas is recolored
// texel-for-texel). The palette uniforms (paletteIndex, rotation, offset, repeat, alpha)
// are declared by the included Palette.hlsl.
int volumeSize;

// Volume atlas input (bound from inputTex3d). Sampled with normalized UV, mirroring the
// 2D palette; the sampler must be bilinear, clamp-to-edge, LINEAR (non-sRGB) (H7).
Texture2D inputTex3d;  SamplerState sampler_inputTex3d;

// =============================================================================
// PASS: palette3d — recolor one volume-atlas texel (frag, single target -> volumeCache)
// =============================================================================
float4 frag_palette3d(NMVaryings i) : SV_Target
{
    // uv = fragCoord / atlas size. The bound output RT IS the volume atlas, so the
    // viewport spans it; divide by the INPUT atlas dims exactly as the 2D palette
    // divides by its input texture's own size.
    uint tw, th;
    inputTex3d.GetDimensions(tw, th);
    float2 uv = NM_FragCoord(i) / float2(tw, th);

    float4 color = inputTex3d.Sample(sampler_inputTex3d, uv);
    // Identical palette evaluation as the 2D effect (engine `time` from NMFullscreen).
    return nm_palette(color, time);
}

#endif // NM_EFFECT_PALETTE3D_INCLUDED
