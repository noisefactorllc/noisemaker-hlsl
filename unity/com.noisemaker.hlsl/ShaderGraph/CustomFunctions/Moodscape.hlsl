#ifndef NM_SG_MOODSCAPE_INCLUDED
#define NM_SG_MOODSCAPE_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for classicNoisedeck/moodscape.
//
// Drop this into a Shader Graph "Custom Function" node (File mode), set the
// function name to `NM_Moodscape_float`, and wire the named inputs. The node
// calls the verbatim core `nm_moodscape(...)` from the effect HLSL.
//
// The core declares the per-effect params as bare mutable globals (noiseScale,
// speed, ...) plus the two compile-time-define-promoted ints (interp ->
// NOISE_TYPE, colorMode -> COLOR_MODE) and the engine globals
// (resolution/time/fullResolution/tileOffset via NMFullscreen). This wrapper
// writes the Shader-Graph inputs into those globals, sets the engine globals
// from the node inputs, then calls the core. UV is the canonical top-left
// fullscreen UV (0..1); Resolution is the full (untiled) render size in pixels
// (used as fullResolution AND resolution; tileOffset is 0 in the single-pass
// Shader-Graph case).
//
// NOTE: Shaders/Effects/classicNoisedeck/Moodscape.hlsl includes
// NMFullscreen.hlsl which declares the engine globals we assign to.
// =============================================================================

#include "../../Shaders/Effects/classicNoisedeck/Moodscape.hlsl"

// Inputs named to match definition.js globals[*] (uniform names) plus the two
// define-promoted ints (interp -> NOISE_TYPE, colorMode -> COLOR_MODE).
// Shader Graph has no int port, so ints/booleans arrive as float and are cast.
void NM_Moodscape_float(
    float  In_interp,       // -> NOISE_TYPE (default 10)
    float  In_colorMode,    // -> COLOR_MODE (default 2)
    float  In_noiseScale,
    float  In_speed,
    float  In_refractAmt,
    float  In_ridges,       // boolean as 0/1 float; core tests > 0
    float  In_wrap,         // boolean as 0/1 float; core tests > 0
    float  In_seed,
    float  In_hueRotation,
    float  In_hueRange,
    float  In_intensity,
    float2 UV,
    float2 Resolution,
    float  Time,
    out float4 Out)
{
    NOISE_TYPE  = (int)In_interp;
    COLOR_MODE  = (int)In_colorMode;
    noiseScale  = In_noiseScale;
    speed       = In_speed;
    refractAmt  = In_refractAmt;
    ridges      = (In_ridges > 0.5) ? 1 : 0;
    wrap        = (In_wrap   > 0.5) ? 1 : 0;
    seed        = (int)In_seed;
    hueRotation = In_hueRotation;
    hueRange    = In_hueRange;
    intensity   = In_intensity;

    // Engine globals consumed by the core (NMFullscreen aliases).
    _NM_Time           = Time;
    _NM_Resolution     = float4(Resolution, 0.0, 0.0);
    _NM_FullResolution = float4(Resolution, 0.0, 0.0);
    _NM_TileOffset     = float4(0.0, 0.0, 0.0, 0.0);

    // globalCoord = UV * resolution (pixel-centered at texel centers). tile=0.
    float2 globalCoord = UV * Resolution;
    Out = nm_moodscape(globalCoord, Resolution, Resolution, Time);
}

#endif // NM_SG_MOODSCAPE_INCLUDED
