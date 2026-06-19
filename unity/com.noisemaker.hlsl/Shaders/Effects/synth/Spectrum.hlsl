#ifndef NM_SPECTRUM_INCLUDED
#define NM_SPECTRUM_INCLUDED

// =============================================================================
// Spectrum.hlsl — synth/spectrum, ported PIXEL-IDENTICALLY from the canonical
// WGSL source:
//   shaders/effects/synth/spectrum/wgsl/spectrum.wgsl
//
// Audio spectrum analyzer generator. Reads 128 frequency bins packed into
// 32 float4 uniforms. Draws an anti-aliased line at the magnitude of each bin
// with a translucent fill below the curve.
//
// No per-effect helpers beyond sampleSpectrum (inline). No pcg/prng used.
//
// COORDINATE NOTE: WGSL computes uv as:
//   uv = vec2(position.x, resolution.y - position.y) / resolution
// This is equivalent to top-left UV (position.xy / resolution with Y-flip),
// which is what NM_GlobalCoord gives us when divided by fullResolution.
// Following WGSL literally: uv.y = (resolution.y - fragCoord.y) / resolution.y
// = 1.0 - fragCoord.y / resolution.y.  In the fullscreen pass resolution ==
// fullResolution so we replicate the WGSL exactly.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
float3 lineColor;       // default [0,1,0]   (globals.color)
float  lineThickness;   // default 2.0       (globals.thickness)
float  gain;            // default 1.0       (globals.gain)

// Audio spectrum: 128 bins packed as 32 float4 uniforms.
// The WGSL declares: array<vec4<f32>, 32> audioSpectrum
// Indexed as: audioSpectrum[index / 4u][index % 4u]
float4 audioSpectrum[32];

// ---- sampleSpectrum — verbatim from WGSL ------------------------------------
// WGSL: return audioSpectrum[index / 4u][index % 4u];
float sampleSpectrum(uint index)
{
    uint slot = index / 4u;
    uint comp = index % 4u;
    float4 v  = audioSpectrum[slot];
    // select component without dynamic indexing (safe on all HLSL targets)
    if      (comp == 0u) return v.x;
    else if (comp == 1u) return v.y;
    else if (comp == 2u) return v.z;
    else                 return v.w;
}

// =============================================================================
// nm_spectrum — core per-pixel evaluation.
// `fragCoordXY` is NM_FragCoord(i) (pixel-space, top-left, +0.5 centered).
// Mirrors WGSL main() exactly.
// =============================================================================
float4 nm_spectrum(float2 fragCoordXY)
{
    // WGSL: uv = vec2(position.x, resolution.y - position.y) / resolution
    // resolution here is the render-target size (fullResolution in tiled mode;
    // they are equal for untiled passes, matching the WGSL binding).
    float2 res = fullResolution.x > 0.0 ? fullResolution : resolution;
    float2 uv  = float2(fragCoordXY.x, res.y - fragCoordXY.y) / res;

    // Sample the spectrum at this x position
    float fIndex   = uv.x * 127.0;
    uint  i0       = (uint)floor(fIndex);
    uint  i1       = min(i0 + 1u, 127u);
    float fract_i  = frac(fIndex);

    // Linearly interpolate between adjacent bins
    float s0  = sampleSpectrum(i0);
    float s1  = sampleSpectrum(i1);
    float mag = lerp(s0, s1, fract_i) * gain;

    // Distance from fragment to spectrum curve, in pixels
    float dist = abs(uv.y - mag) * res.y;

    // Anti-aliased line
    float lineVal = smoothstep(lineThickness + 1.0, lineThickness, dist);

    // Fill below the curve
    float fill = smoothstep(mag + 1.0 / res.y, mag, uv.y) * 0.15;

    float alphaVal = max(lineVal, fill);
    return float4(lineColor * alphaVal, alphaVal);
}

#endif // NM_SPECTRUM_INCLUDED
