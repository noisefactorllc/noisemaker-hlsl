#ifndef NM_GABOR_SG_INCLUDED
#define NM_GABOR_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Gabor.hlsl
//
// Shader Graph Custom Function wrapper for synth/gabor (single-pass generator).
// Add a Custom Function node, point it at this file, select NM_Gabor_float, and
// wire the named inputs. Outputs RGBA.
//
// The core nm_gabor(...) in Shaders/Effects/synth/Gabor.hlsl reads the effect
// parameters from named GLOBAL uniforms (scale, orientation, ...). In a Shader
// Graph node those globals are unbound, so this wrapper COPIES each node input
// into the corresponding global before calling the core. HLSL global uniforms
// declared without `static const` are mutable storage assignable from the entry
// function, which is the standard Custom-Function bridging pattern.
//
// Engine globals (fullResolution/time) are passed explicitly via the
// UV/Resolution/Time inputs so the node is self-contained and does not depend on
// NMFullscreen's per-frame globals being set.
//
// NOTE: Seed is exposed as float because the WGSL reads `seed` from a float slot
// and does float arithmetic (seed + fi*17.0). definition.js types it `int`, but
// integer values pass through float exactly for the [1,100] range used.
// =============================================================================

#include "../../Shaders/Effects/synth/Gabor.hlsl"

void NM_Gabor_float(
    float Scale,
    float Orientation,
    float Bandwidth,
    float Isotropy,
    int   Density,
    int   Octaves,
    int   Speed,
    float Seed,
    float2 UV,
    float2 Resolution,
    float  Time,
    out float4 Out)
{
    // Bridge node inputs -> the core's named global uniforms.
    scale       = Scale;
    orientation = Orientation;
    bandwidth   = Bandwidth;
    isotropy    = Isotropy;
    density     = Density;
    octaves     = Octaves;
    speed       = Speed;
    seed        = Seed;

    // globalCoord = UV * resolution (pixel-centered when UV hits a texel center).
    // tileOffset = 0 for standalone node usage. fullResolution = Resolution.
    float2 globalCoord = UV * Resolution;
    Out = nm_gabor(globalCoord, Resolution, Time);
}

#endif // NM_GABOR_SG_INCLUDED
