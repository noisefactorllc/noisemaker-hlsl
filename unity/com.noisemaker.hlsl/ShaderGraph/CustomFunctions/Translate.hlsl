#ifndef NM_TRANSLATE_SG_INCLUDED
#define NM_TRANSLATE_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Translate.hlsl
//
// Shader Graph Custom Function wrapper for filter/translate. Add a Custom
// Function node, point it at this file, select NM_Translate_float, and wire
// the inputs. Outputs RGBA.
//
// Params from definition.js globals:
//   x    (float, [-1,1], default 0)  — horizontal translation
//   y    (float, [-1,1], default 0)  — vertical translation
//   wrap (int,   choices 0/1/2)      — 0=mirror, 1=repeat, 2=clamp
//
// UV must be fragCoord / input texture dimensions (0..1, top-left origin).
// The runtime divides NM_FragCoord by the input texture's own size before
// calling this function — the WGSL does the same.
//
// Self-contained: does NOT include NMFullscreen.hlsl / NMCore.hlsl.
// nm_mod is mirrored verbatim (floor-based float mod, never fmod) with the
// nmsg_ prefix to avoid symbol clashes with the runtime include.
// =============================================================================

// nm_mod — floor-based float modulo, verbatim parity requirement (never fmod).
float2 nmsg_mod2(float2 a, float2 b) { return a - b * floor(a / b); }

void NM_Translate_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             X,
    float             Y,
    int               Wrap,
    out float4        Out)
{
    float2 uv = UV;

    // WGSL: uv.x = uv.x - uniforms.x;  uv.y = uv.y - uniforms.y;
    uv.x = uv.x - X;
    uv.y = uv.y - Y;

    // WGSL wrap mode branches — WGSL % on float is floor-based -> nmsg_mod2
    [branch]
    if (Wrap == 0)
    {
        // mirror: abs(((uv + 1.0) % 2.0 + 2.0) % 2.0 - 1.0)
        uv = abs(nmsg_mod2(nmsg_mod2(uv + float2(1.0, 1.0), float2(2.0, 2.0)) + float2(2.0, 2.0), float2(2.0, 2.0)) - float2(1.0, 1.0));
    }
    else if (Wrap == 1)
    {
        // repeat: (uv % 1.0 + 1.0) % 1.0
        uv = nmsg_mod2(nmsg_mod2(uv, float2(1.0, 1.0)) + float2(1.0, 1.0), float2(1.0, 1.0));
    }
    else
    {
        // clamp
        uv = clamp(uv, float2(0.0, 0.0), float2(1.0, 1.0));
    }

    Out = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv);
}

#endif // NM_TRANSLATE_SG_INCLUDED
