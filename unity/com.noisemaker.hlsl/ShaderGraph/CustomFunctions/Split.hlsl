#ifndef NM_SPLIT_SG_INCLUDED
#define NM_SPLIT_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Split.hlsl
//
// Shader Graph Custom Function wrapper for mixer/split. Add a Custom Function
// node, point it at this file, select NM_Split_float, and wire the inputs.
//
// The core nm_split(...) in Shaders/Effects/mixer/Split.hlsl reads its scalar
// parameters from module-scope named uniforms (position/rotation/softness/
// invert/speed). This wrapper assigns the node inputs to them before calling
// nm_split, bridging named inputs into the core function.
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   Position : position (-1..1),   default 0.0
//   Rotation : rotation (-180..180), default 0.0
//   Softness : softness (0..1),     default 0.0
//   Invert   : invert (0 off, 1 on), default 0
//   Speed    : speed (0..4),        default 0
//   InputTex : source A -> inputTex (colorA)
//   Tex      : source B -> tex      (colorB)
//   SS       : sampler state (bilinear, clamp, linear/non-sRGB) for both textures
//   UV       : 0..1 fragment UV (top-left origin, WGSL convention)
//   Resolution : output resolution in pixels (used to reconstruct pos.xy)
//
// The WGSL samples both textures at the SAME st (pos.xy / inputTex dims).
// Here we sample both at the supplied UV with a shared sampler, matching the
// equal-sized-surface case the runtime uses.
// =============================================================================

#include "../../Shaders/Effects/mixer/Split.hlsl"

void NM_Split_float(
    UnityTexture2D    InputTex,
    UnityTexture2D    Tex,
    UnitySamplerState SS,
    float2            UV,
    float2            Resolution,
    float             Position,
    float             Rotation,
    float             Softness,
    int               Invert,
    float             Speed,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    position = Position;
    rotation = Rotation;
    softness = Softness;
    invert   = Invert;
    speed    = Speed;

    float4 colorA = InputTex.Sample(SS, UV);
    float4 colorB = Tex.Sample(SS, UV);

    // Reconstruct pos.xy (pixel-centered) from UV and resolution.
    float2 pos = UV * Resolution;

    Out = nm_split(colorA, colorB, pos);
}

#endif // NM_SPLIT_SG_INCLUDED
