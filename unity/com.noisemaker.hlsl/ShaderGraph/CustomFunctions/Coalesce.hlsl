#ifndef NM_COALESCE_SG_INCLUDED
#define NM_COALESCE_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Coalesce.hlsl
//
// Shader Graph Custom Function wrapper for classicNoisedeck/coalesce.
// Add a Custom Function node, point it at this file, select NM_Coalesce_float,
// and wire the named inputs.
//
// NOTE: The core nm_coalesce() function samples inputTex/tex internally via
// module-scope Texture2D globals (the runtime binding model). This wrapper
// bridges UnityTexture2D/UnitySamplerState node inputs into those globals and
// assigns all scalar uniforms before calling nm_coalesce().
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   InputTex    : inputTex (base / input A)
//   Tex         : tex      (layer / input B)
//   SS          : sampler state (bilinear, clamp, linear/non-sRGB) for both
//   UV          : 0..1 fragment UV (top-left origin, WGSL convention)
//   BlendMode_  : blendMode (int, 0..18, 100, 1000..1005), default 10
//   MixAmt      : mixAmt   (-100..100), default 0   (definition.js key "mix")
//   RefractAAmt : refractAAmt (0..100),  default 0
//   RefractBAmt : refractBAmt (0..100),  default 0
//   RefractADir : refractADir (-180..180), default 0
//   RefractBDir : refractBDir (-180..180), default 0
//
// IMPORTANT: The cloak mode (blendMode==100) samples textures at derived UVs
// computed from st (the UV passed in). The refract non-cloak path does NOT
// frac() the refracted UV before sampling — it relies on the sampler's clamp
// mode for out-of-range values (matching the WGSL, which passes raw leftUV /
// rightUV to textureSample without frac in the non-cloak path). // TODO(verify)
// =============================================================================

#include "../../Shaders/Effects/classicNoisedeck/Coalesce.hlsl"

void NM_Coalesce_float(
    UnityTexture2D    InputTex,
    UnityTexture2D    Tex,
    UnitySamplerState SS,
    float2            UV,
    int               BlendMode_,
    float             MixAmt,
    float             RefractAAmt,
    float             RefractBAmt,
    float             RefractADir,
    float             RefractBDir,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    blendMode   = BlendMode_;
    mixAmt      = MixAmt;
    refractAAmt = RefractAAmt;
    refractBAmt = RefractBAmt;
    refractADir = RefractADir;
    refractBDir = RefractBDir;

    // Bridge texture/sampler inputs into module-scope globals.
    inputTex         = InputTex.tex;
    sampler_inputTex = SS.samplerstate;
    tex              = Tex.tex;
    sampler_tex      = SS.samplerstate;

    Out = nm_coalesce(UV);
}

#endif // NM_COALESCE_SG_INCLUDED
