#ifndef NM_SCOPE_INCLUDED
#define NM_SCOPE_INCLUDED

// =============================================================================
// Scope.hlsl — synth/scope, ported PIXEL-IDENTICALLY from the canonical
// WGSL source:
//   shaders/effects/synth/scope/wgsl/scope.wgsl
//
// Audio waveform oscilloscope generator. Single render pass.
//
// No per-effect helpers beyond sampleWaveform (no shared primitives needed).
//
// WGSL PARITY NOTES:
//  * WGSL: uv = vec2(position.x, resolution.y - position.y) / resolution
//    The Y flip converts top-left WGSL coordinates to bottom-left waveform
//    convention so the waveform draws upward from center, matching the GLSL
//    path which uses gl_FragCoord (bottom-left). Applied here verbatim.
//  * WGSL uses resolution (not fullResolution) and packs waveform into
//    array<vec4<f32>,32>. We declare float4 audioWaveform[32] to match exactly.
//  * sampleWaveform(index): audioWaveform[index/4][index%4] -- verbatim.
//  * Indices: i0 = u32(floor(fIndex)), i1 = min(i0+1, 127) -- verbatim.
//  * dist = abs(uv.y - gained) * resolution.y -- verbatim (uses resolution.y).
//  * Premultiplied alpha output: float4(lineColor * line, line).
//  * No nm_mod, no pcg/prng — this effect has no such helpers.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
float3 lineColor;       // default (0,1,0)   (global "color")
float  lineThickness;   // default 2.0       (global "thickness")
float  gain;            // default 1.0       (global "gain")

// ---- Audio waveform: 128 floats packed as 32 float4 (matches WGSL layout) ---
// Bound by the runtime from the audioWaveform uniform data.
float4 audioWaveform[32];

// ---- sampleWaveform: verbatim from WGSL (index/4u -> vec component) ---------
float nm_sampleWaveform(uint index)
{
    return audioWaveform[index / 4u][index % 4u];
}

// =============================================================================
// nm_scope — core per-pixel evaluation. `fragCoord` is the fragment's
// pixel coordinate (NM_FragCoord(i), top-left, +0.5 centered).
// Mirrors WGSL main() exactly.
// =============================================================================
float4 nm_scope(float2 fragCoord)
{
    // WGSL: uv = vec2(position.x, resolution.y - position.y) / resolution
    // This flips Y to bottom-left convention for waveform drawing.
    float2 uv = float2(fragCoord.x, resolution.y - fragCoord.y) / resolution;

    // Sample the waveform at this x position.
    // Map uv.x [0,1] to array index [0,127].
    float fIndex = uv.x * 127.0;
    uint  i0 = (uint)floor(fIndex);
    uint  i1 = min(i0 + 1u, 127u);
    float fract_i = frac(fIndex);

    // Linearly interpolate between adjacent samples.
    float s0 = nm_sampleWaveform(i0);
    float s1 = nm_sampleWaveform(i1);
    float wval = lerp(s0, s1, fract_i);

    // Apply gain around center (0.5 = silence).
    float gained = 0.5 + (wval - 0.5) * gain;

    // Distance from fragment to waveform line, in pixels.
    float dist = abs(uv.y - gained) * resolution.y;

    // Anti-aliased line.
    float lineVal = smoothstep(lineThickness + 1.0, lineThickness, dist);

    // Premultiplied alpha output.
    return float4(lineColor * lineVal, lineVal);
}

#endif // NM_SCOPE_INCLUDED
