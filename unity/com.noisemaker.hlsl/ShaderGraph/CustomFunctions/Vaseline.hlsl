#ifndef NM_SG_VASELINE_INCLUDED
#define NM_SG_VASELINE_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for filter/vaseline.
//
// Drops the effect into Shader Graph as a node. The single global param maps to:
//   alpha -> Alpha (float) [0,1] default 0.5
// InputTex/SS provide the source surface. UV must be the input texture's own
// 0..1 UV (fragCoord / texDimensions, matching the WGSL fullscreen path).
//
// Self-contained: does NOT include NMFullscreen.hlsl / NMCore.hlsl.
// Helpers are mirrored VERBATIM from Vaseline.hlsl, name-prefixed `nmsg_` to
// avoid symbol clashes with the runtime include.
//
// TODO(verify): SS must be a linear (non-sRGB), clamp-to-edge SamplerState to
// match the runtime bilinear/clamp/linear path (H7).
// =============================================================================

static const int   NMSG_VASELINE_TAP_COUNT         = 32;
static const float NMSG_VASELINE_RADIUS             = 48.0;
static const float NMSG_VASELINE_GOLDEN_ANGLE       = 2.39996323;
static const float NMSG_VASELINE_BRIGHTNESS_ADJUST  = 0.15;

float3 nmsg_vaseline_clamp01v(float3 v)
{
    return clamp(v, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

float nmsg_vaseline_chebyshev_mask(float2 uv)
{
    float2 centered = abs(uv - float2(0.5, 0.5)) * 2.0;
    return max(centered.x, centered.y);
}

void NM_Vaseline_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             Alpha,
    out float4        Out)
{
    float texW, texH;
    InputTex.tex.GetDimensions(texW, texH);
    float2 fullSize = float2(texW, texH);

    // textureLoad equivalent: Load at integer pixel coord
    int2   coord    = int2((int)(UV.x * texW), (int)(UV.y * texH));
    float4 original = InputTex.tex.Load(int3(coord, 0));

    float a = clamp(Alpha, 0.0, 1.0);

    if (a <= 0.0)
    {
        Out = float4(nmsg_vaseline_clamp01v(original.rgb), original.a);
        return;
    }

    float2 texelSize = 1.0 / fullSize;
    float2 radiusUV  = NMSG_VASELINE_RADIUS * texelSize;

    float3 blurAccum = float3(0.0, 0.0, 0.0);
    float  weightSum = 0.0;

    for (int idx = 0; idx < NMSG_VASELINE_TAP_COUNT; idx = idx + 1)
    {
        float t       = (float)idx / (float)NMSG_VASELINE_TAP_COUNT;
        float r       = sqrt(t);
        float theta   = (float)idx * NMSG_VASELINE_GOLDEN_ANGLE;
        float2 offset = float2(cos(theta), sin(theta)) * r;

        float sigma  = 0.4;
        float weight = exp(-0.5 * (r * r) / (sigma * sigma));

        float2 sampleUV = clamp(UV + offset * radiusUV, float2(0.0, 0.0), float2(1.0, 1.0));
        blurAccum = blurAccum + SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, sampleUV).rgb * weight;
        weightSum = weightSum + weight;
    }

    float3 blurred = blurAccum / weightSum;
    float3 boosted = nmsg_vaseline_clamp01v(blurred + float3(NMSG_VASELINE_BRIGHTNESS_ADJUST, NMSG_VASELINE_BRIGHTNESS_ADJUST, NMSG_VASELINE_BRIGHTNESS_ADJUST));

    float edgeMask = nmsg_vaseline_chebyshev_mask(UV);
    edgeMask = smoothstep(0.0, 0.8, edgeMask);

    float3 sourceClamped = nmsg_vaseline_clamp01v(original.rgb);
    float3 bloomed       = nmsg_vaseline_clamp01v((sourceClamped + boosted) * 0.5);
    float3 edgeBlended   = lerp(sourceClamped, bloomed, edgeMask);
    float3 finalRgb      = nmsg_vaseline_clamp01v(lerp(sourceClamped, edgeBlended, a));

    Out = float4(finalRgb, original.a);
}

#endif // NM_SG_VASELINE_INCLUDED
