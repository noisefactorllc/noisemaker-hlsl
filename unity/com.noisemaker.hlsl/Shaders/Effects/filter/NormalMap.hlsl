#ifndef NM_NORMALMAP_INCLUDED
#define NM_NORMALMAP_INCLUDED

// =============================================================================
// NormalMap.hlsl — filter/normalMap, ported PIXEL-IDENTICALLY from the
// canonical WGSL: shaders/effects/filter/normalMap/wgsl/normalMap.wgsl
//
// Normal map generation via a 3×3 Sobel filter. Each pixel reads 9 neighbours
// with wrap-around addressing (textureLoad / integer coords), computes the
// horizontal and vertical Sobel responses, and encodes them into RGB normal-map
// channels with a stylised Z component.
//
// PORTING NOTES:
//  * The WGSL is a compute shader that writes to a storage buffer using
//    textureLoad (integer pixel fetch, no sampling). In the Unity render-pass
//    path we reproduce this via Texture2D.Load(int3(x,y,0)), which gives the
//    identical bit-exact read. NM_FragCoord(i) gives the top-left pixel centre;
//    we truncate to int2 to match gid.xy in the compute shader.
//  * wrap_coord uses C-style truncate-toward-zero % — same as WGSL i32 %
//    (HLSL % is also truncate-toward-zero for integers). Manual fix for
//    negative remainders matches the WGSL verbatim.
//  * ENCODING follows the GLSL, NOT the WGSL. The parity golden is the WebGL2
//    (GLSL) backend, and here the two sources DIVERGE: GLSL uses scale 0.5, a
//    non-inverted X, and z = clamp(1 - (|dx|+|dy|)*0.5); the WGSL uses 0.25, an
//    inverted X, and a magnitude Z that is always >=1. We MUST match the GLSL to
//    match the golden. (The Sobel/oklab value-map computation is identical in both.)
//  * No per-effect globals (definition.js globals: {}). No named uniforms.
//  * channelCount = sanitize_channelCount(size.z). definition.js has no "size"
//    global and the graph passes no size uniform, so size.z = 0 and the GLSL's
//    sanitize_channelCount(0) returns 1 (the `count <= 1u` branch) — so the
//    value-map is texel.x (RED channel), and oklab/srgb/cbrt are NOT used. We
//    hard-wire channelCount = 1 to match. (See note at the channelCount decl.)
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// No per-effect named uniforms (definition.js globals: {}).

// ---------------------------------------------------------------------------
// Verbatim helper functions (ported from WGSL, per-effect copies)
// ---------------------------------------------------------------------------

static const int2 SOBEL_OFFSETS[9] = {
    int2(-1, -1), int2(0, -1), int2(1, -1),
    int2(-1,  0), int2(0,  0), int2(1,  0),
    int2(-1,  1), int2(0,  1), int2(1,  1)
};

static const float SOBEL_X_KERNEL[9] = {
     0.5,  0.0, -0.5,
     1.0,  0.0, -1.0,
     0.5,  0.0, -0.5
};

static const float SOBEL_Y_KERNEL[9] = {
     0.5,  1.0,  0.5,
     0.0,  0.0,  0.0,
    -0.5, -1.0, -0.5
};

// WGSL: fn clamp01(value : f32) -> f32
float nm_clamp01(float value)
{
    return clamp(value, 0.0, 1.0);
}

// WGSL: fn wrap_coord(value : i32, limit : i32) -> i32
int nm_wrap_coord(int value, int limit)
{
    if (limit <= 0)
        return 0;
    int wrapped = value % limit;
    if (wrapped < 0)
        wrapped = wrapped + limit;
    return wrapped;
}

// WGSL: fn srgb_to_linear(value : f32) -> f32
float nm_srgb_to_linear(float value)
{
    if (value <= 0.04045)
        return value / 12.92;
    return pow((value + 0.055) / 1.055, 2.4);
}

// WGSL: fn cbrt_safe(value : f32) -> f32
// select(b,a,c) in WGSL = c ? a : b  (reversed order — copy literally)
float nm_cbrt_safe(float value)
{
    if (value == 0.0)
        return 0.0;
    float sign_value = (value >= 0.0) ? 1.0 : -1.0;  // select(-1.0, 1.0, value >= 0.0)
    return sign_value * pow(abs(value), 1.0 / 3.0);
}

// WGSL: fn oklab_l_component(rgb : vec3<f32>) -> f32
float nm_oklab_l_component(float3 rgb)
{
    float r = nm_srgb_to_linear(nm_clamp01(rgb.x));
    float g = nm_srgb_to_linear(nm_clamp01(rgb.y));
    float b = nm_srgb_to_linear(nm_clamp01(rgb.z));

    float l = 0.4121656120 * r + 0.5362752080 * g + 0.0514575653 * b;
    float m = 0.2118591070 * r + 0.6807189584 * g + 0.1074065790 * b;
    float s = 0.0883097947 * r + 0.2818474174 * g + 0.6302613616 * b;

    float l_c = nm_cbrt_safe(l);
    float m_c = nm_cbrt_safe(m);
    float s_c = nm_cbrt_safe(s);

    return nm_clamp01(0.2104542553 * l_c + 0.7936177850 * m_c - 0.0040720468 * s_c);
}

// WGSL: fn value_map_component(texel : vec4<f32>, channelCount : u32) -> f32
float nm_value_map_component(float4 texel, uint channelCount)
{
    if (channelCount <= 1u)
        return texel.x;
    if (channelCount == 2u)
        return texel.x;
    if (channelCount == 3u)
        return nm_oklab_l_component(texel.xyz);
    // channelCount >= 4 (CHANNEL_CAP path)
    float3 clamped_rgb = clamp(texel.xyz, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
    return nm_oklab_l_component(clamped_rgb);
}

// ---------------------------------------------------------------------------
// nm_normalMap — core per-pixel evaluation.
// inputTex  : source texture, accessed via integer Load (exact texel fetch).
// fragCoord : integer pixel coordinate (top-left, matching WGSL gid.xy).
// ---------------------------------------------------------------------------
float4 nm_normalMap(Texture2D inputTex, int2 fragCoord)
{
    uint tw, th;
    inputTex.GetDimensions(tw, th);
    int width_i  = (int)tw;
    int height_i = (int)th;

    // channelCount comes from sanitize_channelCount(size.z). definition.js exposes
    // no `size` global and the graph passes no `size` uniform, so size = (0,0,0,0)
    // and size.z = 0. In the GLSL golden, sanitize_channelCount(0): as_u32(0)=0,
    // and `if (count <= 1u) return 1u` -> channelCount = 1 (NOT 4 — a prior port
    // misread this as the CHANNEL_CAP default). With channelCount == 1,
    // value_map_component returns texel.x (the RED channel) and the oklab/srgb/cbrt
    // path is never taken. Hard-wiring 4 ran the Sobel over oklab luminance instead
    // of the red channel -> wrong normal map (ssim 0.64).
    uint channelCount = 1u;

    // Sobel X
    float sobel_x = 0.0;
    [unroll]
    for (int i = 0; i < 9; i++)
    {
        int2 offset = SOBEL_OFFSETS[i];
        int sx = nm_wrap_coord(fragCoord.x + offset.x, width_i);
        int sy = nm_wrap_coord(fragCoord.y + offset.y, height_i);
        float4 texel = inputTex.Load(int3(sx, sy, 0));
        float sample_value = nm_value_map_component(texel, channelCount);
        sobel_x += sample_value * SOBEL_X_KERNEL[i];
    }

    // Sobel Y
    float sobel_y = 0.0;
    [unroll]
    for (int j = 0; j < 9; j++)
    {
        int2 offset = SOBEL_OFFSETS[j];
        int sx = nm_wrap_coord(fragCoord.x + offset.x, width_i);
        int sy = nm_wrap_coord(fragCoord.y + offset.y, height_i);
        float4 texel = inputTex.Load(int3(sx, sy, 0));
        float sample_value = nm_value_map_component(texel, channelCount);
        sobel_y += sample_value * SOBEL_Y_KERNEL[j];
    }

    // ENCODING — match the GLSL, NOT the WGSL. The parity golden is rendered by the
    // WebGL2 (GLSL) backend, and for normalMap the GLSL and WGSL DIVERGE: the WGSL
    // uses sobel_scale 0.25, an inverted X (1.0 - ...), and a magnitude-based Z that
    // is always >= 1 (would clamp to 255). The GLSL is what the golden actually runs:
    //   x_value = clamp(dx * 0.5 + 0.5)            (scale 0.5, NOT inverted)
    //   y_value = clamp(dy * 0.5 + 0.5)
    //   z_value = clamp(1.0 - (|dx| + |dy|) * 0.5) (varies in [0,1])
    // where dx = sobel_x, dy = sobel_y are the raw Sobel responses.
    float x_value = nm_clamp01(sobel_x * 0.5 + 0.5);
    float y_value = nm_clamp01(sobel_y * 0.5 + 0.5);
    float z_value = nm_clamp01(1.0 - (abs(sobel_x) + abs(sobel_y)) * 0.5);

    // Alpha: original texel alpha (WGSL: texel.w)
    float4 orig = inputTex.Load(int3(fragCoord.x, fragCoord.y, 0));

    return float4(x_value, y_value, z_value, orig.w);
}

#endif // NM_NORMALMAP_INCLUDED
