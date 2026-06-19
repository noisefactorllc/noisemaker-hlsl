#ifndef NM_BITEFFECTS_SG_INCLUDED
#define NM_BITEFFECTS_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/BitEffects.hlsl
//
// Shader Graph Custom Function wrapper for classicNoisedeck/bitEffects (a
// single-pass generator, so the wrapper is provided). Add a Custom Function
// node, point it at this file, select NM_BitEffects_float, and wire the named
// inputs. Outputs RGBA.
//
// The core nm_bitEffects(...) in Shaders/Effects/classicNoisedeck/BitEffects.hlsl
// reads the effect parameters from named GLOBAL uniforms. In a Shader Graph node
// those globals are unbound, so this wrapper COPIES each node input into the
// corresponding global before calling the core. Mutable HLSL global uniforms
// (declared without static const) are assignable from the entry function — the
// standard Custom-Function bridging pattern.
//
// Engine globals (resolution/time/fullResolution) are passed explicitly via the
// UV/Resolution/Time inputs so the node is self-contained. rotate2D and bitMask
// read `resolution`/`fullResolution` (NMFullscreen aliases for _NM_Resolution/
// _NM_FullResolution); seed them from the Resolution input.
//
// Define-style params (Mode/Formula/ColorScheme/Interp/MaskFormula/
// MaskColorScheme) are exposed as int inputs and branched at runtime.
// =============================================================================

#include "../../Shaders/Effects/classicNoisedeck/BitEffects.hlsl"

void NM_BitEffects_float(
    int   Mode,
    float Speed,
    int   Formula,
    int   N,
    float Scale,
    float Rotation,
    int   ColorScheme,
    int   Interp,
    int   MaskFormula,
    int   Tiles,
    float Complexity,
    int   MaskColorScheme,
    float BaseHueRange,
    float HueRotation,
    float HueRange,
    int   Seed,
    float2 UV,
    float2 Resolution,
    float  Time,
    out float4 Out)
{
    // Bridge node inputs -> the core's named global uniforms.
    MODE              = Mode;
    be_speed          = Speed;
    FORMULA           = Formula;
    be_n              = (float)N;
    be_scale          = Scale;
    be_rotation       = Rotation;
    COLOR_SCHEME      = ColorScheme;
    INTERP            = Interp;
    MASK_FORMULA      = MaskFormula;
    be_tiles          = (float)Tiles;
    be_complexity     = Complexity;
    MASK_COLOR_SCHEME = MaskColorScheme;
    be_baseHueRange   = BaseHueRange;
    be_hueRotation    = HueRotation;
    be_hueRange       = HueRange;
    be_seed           = Seed;

    // be_rotate2D() and be_bitMask() read engine `resolution`/`fullResolution`;
    // be_constant() reads the `time` alias (_NM_Time). Seed them from the inputs.
    _NM_Resolution     = float4(Resolution, 0.0, 0.0);
    _NM_FullResolution = float4(Resolution, 0.0, 0.0);
    _NM_Time           = Time;

    // globalCoord = UV * resolution (pixel-centered when UV hits a texel center).
    // tileOffset = 0 for standalone node usage. fullResolution = Resolution.
    float2 globalCoord = UV * Resolution;
    Out = nm_bitEffects(globalCoord, Resolution, Resolution, Time);
}

#endif // NM_BITEFFECTS_SG_INCLUDED
