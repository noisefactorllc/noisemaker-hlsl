#ifndef NM_SG_WAVES_INCLUDED
#define NM_SG_WAVES_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for filter/waves.
//
// Drops the effect into Shader Graph as a node. Each global param from
// definition.js maps to a named input:
//   strength  -> Strength  (float) [0,100]  default 25
//   scale     -> Scale     (float) [1,5]    default 1
//   speed     -> Speed     (int)   [-5,5]   default 0
//   wrap      -> Wrap      (int)   0=mirror, 1=repeat, 2=clamp  default 0
//   rotation  -> Rotation  (float) [-180,180] default 0
//   antialias -> Antialias (int)   bool-as-int  default 1
// InputTex/SS/UV provide the source surface. UV must be the input texture's
// own 0..1 UV (fragCoord / inputTex dimensions, matching the WGSL).
//
// Self-contained (does NOT include NMFullscreen.hlsl / NMCore.hlsl).
// Helpers mirrored VERBATIM from Shaders/Effects/filter/Waves.hlsl, name-
// prefixed `nmsg_waves_` to avoid symbol clashes with the runtime include.
// =============================================================================

static const float NMSG_WAVES_PI  = 3.14159265359;
static const float NMSG_WAVES_TAU = 6.28318530718;

// nm_mod: floor-based float modulo (never fmod). Required by PORTING-GUIDE.
float2 nmsg_waves_nm_mod(float2 a, float b) { return a - b * floor(a / b); }
float  nmsg_waves_nm_mod1(float a, float b) { return a - b * floor(a / b); }

// rotate2D — verbatim from WGSL rotate2D(st_in, rot, aspectRatio).
float2 nmsg_waves_rotate2D(float2 st, float rot, float ar)
{
    st.x = st.x * ar;
    float angle = rot * NMSG_WAVES_PI;
    st = st - float2(0.5 * ar, 0.5);
    float c = cos(angle);
    float s = sin(angle);
    st = float2(c * st.x - s * st.y, s * st.x + c * st.y);
    st = st + float2(0.5 * ar, 0.5);
    st.x = st.x / ar;
    return st;
}

// Shader Graph Custom Function entry.
// TODO(verify): SS must be a clamp, non-sRGB (linear) sampler state to match
// the runtime's bilinear/clamp/linear path (H7).
void NM_Waves_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             Strength,
    float             Scale,
    int               Speed,
    int               Wrap,
    float             Rotation,
    int               Antialias,
    float             Time,
    out float4        Out)
{
    float texW, texH;
    InputTex.GetDimensions(texW, texH);
    float ar = texW / texH;

    float2 uv = UV;

    // Apply rotation before distortion
    uv = nmsg_waves_rotate2D(uv, Rotation / 180.0, ar);

    // Sine wave displacement
    uv.y = uv.y + sin(uv.x * Scale * 10.0 + Time * NMSG_WAVES_TAU * (float)Speed) * (Strength * 0.01);

    // Wrap mode
    [branch]
    if (Wrap == 0)
    {
        // mirror
        uv = abs(nmsg_waves_nm_mod(nmsg_waves_nm_mod(uv + 1.0, 2.0) + 2.0, 2.0) - 1.0);
    }
    else if (Wrap == 1)
    {
        // repeat
        uv = nmsg_waves_nm_mod(nmsg_waves_nm_mod(uv, 1.0) + 1.0, 1.0);
    }
    else
    {
        // clamp
        uv = clamp(uv, float2(0.0, 0.0), float2(1.0, 1.0));
    }

    // Reverse rotation
    uv = nmsg_waves_rotate2D(uv, -Rotation / 180.0, ar);

    // Antialias (4-tap RGSS) — ddx/ddy require a running pixel shader quad;
    // TODO(verify): Shader Graph context provides quad derivatives.
    [branch]
    if (Antialias != 0)
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

#endif // NM_SG_WAVES_INCLUDED
