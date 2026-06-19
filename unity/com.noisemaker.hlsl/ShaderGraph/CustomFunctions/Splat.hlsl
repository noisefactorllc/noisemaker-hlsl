#ifndef NM_SPLAT_SG_INCLUDED
#define NM_SPLAT_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Splat.hlsl
//
// Shader Graph Custom Function wrapper for classicNoisedeck/splat. Add a Custom
// Function node, point it at this file, select NM_Splat_float, and wire the named
// inputs + InputTex / SS / UV / Resolution. Outputs RGBA.
//
// classicNoisedeck/splat is a SINGLE-PASS filter, so a wrapper ships (per the
// porting guide, only MULTI-PASS effects skip the wrapper). The effect's main()
// re-samples inputTex for the displace modes, so it is not a pure color->color
// function; this wrapper reproduces main()'s composite logic inline, calling the
// VERBATIM helper functions from Shaders/Effects/classicNoisedeck/Splat.hlsl and
// assigning the core's module-scope named uniforms from the node inputs.
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   Enabled     : enabled (bool-as-int)     SplatColor : color  (RGB)
//   Mode        : mode (0..3)               Cutoff     : cutoff (0..100)
//   Scale       : scale (1..5)              Speed      : speed (0..5)
//   Seed        : seed (1..100)
//   UseSpecks   : useSpecks (bool-as-int)   SpeckColor : speckColor (RGB)
//   SpeckMode   : speckMode (0..3)          SpeckCutoff: speckCutoff (0..100)
//   SpeckScale  : speckScale (1..5)         SpeckSpeed : speckSpeed (0..5)
//   SpeckSeed   : speckSeed (1..100)
//   InputTex    : source surface
//   SS          : sampler state (bilinear, clamp, linear/non-sRGB) for InputTex
//   UV          : 0..1 fragment UV (top-left origin, WGSL convention)
//
// COORD/SAMPLING parity: the WGSL derives uv and aspectRatio from the INPUT
// TEXTURE's own dimensions (fragCoord / dims). In a Shader Graph node the caller
// supplies UV directly; aspectRatio is computed from InputTex.GetDimensions to
// match the WGSL (NOT from a fullResolution global).
// =============================================================================

#include "../../Shaders/Effects/classicNoisedeck/Splat.hlsl"

void NM_Splat_float(
    int               Enabled,
    int               Mode,
    float             Scale,
    float             Seed,
    float3            SplatColor,
    float             Cutoff,
    float             Speed,
    int               UseSpecks,
    int               SpeckMode,
    float             SpeckScale,
    float             SpeckSeed,
    float3            SpeckColor,
    float             SpeckCutoff,
    float             SpeckSpeed,
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    enabled     = Enabled;
    mode        = Mode;
    scale       = Scale;
    seed        = Seed;
    color       = SplatColor;
    cutoff      = Cutoff;
    speed       = Speed;
    useSpecks   = UseSpecks;
    speckMode   = SpeckMode;
    speckScale  = SpeckScale;
    speckSeed   = SpeckSeed;
    speckColor  = SpeckColor;
    speckCutoff = SpeckCutoff;
    speckSpeed  = SpeckSpeed;

    // aspectRatio from the INPUT TEXTURE's own dimensions (WGSL: dims.x/dims.y).
    uint tw, th;
    InputTex.tex.GetDimensions(tw, th);
    float2 dims = float2(tw, th);
    float aspectRatioLocal = dims.x / dims.y;

    float2 uv = UV;
    float4 color_ = InputTex.Sample(SS, uv);

    float2 noiseCoord = uv * float2(aspectRatioLocal, 1.0);

    if (useSpecks != 0)
    {
        float speckMask = nm_splat_speckle(noiseCoord + speckSeed,
            float2(32.0, 32.0) * nm_splat_mapRange(speckScale, 1.0, 5.0, 2.0, 0.5));

        [branch]
        if (speckMode == 0)
        {
            color_ = float4(lerp(color_.rgb, speckColor, speckMask), color_.a); // color
        }
        else if (speckMode == 1)
        {
            color_ = InputTex.Sample(SS, uv + speckMask * 0.1); // displace
        }
        else if (speckMode == 2)
        {
            color_ = float4(lerp(color_.rgb, 1.0 - color_.rgb, speckMask), color_.a); // invert
        }
        else if (speckMode == 3)
        {
            color_ = float4(color_.rgb * speckMask, color_.a); // negative
        }
    }

    if (enabled != 0)
    {
        float splatMask = nm_splat_splat(noiseCoord + seed,
            float2(nm_splat_mapRange(scale, 1.0, 5.0, 2.0, 0.5),
                   nm_splat_mapRange(scale, 1.0, 5.0, 2.0, 0.5)));

        [branch]
        if (mode == 0)
        {
            color_ = float4(lerp(color_.rgb, color, splatMask), color_.a); // color
        }
        else if (mode == 1)
        {
            float4 texColor = InputTex.Sample(SS, uv + splatMask * 0.1); // displace
            color_ = lerp(color_, texColor, splatMask);
        }
        else if (mode == 2)
        {
            color_ = float4(lerp(color_.rgb, 1.0 - color_.rgb, splatMask), color_.a); // invert
        }
        else if (mode == 3)
        {
            color_ = float4(color_.rgb * nm_splat_mapRange(splatMask * 0.5 - 0.5, -0.25, 0.0, 0.0, 1.0), color_.a); // negative
        }
    }

    Out = color_;
}

#endif // NM_SPLAT_SG_INCLUDED
