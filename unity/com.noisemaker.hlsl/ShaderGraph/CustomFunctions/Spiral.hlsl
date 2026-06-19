#ifndef NM_SG_SPIRAL_INCLUDED
#define NM_SG_SPIRAL_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for filter/spiral.
//
// Drops the effect into Shader Graph as a node. Each global param from
// definition.js maps to a named input:
//   Strength   (float) [-100,100] default -100
//   Speed      (int)   [-5,5]     default 0
//   Rotation   (float) [-180,180] default 0
//   Wrap       (int)   {0=mirror,1=repeat,2=clamp} default 0
//   AspectLens (int, bool) default 1
//   Antialias  (int, bool) default 1
// InputTex/SS/UV provide the source surface. UV must be the input texture's
// own 0..1 UV (fragCoord / inputTex dimensions, matching WGSL main() exactly).
//
// Self-contained: does NOT include NMFullscreen.hlsl / NMCore.hlsl. Helpers
// are mirrored VERBATIM from Spiral.hlsl, name-prefixed `nmsg_` to avoid
// symbol clashes with the runtime include.
//
// NOTE: The WGSL antialias path uses dpdx/dpdy (ddx/ddy). Shader Graph Custom
// Function nodes execute in a pixel shader context, so ddx/ddy are valid here.
// TODO(verify): confirm ddx/ddy are available and consistent in all SG targets.
// =============================================================================

static const float NMSG_SPIRAL_PI  = 3.14159265359;
static const float NMSG_SPIRAL_TAU = 6.28318530718;

// nm_mod (floored modulo) — inlined, no NMCore dependency
float2 nmsg_spiral_mod2(float2 a, float2 b) { return a - b * floor(a / b); }

// rotate2D — verbatim from WGSL rotate2D(st_in, rot, aspectRatio)
float2 nmsg_spiral_rotate2D(float2 st, float rot, float ar)
{
    st.x = st.x * ar;
    float angle = rot * NMSG_SPIRAL_PI;
    float c = cos(angle);
    float s = sin(angle);
    st = st - float2(0.5 * ar, 0.5);
    st = float2(c * st.x - s * st.y, s * st.x + c * st.y);
    st = st + float2(0.5 * ar, 0.5);
    st.x = st.x / ar;
    return st;
}

// Shader Graph Custom Function entry.
// UV should be inputTex-space 0..1 (fragCoord / inputTex dimensions).
// NMTime must be supplied by the caller (range 0..1, matches _NM_Time / `time`).
void NM_Spiral_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             NMTime,
    float             Strength,
    int               Speed,
    float             Rotation,
    int               Wrap,
    int               AspectLens,
    int               Antialias,
    out float4        Out)
{
    float texW, texH;
    InputTex.GetDimensions(texW, texH);
    float ar = texW / texH;
    float2 uv = UV;

    // Apply rotation before distortion
    uv = nmsg_spiral_rotate2D(uv, Rotation / 180.0, ar);

    uv = uv - 0.5;

    if (AspectLens != 0)
    {
        uv.x = uv.x * ar;
    }

    // Convert to polar coordinates
    float r = length(uv);
    float a = atan2(uv.y, uv.x);

    // Apply spiral distortion
    float spiralAmt = (Strength * 0.05) * r;
    a = a + spiralAmt - (NMTime * NMSG_SPIRAL_TAU * (float)Speed * sign(Strength));

    // Convert back to cartesian coordinates
    uv = float2(cos(a), sin(a)) * r;

    if (AspectLens != 0)
    {
        uv.x = uv.x / ar;
    }

    uv = uv + 0.5;

    // Apply wrap mode
    if (Wrap == 0)
    {
        uv = abs(nmsg_spiral_mod2(nmsg_spiral_mod2(uv + float2(1.0, 1.0), float2(2.0, 2.0)) + float2(2.0, 2.0), float2(2.0, 2.0)) - float2(1.0, 1.0));
    }
    else if (Wrap == 1)
    {
        uv = nmsg_spiral_mod2(nmsg_spiral_mod2(uv, float2(1.0, 1.0)) + float2(1.0, 1.0), float2(1.0, 1.0));
    }
    else
    {
        uv = clamp(uv, float2(0.0, 0.0), float2(1.0, 1.0));
    }

    // Reverse rotation after distortion
    uv = nmsg_spiral_rotate2D(uv, -Rotation / 180.0, ar);

    [branch]
    if (Antialias != 0)
    {
        float2 dx = ddx(uv);
        float2 dy = ddy(uv);
        float4 col = float4(0.0, 0.0, 0.0, 0.0);
        col += SAMPLE_TEXTURE2D_LOD(InputTex.tex, SS.samplerstate, uv + dx * -0.375 + dy * -0.125, 0.0);
        col += SAMPLE_TEXTURE2D_LOD(InputTex.tex, SS.samplerstate, uv + dx *  0.125 + dy * -0.375, 0.0);
        col += SAMPLE_TEXTURE2D_LOD(InputTex.tex, SS.samplerstate, uv + dx *  0.375 + dy *  0.125, 0.0);
        col += SAMPLE_TEXTURE2D_LOD(InputTex.tex, SS.samplerstate, uv + dx * -0.125 + dy *  0.375, 0.0);
        Out = col * 0.25;
    }
    else
    {
        Out = SAMPLE_TEXTURE2D_LOD(InputTex.tex, SS.samplerstate, uv, 0.0);
    }
}

#endif // NM_SG_SPIRAL_INCLUDED
