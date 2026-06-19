#ifndef NM_PATTERNMIX_SG_INCLUDED
#define NM_PATTERNMIX_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/PatternMix.hlsl
//
// Shader Graph Custom Function wrapper for mixer/patternMix. Add a Custom
// Function node, point it at this file, select NM_PatternMix_float, and wire
// the named inputs plus the two textures/SS/UV.  Outputs RGBA.
//
// The core nm_patternMix(...) in Shaders/Effects/mixer/PatternMix.hlsl reads its
// scalar parameters from module-scope named uniforms — matching the runtime's
// individual-named-uniform binding model. In a standalone Shader Graph node those
// globals are not bound by the runtime, so this wrapper assigns the node inputs to
// them before calling nm_patternMix, bridging named inputs into the core function.
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   PatternType : patternType  (0 checkerboard .. 8 triangularGrid), default 7
//   Scale       : scale        (1..20),   default 18.0
//   Thickness   : thickness    (0..1),    default 0.5
//   Smoothness  : smoothness   (0..0.25), default 0.01
//   Rotation    : rotation     (-180..180), default 0.0
//   Invert      : invert       (0 sourceB fg, 1 sourceA fg), default 0
//   InputTex    : base surface (colorA)
//   Tex         : layer surface (colorB)
//   SS          : sampler state (bilinear, clamp, linear/non-sRGB) for both
//   UV          : 0..1 fragment UV (top-left origin, WGSL convention)
//   Resolution  : render target dimensions in pixels (to reconstruct fragPos)
//
// The WGSL samples both textures at the SAME st (derived from inputTex's size);
// here we sample both at the supplied UV with one shared sampler, matching the
// equal-sized-surface case the runtime uses. fragPos is reconstructed as UV *
// Resolution to match NM_FragCoord(). // TODO(verify): confirm Resolution matches
// inputTex's pixel dimensions in the Shader Graph context.
// =============================================================================

#include "../../Shaders/Effects/mixer/PatternMix.hlsl"

void NM_PatternMix_float(
    int               PatternType,
    float             Scale,
    float             Thickness,
    float             Smoothness,
    float             Rotation,
    int               Invert,
    UnityTexture2D    InputTex,
    UnityTexture2D    Tex,
    UnitySamplerState SS,
    float2            UV,
    float2            Resolution,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    patternType = PatternType;
    scale       = Scale;
    thickness   = Thickness;
    smoothness  = Smoothness;
    rotation    = Rotation;
    invert      = Invert;

    float4 colorA = InputTex.Sample(SS, UV);
    float4 colorB = Tex.Sample(SS, UV);

    // Reconstruct pixel-center position matching NM_FragCoord(). The WGSL derives
    // dims from textureDimensions(inputTex,0); here Resolution serves that role.
    float2 fragPos = UV * Resolution;
    Out = nm_patternMix(colorA, colorB, fragPos, Resolution);
}

#endif // NM_PATTERNMIX_SG_INCLUDED
