#ifndef NM_UVREMAP_INCLUDED
#define NM_UVREMAP_INCLUDED

// =============================================================================
// UvRemap.hlsl — mixer/uvRemap, ported PIXEL-IDENTICALLY from the canonical
// WGSL:  shaders/effects/mixer/uvRemap/wgsl/uvRemap.wgsl
//
// Remap UVs of one input using color channels of another. Single render pass.
//
// PORTING-GUIDE notes:
//  * Helpers (modulo / mirrorWrap / applyWrap) are THIS effect's own copies —
//    ported VERBATIM inline; not shared (golden rule 2).
//    modulo implements floor-based mod; mapped to nm_mod in HLSL per guide rule H6,
//    but since the helpers are verbatim we use nm_mod from NMCore.
//  * mapSource / channel / wrap: WGSL i32 uniforms -> HLSL int uniforms.
//  * scale / offset: WGSL f32 uniforms -> HLSL float uniforms.
//  * UV coord: WGSL divides pos.xy by textureDimensions(inputTex,0). Exactly as
//    BlendMode.hlsl — one `st` from inputTex's own dims, used for BOTH initial
//    samples (colorA, colorB). tileOffset NOT added (WGSL does not add it).
//  * select(b,a,cond) in WGSL means "return a if cond, else b" — reversed arg
//    order vs. ternary. The WGSL uses plain if/else branches here; ported verbatim.
//  * modulo(a,b) -> nm_mod(a,b)  (never fmod — PORTING-GUIDE H6).
//  * fract -> frac.  mix -> lerp (unused here, but noted for completeness).
//  * No PRNG / no atan2 / no bit-reinterpret in this effect.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
int   mapSource;   // 0=sourceA uses colorB as map, 1=sourceB uses colorA as map; default 0
int   channel;     // 0=rg, 1=rb, 2=gb; default 0
float scale;       // percentage: 100 = identity; default 100.0
float offset;      // UV offset; default 0.0
int   wrap;        // 0=clamp, 1=mirror, 2=repeat; default 1

// -----------------------------------------------------------------------------
// mirrorWrap — ported VERBATIM from uvRemap.wgsl.
// WGSL: let m = modulo(t, 2.0); if (m > 1.0) { return 2.0 - m; } return m;
// -----------------------------------------------------------------------------
float mirrorWrap(float t)
{
    float m = nm_mod(t, 2.0);
    if (m > 1.0) {
        return 2.0 - m;
    }
    return m;
}

// -----------------------------------------------------------------------------
// applyWrap — ported VERBATIM from uvRemap.wgsl.
// 0: Clamp, 1: Mirror, 2: Repeat (fract)
// -----------------------------------------------------------------------------
float2 applyWrap(float2 uv, int wrapMode)
{
    if (wrapMode == 0) {
        // Clamp
        return clamp(uv, float2(0.0, 0.0), float2(1.0, 1.0));
    } else if (wrapMode == 1) {
        // Mirror
        return float2(mirrorWrap(uv.x), mirrorWrap(uv.y));
    } else {
        // Repeat
        return frac(uv);
    }
}

// -----------------------------------------------------------------------------
// nm_uvRemap — core per-pixel evaluation. Takes the two already-sampled input
// colors (colorA = inputTex, colorB = tex) and the UV to sample each input at
// remapped coordinates. Returns the final RGBA. Ported VERBATIM from
// uvRemap.wgsl main() lines 37-81.
//
// References the global Texture2D/SamplerState resources the .shader declares
// BEFORE this #include (same forward pattern as Distortion.hlsl). HLSL cannot
// reliably pass Texture2D/SamplerState as function parameters, so the remapped
// samples use the globals directly.
// -----------------------------------------------------------------------------
float4 nm_uvRemap(
    float4 colorA,
    float4 colorB)
{
    // Choose map and sample sources.
    // MATCH THE GLSL (the WebGL2 golden), NOT the WGSL — they are INVERTED here:
    //   GLSL:  mapColor = (mapSource==0) ? colorA : colorB;
    //          sampleFromB = (mapSource==0) ? 1 : 0;
    //   WGSL:  mapSource==0 -> map=colorB, sampleFromB=0  (the opposite).
    // The golden runs the GLSL, so mapSource=0 maps with colorA(inputTex) and
    // samples tex. (See normalMap for the same WGSL/GLSL-divergence hazard.)
    float4 mapColor   = (mapSource == 0) ? colorA : colorB;
    int    sampleFromB = (mapSource == 0) ? 1 : 0;

    // Extract UV channels
    float2 rawUV;
    if (channel == 0) {
        rawUV = mapColor.rg;
    } else if (channel == 1) {
        rawUV = float2(mapColor.r, mapColor.b);
    } else {
        rawUV = float2(mapColor.g, mapColor.b);
    }

    // Apply scale (percentage: 100 = identity) and offset
    float s = scale / 100.0;
    float2 remappedUV = rawUV * s + offset;

    // Apply wrap mode
    remappedUV = applyWrap(remappedUV, wrap);

    // GLSL: sampleUV = fract((remappedUV * fullResolution - tileOffset) / resolution).
    // This tile-corrects the map UV (identity when untiled: fullResolution==resolution,
    // tileOffset==0). The WGSL omits it; we follow the GLSL golden.
    float2 sampleUV = (remappedUV * fullResolution - tileOffset) / resolution;
    sampleUV = frac(sampleUV);

    // Sample the chosen texture at the remapped UVs
    float4 result;
    if (sampleFromB == 1) {
        result = tex.Sample(sampler_tex, sampleUV);
    } else {
        result = inputTex.Sample(sampler_inputTex, sampleUV);
    }

    return result;
}

#endif // NM_UVREMAP_INCLUDED
