#ifndef NM_DEGAUSS_SG_INCLUDED
#define NM_DEGAUSS_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Degauss.hlsl
//
// Shader Graph Custom Function wrapper for filter/degauss.
//
// NOTE: degauss uses manual bilinear sampling via Texture2D.Load (integer texel
// fetch), so the effect requires a direct Texture2D reference — not just a
// sampled value. The function reconstructs integer pixel coords from UV and the
// texture dimensions returned by GetDimensions.
//
// Wire InputTex as a Texture2D property (not Sampler2D). The SamplerState (SS)
// is passed through for API completeness but is NOT used in the effect math;
// all sampling is via integer .Load calls matching the WGSL textureLoad path.
//
// Inputs:
//   InputTex        — source surface (Texture2D / UnityTexture2D)
//   SS              — sampler state (unused internally; kept for SG convention)
//   UV              — 0..1 fragment UV (top-left origin)
//   Displacement    — float [0, 0.25]
//   Direction       — float [-180, 180]
//   Seed            — int   [1, 100]
//   Speed           — float [0, 2]
//   Time            — float (animation time, pass _NM_Time)
// Output:
//   Out             — float4 RGBA
// =============================================================================

#include "../../Shaders/Effects/filter/Degauss.hlsl"

void NM_Degauss_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             Displacement,
    float             Direction,
    int               Seed,
    float             Speed,
    float             Time,
    out float4        Out)
{
    // Write per-effect uniforms into the globals declared in Degauss.hlsl.
    // This mirrors how the runtime sets them via MaterialPropertyBlock.
    displacement = Displacement;
    direction    = Direction;
    seed         = Seed;
    speed        = Speed;

    // Reconstruct integer pixel coords from UV and texture size.
    // TODO(verify): _NM_Time must be wired explicitly here since NMFullscreen's
    // `time` alias is unavailable in the SG context without the NMPipeline cbuffer.
    // Pass Time = _NM_Time from a shader property.
    // Override the global `time` alias used inside nm_degauss:
    _NM_Time = Time;

    uint tw, th;
    InputTex.tex.GetDimensions(tw, th);
    float width_f  = (float)tw;
    float height_f = (float)th;

    // pixel = floor(UV * texSize); same as NM_FragCoord(i) for a fullscreen pass.
    uint2 px = uint2((uint)(UV.x * width_f), (uint)(UV.y * height_f));

    // nm_degauss uses the global `inputTex` declared in Degauss.hlsl.
    // Rebind it to the SG input texture.
    inputTex = InputTex.tex;

    Out = nm_degauss(px, width_f, height_f);
}

#endif // NM_DEGAUSS_SG_INCLUDED
