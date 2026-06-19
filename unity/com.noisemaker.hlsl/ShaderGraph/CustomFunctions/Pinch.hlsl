#ifndef NM_SG_PINCH_INCLUDED
#define NM_SG_PINCH_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for filter/pinch.
//
// Drops the effect into Shader Graph as a node. Each global param from
// definition.js maps to a named input:
//   strength   -> Strength   (float) [0,100] default 75
//   aspectLens -> AspectLens (float, >0.5 = true) default 1
//   wrap       -> Wrap       (float cast to int: 0=mirror,1=repeat,2=clamp)
//   rotation   -> Rotation   (float) [-180,180] default 0
//   antialias  -> Antialias  (float, >0.5 = true) default 1
//
// Self-contained (does NOT include NMFullscreen.hlsl / NMCore.hlsl).
// Helpers mirrored VERBATIM from Shaders/Effects/filter/Pinch.hlsl,
// name-prefixed `nmsg_` to avoid symbol clashes with the runtime include.
//
// nm_mod is inlined as nmsg_mod to avoid the NMCore dependency.
// =============================================================================

static const float NMSG_PINCH_PI = 3.14159265359;

// nm_mod inline (floor-based float mod, matches WGSL %)
float2 nmsg_mod(float2 a, float b) { return a - b * floor(a / b); }

// rotate2D — verbatim from WGSL rotate2D()
float2 nmsg_pinch_rotate2D(float2 st, float rot, float ar)
{
    st.x = st.x * ar;
    float angle = rot * NMSG_PINCH_PI;
    st = st - float2(0.5 * ar, 0.5);
    float c = cos(angle);
    float s = sin(angle);
    st = float2(c * st.x - s * st.y, s * st.x + c * st.y);
    st = st + float2(0.5 * ar, 0.5);
    st.x = st.x / ar;
    return st;
}

// NM_Pinch_float — Shader Graph Custom Function entry.
// TODO(verify): SS must be a clamp, non-sRGB (linear) sampler state so it
// matches the runtime's bilinear/clamp/linear path (H7).
void NM_Pinch_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             Strength,
    float             AspectLens,
    float             Wrap,
    float             Rotation,
    float             Antialias,
    out float4        Out)
{
    float texW, texH;
    InputTex.GetDimensions(texW, texH);
    float ar = texW / texH;

    float2 uv = UV;

    // Apply rotation before distortion
    uv = nmsg_pinch_rotate2D(uv, Rotation / 180.0, ar);

    float intensity = Strength * 0.01;

    uv = uv - 0.5;

    if (AspectLens > 0.5)
    {
        uv.x = uv.x * ar;
    }

    float r = length(uv);
    float effect = pow(r, 1.0 - intensity);
    uv = normalize(uv) * effect;

    if (AspectLens > 0.5)
    {
        uv.x = uv.x / ar;
    }

    uv = uv + 0.5;

    int wrapMode = (int)Wrap;
    if (wrapMode == 0)
    {
        uv = abs(nmsg_mod(nmsg_mod(uv + 1.0, 2.0) + 2.0, 2.0) - 1.0);
    }
    else if (wrapMode == 1)
    {
        uv = nmsg_mod(nmsg_mod(uv, 1.0) + 1.0, 1.0);
    }
    else
    {
        uv = clamp(uv, float2(0.0, 0.0), float2(1.0, 1.0));
    }

    // Reverse rotation after distortion
    uv = nmsg_pinch_rotate2D(uv, -Rotation / 180.0, ar);

    if (Antialias > 0.5)
    {
        float2 dx = ddx(uv);
        float2 dy = ddy(uv);
        float4 col = float4(0.0, 0.0, 0.0, 0.0);
        col += SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv + dx * -0.375 + dy * -0.125);
        col += SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv + dx *  0.125 + dy * -0.375);
        col += SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv + dx *  0.375 + dy *  0.125);
        col += SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv + dx * -0.125 + dy *  0.375);
        Out = col * 0.25;
    }
    else
    {
        Out = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv);
    }
}

#endif // NM_SG_PINCH_INCLUDED
