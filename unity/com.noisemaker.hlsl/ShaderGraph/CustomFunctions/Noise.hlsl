#ifndef NM_SG_NOISE_INCLUDED
#define NM_SG_NOISE_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for synth/noise (VNoise).
//
// Drop this into a Shader Graph "Custom Function" node (File mode), set the
// function name to `NM_Noise_float`, and wire the named inputs. The node calls
// the verbatim core `nm_noise(...)` from the effect HLSL.
//
// The core declares the per-effect params as bare mutable globals (scaleX,
// scaleY, ...) plus the engine globals (resolution/time/fullResolution/
// tileOffset via NMFullscreen). This wrapper writes the Shader-Graph inputs into
// those globals, sets the engine globals from the node inputs, then calls the
// core. UV is the canonical top-left fullscreen UV (0..1); Resolution is the
// full (untiled) render size in pixels (used as fullResolution AND resolution;
// tileOffset is 0 in the Shader-Graph single-pass case).
//
// NOTE: Effects/synth/Noise.hlsl includes NMFullscreen.hlsl which declares the
// engine globals (resolution/time/fullResolution/tileOffset/...) we assign to.
// =============================================================================

// Resolve include relative to this file's location in the package.
#include "../../Shaders/Effects/synth/Noise.hlsl"

// All inputs are named to match definition.js globals[*] (uniform names) plus
// the two compile-time-define-promoted ints (noiseType -> NOISE_TYPE,
// loopOffset -> LOOP_OFFSET). UV/Resolution/Time are the engine inputs.
void NM_Noise_float(
    float  In_scaleX,
    float  In_scaleY,
    float  In_seed,
    float  In_loopScale,
    float  In_speed,
    float  In_octaves,     // Shader Graph has no int port; pass as float, trunc below.
    float  In_ridges,      // boolean as 0/1 float; core tests > 0.5
    float  In_wrap,        // boolean as 0/1 float; core tests > 0.5
    float  In_colorMode,
    float  In_noiseType,   // -> NOISE_TYPE (default 10)
    float  In_loopOffset,  // -> LOOP_OFFSET (default 300)
    float  In_time,
    float2 UV,
    float2 Resolution,
    out float4 Out)
{
    // Per-effect param globals (declared in Noise.hlsl).
    scaleX    = In_scaleX;
    scaleY    = In_scaleY;
    seed      = In_seed;
    loopScale = In_loopScale;
    speed     = In_speed;
    octaves   = (int)In_octaves;
    ridges    = (int)(In_ridges > 0.5 ? 1 : 0);
    wrap      = (int)(In_wrap   > 0.5 ? 1 : 0);
    colorMode = (int)In_colorMode;
    NOISE_TYPE  = (int)In_noiseType;
    LOOP_OFFSET = (int)In_loopOffset;

    // Engine globals consumed by the core (NMFullscreen aliases).
    _NM_Time            = In_time;
    _NM_Resolution      = float4(Resolution, 0.0, 0.0);
    _NM_FullResolution  = float4(Resolution, 0.0, 0.0);
    _NM_TileOffset      = float4(0.0, 0.0, 0.0, 0.0);

    // fragCoord = pixel-centered coord = UV * resolution. tileOffset = 0.
    float2 fragCoord = UV * Resolution;
    Out = nm_noise(fragCoord, float2(0.0, 0.0), Resolution);
}

#endif // NM_SG_NOISE_INCLUDED
