#ifndef NM_FXAA_SG_INCLUDED
#define NM_FXAA_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Fxaa.hlsl
//
// Shader Graph Custom Function wrapper for filter/fxaa. Add a Custom Function
// node, point it at this file, select NM_Fxaa_float, and wire inputs.
//
// NOTE: This wrapper calls nm_fxaa_main which uses Texture2D.Load (integer pixel
// coords). UV is converted to pixel coords internally using the texture
// dimensions. The SamplerState input is accepted for API consistency but is NOT
// used — all fetches go through Load, matching the WGSL textureLoad path.
// TODO(verify): Shader Graph UnityTexture2D.tex exposes the underlying
// Texture2D for Load; confirm this works across all SRP targets.
// =============================================================================

#include "../../Shaders/Effects/filter/Fxaa.hlsl"

// InputTex  : source surface to anti-alias (UnityTexture2D wraps Texture2D)
// SS        : sampler state (accepted for API consistency; not used — Load path)
// UV        : 0..1 fragment UV (top-left origin, WGSL convention)
// Strength  : blend weight between original and AA result [0, 1]
// Sharpness : luma-difference sharpness for neighbor weights [0.1, 10]
// Threshold : max luma contrast below which AA is skipped [0, 1]
void NM_Fxaa_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             Strength,
    float             Sharpness,
    float             Threshold,
    out float4        Out)
{
    // Write uniforms into the expected globals before calling nm_fxaa_main.
    // (These globals are declared in Fxaa.hlsl and read by the helper functions.)
    strength  = Strength;
    sharpness = Sharpness;
    threshold = Threshold;

    uint tw, th;
    InputTex.tex.GetDimensions(tw, th);
    int2 sz = int2((int)tw, (int)th);

    // Convert UV to integer pixel coordinate, matching WGSL position.xy truncation.
    float2 fc = UV * float2(tw, th);
    int2 pixel_coord = int2((int)fc.x, (int)fc.y);

    Out = nm_fxaa_main(InputTex.tex, pixel_coord, sz);
}

#endif // NM_FXAA_SG_INCLUDED
