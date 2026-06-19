#ifndef NM_SG_POLAR_INCLUDED
#define NM_SG_POLAR_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for filter/polar.
//
// Drops the effect into Shader Graph as a single-pass node. Named inputs map
// directly to definition.js globals:
//   PolarMode  (int)   — 0=polar, 1=vortex          default 0
//   Scale      (float) — [-2,2]                      default 0
//   Rotation   (int)   — rot speed [-2,2]             default 0
//   Speed      (int)   — polar speed [-2,2]           default 0
//   AspectLens (int)   — 1:1 aspect bool as int       default 1
//   Antialias  (int)   — antialias bool as int        default 1
//   InputTex/SS — source surface; UV must be the input texture's 0..1 space
//   Time (float) — animation time (matches `time` engine global)
//
// Self-contained (does NOT include NMFullscreen.hlsl / NMCore.hlsl) so it is
// safe to drop into a Shader Graph Custom Function node. Helpers are mirrored
// VERBATIM from Shaders/Effects/filter/Polar.hlsl, name-prefixed `nmsg_` to
// avoid symbol clashes with the runtime include.
//
// NOTE: antialias 4-tap MSAA uses ddx/ddy which are only valid in pixel shaders.
// In SG the node runs in a pixel shader context so ddx/ddy are available.
// TODO(verify): confirm SG executes this in pixel stage on all target platforms.
// =============================================================================

static const float NM_SG_POLAR_TAU = 6.28318530718;

// smod1 — verbatim from WGSL smod1(v, m)
float nmsg_polar_smod1(float v, float m)
{
    return m * (0.75 - abs(frac(v) - 0.5) - 0.25);
}

// polarCoords — verbatim from WGSL polarCoords(uvIn, aspect, doAspect)
float2 nmsg_polar_polarCoords(float2 uvIn, float aspect, bool doAspect,
                               float scale, float rotation, float speed, float time)
{
    float2 uv = uvIn - float2(0.5, 0.5);
    if (doAspect) { uv.x = uv.x * aspect; }
    float2 coord = float2(
        atan2(uv.y, uv.x) / NM_SG_POLAR_TAU + 0.5,
        length(uv) - scale * 0.075
    );
    coord.x = nmsg_polar_smod1(coord.x + time * -rotation, 1.0);
    coord.y = nmsg_polar_smod1(coord.y + time *  speed,    1.0);
    return coord;
}

// vortexCoords — verbatim from WGSL vortexCoords(uvIn, aspect, doAspect)
float2 nmsg_polar_vortexCoords(float2 uvIn, float aspect, bool doAspect,
                                float scale, float rotation, float speed, float time)
{
    float2 uv = uvIn - float2(0.5, 0.5);
    if (doAspect) { uv.x = uv.x * aspect; }
    float r2 = dot(uv, uv) - scale * 0.01;
    uv = uv / r2;
    uv.x = nmsg_polar_smod1(uv.x + time * -rotation, 1.0);
    uv.y = nmsg_polar_smod1(uv.y + time *  speed,    1.0);
    return uv;
}

// Shader Graph Custom Function entry.
void NM_Polar_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             Time,
    int               PolarMode,
    float             Scale,
    int               Rotation,
    int               Speed,
    int               AspectLens,
    int               Antialias,
    out float4        Out)
{
    float texW, texH;
    InputTex.GetDimensions(texW, texH);
    float2 texSize = float2(texW, texH);
    float aspect   = texSize.x / texSize.y;
    bool doAspect  = (AspectLens != 0);

    float2 coord;
    [branch]
    if (PolarMode == 0)
    {
        coord = nmsg_polar_polarCoords(UV, aspect, doAspect,
                                       Scale, (float)Rotation, (float)Speed, Time);
    }
    else
    {
        coord = nmsg_polar_vortexCoords(UV, aspect, doAspect,
                                        Scale, (float)Rotation, (float)Speed, Time);
    }

    [branch]
    if (Antialias != 0)
    {
        float2 dx = ddx(coord);
        float2 dy = ddy(coord);
        float4 col = float4(0.0, 0.0, 0.0, 0.0);
        col += SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, coord + dx * -0.375 + dy * -0.125);
        col += SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, coord + dx *  0.125 + dy * -0.375);
        col += SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, coord + dx *  0.375 + dy *  0.125);
        col += SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, coord + dx * -0.125 + dy *  0.375);
        Out = col * 0.25;
    }
    else
    {
        Out = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, coord);
    }
}

#endif // NM_SG_POLAR_INCLUDED
