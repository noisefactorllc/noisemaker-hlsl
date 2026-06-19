#ifndef NM_SG_TUNNEL_INCLUDED
#define NM_SG_TUNNEL_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for filter/tunnel.
//
// Drops the effect into Shader Graph as a node. Each global param from
// definition.js maps to a named input. InputTex/SS/UV provide the source
// surface. UV must be the input texture's own 0..1 UV (fragCoord / texDims).
//
// Self-contained (does NOT include NMFullscreen.hlsl / NMCore.hlsl) so it is
// safe to drop into a Shader Graph Custom Function node. Helpers are mirrored
// VERBATIM from Shaders/Effects/filter/Tunnel.hlsl, name-prefixed `nmsg_` to
// avoid symbol clashes with the runtime include.
//
// NOTE: `time` must be supplied externally (e.g. _Time.y or a custom float).
// The runtime passes _NM_Time; in Shader Graph wire a Time node or float input.
// =============================================================================

static const float NM_SG_TUNNEL_PI  = 3.14159265359;
static const float NM_SG_TUNNEL_TAU = 6.28318530718;

// polygonShape — verbatim from WGSL (note reversed atan2(uv.x, uv.y) arg order)
float nmsg_tunnel_polygonShape(float2 uv, int sides)
{
    float a = atan2(uv.x, uv.y) + NM_SG_TUNNEL_PI;
    float r = NM_SG_TUNNEL_TAU / (float)sides;
    return cos(floor(0.5 + a / r) * r - a) * length(uv);
}

// smod2 — verbatim from WGSL
float2 nmsg_tunnel_smod2(float2 v, float m)
{
    return m * (0.75 - abs(frac(v) - 0.5) - 0.25);
}

// Core tunnel logic — param-injected, verbatim from Tunnel.hlsl NMFrag_tunnel().
// TODO(verify): SS must be a clamp, non-sRGB (linear) sampler state.
void NM_Tunnel_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             Time,
    int               Shape,
    float             Scale,
    float             Speed,
    float             Rotation,
    float             Center,
    int               AspectLens,
    int               Antialias,
    out float4        Out)
{
    float texW, texH;
    InputTex.GetDimensions(texW, texH);
    float2 texSize = float2(texW, texH);

    float2 centered = UV - 0.5;

    [branch] if (AspectLens != 0)
    {
        centered.x = centered.x * (texSize.x / texSize.y);
    }

    float a = atan2(centered.y, centered.x);
    float r;

    [branch] if (Shape == 0)
    {
        r = length(centered);
    }
    else if (Shape == 1)
    {
        r = nmsg_tunnel_polygonShape(centered * 2.0, 3);
    }
    else if (Shape == 2)
    {
        float2 p = centered * centered * centered * centered *
                   centered * centered * centered * centered;
        r = pow(p.x + p.y, 1.0 / 8.0);
    }
    else if (Shape == 3)
    {
        r = nmsg_tunnel_polygonShape(centered * 2.0, 4);
    }
    else if (Shape == 4)
    {
        r = nmsg_tunnel_polygonShape(centered * 2.0, 6);
    }
    else
    {
        r = nmsg_tunnel_polygonShape(centered * 2.0, 8);
    }

    r -= Scale * 0.15;

    float2 tunnelCoords = nmsg_tunnel_smod2(float2(
        0.3 / r + Time * Speed,
        a / NM_SG_TUNNEL_PI + Time * Rotation
    ), 1.0);

    float4 color;
    [branch] if (Antialias != 0)
    {
        float2 dx = ddx(tunnelCoords);
        float2 dy = ddy(tunnelCoords);
        color = float4(0.0, 0.0, 0.0, 0.0);
        color += SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, tunnelCoords + dx * -0.375 + dy * -0.125);
        color += SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, tunnelCoords + dx *  0.125 + dy * -0.375);
        color += SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, tunnelCoords + dx *  0.375 + dy *  0.125);
        color += SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, tunnelCoords + dx * -0.125 + dy *  0.375);
        color = color * 0.25;
    }
    else
    {
        color = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, tunnelCoords);
    }

    [branch] if (Center != 0.0)
    {
        float centerMask = smoothstep(0.0, 0.5, r);
        float amt = Center / 100.0;
        [branch] if (amt < 0.0)
        {
            color = float4(color.rgb * lerp(1.0, centerMask, -amt), color.a);
        }
        else
        {
            color = float4(lerp(color.rgb, float3(1.0, 1.0, 1.0), (1.0 - centerMask) * amt), color.a);
        }
    }

    Out = color;
}

#endif // NM_SG_TUNNEL_INCLUDED
