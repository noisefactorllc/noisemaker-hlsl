#ifndef NM_FXAA_INCLUDED
#define NM_FXAA_INCLUDED

// =============================================================================
// Fxaa.hlsl — filter/fxaa, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/fxaa/wgsl/fxaa.wgsl
//
// Edge-aware luminance-weighted 5-tap blur (N/S/W/E + center) with reflect
// boundary, threshold early-out, and lerp(original, blended, strength) output.
//
// WGSL uses textureLoad (integer pixel coords, no sampler) for all fetches.
// HLSL equivalent: Texture2D.Load(int3(x, y, mip)).
// reflect_coord mirrors the WGSL integer reflect-boundary helper verbatim.
//
// Uniforms (definition.js globals):
//   float strength   default 1.0   [0, 1]
//   float sharpness  default 1.0   [0.1, 10]
//   float threshold  default 0.0   [0, 1]
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// Per-effect named uniforms (definition.js globals[*].uniform)
float strength;
float sharpness;
float threshold;

// WGSL: const EPSILON: f32 = 1e-10;
static const float FXAA_EPSILON = 1e-10;

// WGSL: const LUMA_WEIGHTS: vec3<f32> = vec3<f32>(0.299, 0.587, 0.114);
static const float3 LUMA_WEIGHTS = float3(0.299, 0.587, 0.114);

// WGSL fn luminance_from_rgb
float luminance_from_rgb(float3 rgb)
{
    return dot(rgb, LUMA_WEIGHTS);
}

// WGSL fn weight_from_luma
float weight_from_luma(float center_luma, float neighbor_luma, float sharp)
{
    return exp(-sharp * abs(center_luma - neighbor_luma));
}

// WGSL fn reflect_coord(coord: i32, limit: i32) -> i32
// Integer reflect-boundary. Verbatim from WGSL (int % truncates toward 0).
int reflect_coord(int coord, int limit)
{
    if (limit <= 1)
        return 0;

    int period = 2 * limit - 2;
    int wrapped = coord % period;
    if (wrapped < 0)
        wrapped = wrapped + period;

    if (wrapped < limit)
        return wrapped;

    return period - wrapped;
}

// WGSL fn load_texel — textureLoad with reflected coords
float4 nm_fxaa_load(Texture2D tex, int2 coord, int2 sz)
{
    int rx = reflect_coord(coord.x, sz.x);
    int ry = reflect_coord(coord.y, sz.y);
    return tex.Load(int3(rx, ry, 0));
}

// -----------------------------------------------------------------------------
// nm_fxaa_main — full WGSL main() body, separated for re-use in the SG wrapper.
// pixel_coord is the integer top-left pixel coordinate (== floor(fragCoord)).
// -----------------------------------------------------------------------------
float4 nm_fxaa_main(Texture2D inputTex, int2 pixel_coord, int2 sz)
{
    // WGSL: let size = vec2<i32>(textureDimensions(inputTex, 0));
    // (sz passed in, mirrors the one-line WGSL declaration)

    float4 center_texel = nm_fxaa_load(inputTex, pixel_coord,                   sz);
    float4 north_texel  = nm_fxaa_load(inputTex, pixel_coord + int2( 0, -1),    sz);
    float4 south_texel  = nm_fxaa_load(inputTex, pixel_coord + int2( 0,  1),    sz);
    float4 west_texel   = nm_fxaa_load(inputTex, pixel_coord + int2(-1,  0),    sz);
    float4 east_texel   = nm_fxaa_load(inputTex, pixel_coord + int2( 1,  0),    sz);

    float3 center_rgb = center_texel.xyz;
    float3 north_rgb  = north_texel.xyz;
    float3 south_rgb  = south_texel.xyz;
    float3 west_rgb   = west_texel.xyz;
    float3 east_rgb   = east_texel.xyz;

    float center_luma = luminance_from_rgb(center_rgb);
    float north_luma  = luminance_from_rgb(north_rgb);
    float south_luma  = luminance_from_rgb(south_rgb);
    float west_luma   = luminance_from_rgb(west_rgb);
    float east_luma   = luminance_from_rgb(east_rgb);

    // Threshold: skip AA when max luma contrast is below threshold
    float maxDiff = max(
        max(abs(center_luma - north_luma), abs(center_luma - south_luma)),
        max(abs(center_luma - west_luma),  abs(center_luma - east_luma))
    );
    if (maxDiff < threshold)
        return center_texel;

    float weight_center = 1.0;
    float weight_north  = weight_from_luma(center_luma, north_luma,  sharpness);
    float weight_south  = weight_from_luma(center_luma, south_luma,  sharpness);
    float weight_west   = weight_from_luma(center_luma, west_luma,   sharpness);
    float weight_east   = weight_from_luma(center_luma, east_luma,   sharpness);
    float weight_sum    = weight_center + weight_north + weight_south
                        + weight_west   + weight_east + FXAA_EPSILON;

    float3 blended_rgb = (
          center_rgb * weight_center
        + north_rgb  * weight_north
        + south_rgb  * weight_south
        + west_rgb   * weight_west
        + east_rgb   * weight_east
    ) / weight_sum;

    float4 result_texel = float4(blended_rgb, center_texel.w);

    // Strength: lerp between original and AA result
    // WGSL: mix(center_texel, result_texel, strength)
    return lerp(center_texel, result_texel, strength);
}

#endif // NM_FXAA_INCLUDED
