#ifndef NM_CLOUDS_SG_INCLUDED
#define NM_CLOUDS_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Clouds.hlsl
//
// Shader Graph Custom Function wrapper for filter/clouds. Add a Custom Function
// node pointing at this file, select NM_Clouds_float, and wire inputs.
//
// NOTE: This wrapper evaluates one pixel at a time (no ping-pong textures needed)
// because the shadow offset is expressed in UV-space and computed inline. It is
// valid as a SG node when InputTex, SS, and UV are wired from a full-screen pass.
// The shadowOffset math uses InputTex dimensions (GetDimensions), matching WGSL.
//
// Inputs match definition.js globals[*].uniform names exactly.
// =============================================================================

#include "../../Shaders/Effects/filter/Clouds.hlsl"

// InputTex : source surface to composite clouds over
// SS       : sampler state (bilinear, clamp, linear/non-sRGB)
// UV       : 0..1 fragment UV (top-left origin, WGSL convention)
//            should be (fragCoord + tileOffset) / fullResolution
// FullRes  : fullResolution.xy (pass _NM_FullResolution.xy from engine)
// Time     : normalized 0..1 animation time (_NM_Time)
// Seed     : int 1..100
// Scale    : float 0.1..1.0
// Speed    : int 0..4
void NM_Clouds_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float2            FullRes,
    float             Time,
    int               Seed,
    float             Scale,
    int               Speed,
    out float4        Out)
{
    static const float TAU = 6.28318530718;

    uint tw, th;
    InputTex.tex.GetDimensions(tw, th);
    float2 texSize = float2(tw, th);

    float4 inputColor = InputTex.Sample(SS, UV);

    float aspect   = FullRes.x / FullRes.y;
    float2 seedOff = float2((float)Seed * 17.31, (float)Seed * 23.71);

    float animPhase = Time * TAU * (float)Speed;
    float animSpeed = (float)Speed;

    float2 cloudUV = UV * float2(aspect, 1.0) / Scale + seedOff;

    float cloud         = nm_clouds_cloudNoise(cloudUV, 1.0, 7, animPhase, animSpeed);
    float cloudMask     = smoothstep(0.45, 0.65, cloud);
    float cloudDepth    = smoothstep(0.45, 0.85, cloud);
    float cloudBrightness = lerp(0.75, 1.0, cloudDepth);

    float shadowDist    = min(texSize.x, texSize.y) * 0.008;
    float2 shadowOffset = float2(-shadowDist, shadowDist) / texSize;
    float2 shadowUV     = (UV + shadowOffset) * float2(aspect, 1.0) / Scale + seedOff;
    float shadowCloud   = nm_clouds_cloudNoise(shadowUV, 1.0, 7, animPhase, animSpeed);
    float shadowMask    = smoothstep(0.45, 0.65, shadowCloud);

    float shadow = max(shadowMask - cloudMask, 0.0) * 0.5;

    float3 result = inputColor.rgb * (1.0 - shadow);
    result = lerp(result, float3(cloudBrightness, cloudBrightness, cloudBrightness), cloudMask);

    Out = float4(result, inputColor.a);
}

#endif // NM_CLOUDS_SG_INCLUDED
