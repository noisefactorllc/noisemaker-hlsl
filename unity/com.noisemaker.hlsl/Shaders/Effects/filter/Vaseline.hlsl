#ifndef NM_EFFECT_VASELINE_INCLUDED
#define NM_EFFECT_VASELINE_INCLUDED

// =============================================================================
// Vaseline.hlsl — filter/vaseline (func: "vaseline")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/filter/vaseline/wgsl/upsample.wgsl
//
// N-tap golden-angle-spiral blur with edge-weighted blending.
// Single render pass ("upsample"). RGB is blurred + bloomed; alpha passthrough.
//
// PORTING-GUIDE notes / hazards:
//  * WGSL uses `textureLoad(inputTex, coord, 0)` for `original` (exact pixel at
//    fragCoord integer coord) and `textureSample(inputTex, inputSampler, sampleUV)`
//    for the spiral taps. We mirror both: Load via .Load(int3(px,py,0)) and Sample.
//  * WGSL derives `uv` as `(vec2f(coord) + 0.5) / fullSize` where fullSize =
//    params.resolution. In the fullscreen pipeline params.resolution == the input
//    texture dimensions, so we use NM_FragCoord(i) / float2(texW, texH).
//  * radiusUV = RADIUS * texelSize (scalar * vec2). No renderScale in WGSL.
//  * `chebyshev_mask` and `clamp01v` are effect-local helpers — copied verbatim.
//  * Constants TAP_COUNT/RADIUS/GOLDEN_ANGLE/BRIGHTNESS_ADJUST match WGSL exactly.
//  * `mix` -> `lerp`; `smoothstep`/`clamp`/`sqrt`/`cos`/`sin`/`exp` map 1:1.
//  * float3(0.0) splats, float2(0.0)/float2(1.0) clamp bounds match WGSL.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler ------------------------------------------------
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect uniforms (definition.js globals[*].uniform) ----------------
float alpha;  // [0,1]  default 0.5

// ---- Effect-local constants (WGSL: const) -----------------------------------
static const int   TAP_COUNT        = 32;
static const float RADIUS           = 48.0;
static const float GOLDEN_ANGLE     = 2.39996323;
static const float BRIGHTNESS_ADJUST = 0.15;

// ---- Effect-local helpers (verbatim from WGSL) ------------------------------

// clamp01v — verbatim from WGSL `clamp01v(v: vec3f)`
float3 nm_vaseline_clamp01v(float3 v)
{
    return clamp(v, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

// chebyshev_mask — verbatim from WGSL `chebyshev_mask(uv: vec2f)`
float nm_vaseline_chebyshev_mask(float2 uv)
{
    float2 centered = abs(uv - float2(0.5, 0.5)) * 2.0;
    return max(centered.x, centered.y);
}

// =============================================================================
// NMFrag_upsample — pass "main", program "upsample"
//
// WGSL main() body translated:
//   coord    = vec2i(fragCoord.xy)
//   fullSize = params.resolution  (== input tex dims in fullscreen pipeline)
//   uv       = (vec2f(coord) + 0.5) / fullSize
//   original = textureLoad(inputTex, coord, 0)
//   a        = clamp(alpha, 0, 1)
//   early-out if a <= 0
//   texelSize = 1.0 / fullSize
//   radiusUV  = RADIUS * texelSize
//   spiral gather loop i in [0, TAP_COUNT)
//   blurred  = blurAccum / weightSum
//   boosted  = clamp01v(blurred + BRIGHTNESS_ADJUST)
//   edgeMask = smoothstep(0, 0.8, chebyshev_mask(uv))
//   sourceClamped = clamp01v(original.rgb)
//   bloomed  = clamp01v((sourceClamped + boosted) * 0.5)
//   edgeBlended = mix(sourceClamped, bloomed, edgeMask)
//   finalRgb = clamp01v(mix(sourceClamped, edgeBlended, a))
//   return vec4(finalRgb, original.a)
// =============================================================================
float4 NMFrag_upsample(NMVaryings i) : SV_Target
{
    uint texW, texH;
    inputTex.GetDimensions(texW, texH);
    float2 fullSize = float2((float)texW, (float)texH);

    float2 fragCoordPx = NM_FragCoord(i);
    int2   coord       = int2((int)fragCoordPx.x, (int)fragCoordPx.y);
    float2 uv          = (float2(coord) + 0.5) / fullSize;

    // textureLoad(inputTex, coord, 0) -> Load with mip=0
    float4 original = inputTex.Load(int3(coord, 0));

    float a = clamp(alpha, 0.0, 1.0);

    if (a <= 0.0)
    {
        return float4(nm_vaseline_clamp01v(original.rgb), original.a);
    }

    float2 texelSize = 1.0 / fullSize;
    float2 radiusUV  = RADIUS * texelSize;

    // N-tap gather using golden angle spiral
    float3 blurAccum = float3(0.0, 0.0, 0.0);
    float  weightSum = 0.0;

    for (int idx = 0; idx < TAP_COUNT; idx = idx + 1)
    {
        float t       = (float)idx / (float)TAP_COUNT;
        float r       = sqrt(t);
        float theta   = (float)idx * GOLDEN_ANGLE;
        float2 offset = float2(cos(theta), sin(theta)) * r;

        float sigma  = 0.4;
        float weight = exp(-0.5 * (r * r) / (sigma * sigma));

        float2 sampleUV = clamp(uv + offset * radiusUV, float2(0.0, 0.0), float2(1.0, 1.0));
        blurAccum = blurAccum + inputTex.Sample(sampler_inputTex, sampleUV).rgb * weight;
        weightSum = weightSum + weight;
    }

    float3 blurred = blurAccum / weightSum;
    float3 boosted = nm_vaseline_clamp01v(blurred + float3(BRIGHTNESS_ADJUST, BRIGHTNESS_ADJUST, BRIGHTNESS_ADJUST));

    // Edge mask - more effect at edges
    float edgeMask = nm_vaseline_chebyshev_mask(uv);
    edgeMask = smoothstep(0.0, 0.8, edgeMask);

    float3 sourceClamped = nm_vaseline_clamp01v(original.rgb);
    float3 bloomed       = nm_vaseline_clamp01v((sourceClamped + boosted) * 0.5);
    float3 edgeBlended   = lerp(sourceClamped, bloomed, edgeMask);
    float3 finalRgb      = nm_vaseline_clamp01v(lerp(sourceClamped, edgeBlended, a));

    return float4(finalRgb, original.a);
}

#endif // NM_EFFECT_VASELINE_INCLUDED
