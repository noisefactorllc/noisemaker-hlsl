#ifndef NM_EFFECT_WORMHOLE_INCLUDED
#define NM_EFFECT_WORMHOLE_INCLUDED

// =============================================================================
// Wormhole.hlsl — filter/wormhole (func: "wormhole")
//
// Luminance-driven scatter displacement field. Each input pixel is scattered to
// a destination texel chosen by its OKLab L channel; deposits accumulate, then
// the buffer is mean-normalized, sqrt'd, and blended with the original.
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL sources (top-left origin):
//   wgsl/clear.wgsl     progName "clear"     (frag_clear)          FULLSCREEN
//   wgsl/deposit.wgsl   progName "deposit"   (vert_deposit /       DEPOSIT-POINTS
//                                             frag_deposit)
//   wgsl/blend.wgsl     progName "blend"     (frag_blend)          FULLSCREEN
//
// MULTI-PASS / POINTS-SCATTER (NO persistent feedback): 3 passes per frame in
// definition order: clear -> deposit -> blend. There is NO 'global_' agent
// state and NO frame-to-frame feedback; this wormhole is a single-frame scatter
// (unlike the agent-based pattern). The only intermediate is the transient
// accumulation texture wormhole_accum (rgba16f, full-res), cleared then scattered
// into additively (Blend One One), then consumed by blend. It is a regular
// POOLED graph texture (NOT 'global_'-prefixed, NOT persisted).
//
// DEPOSIT pass: drawMode:"points", count:"input" → the runtime issues
// DrawProcedural(Points, N) with N = inputTex.width * inputTex.height (ONE point
// per INPUT pixel — NOT a stateSize*stateSize agent grid; there are no agents).
// vert_deposit reads inputTex per SV_VertexID in the VERTEX stage (SM4.5 allows
// VS texture Load), computes the scatter destination texel exactly as the WGSL
// vertex shader, transforms it to clip space, and emits a 1px point (D3D points
// are 1px, matching the reference's gl_PointSize=1.0 / WebGPU 1px deposit). The
// fragment emits the deposit color; the pass uses additive Blend One One.
//
// NOTE: multi-pass + points-scatter effect → ships as a runtime-rendered
// Texture2D. NO Shader Graph Custom Function wrapper is provided (the C# runtime
// drives the 3 passes in order, binding wormhole_accum read/write per pass and
// issuing the points draw for deposit).
//
// PORTING-GUIDE / parity notes:
//  * Ported from WGSL (canonical). The WGSL deposit vertex applies a WebGPU Y
//    flip (clipY = 1 - (destY+0.5)/h*2). Unity/D3D is top-left like WebGPU, so we
//    reproduce the WGSL clip mapping VERBATIM (clipX = (destX+0.5)/w*2-1; clipY =
//    1 - (destY+0.5)/h*2). The GLSL deposit.vert uses clipY = (destY+0.5)/h*2-1
//    (bottom-left); per Golden Rule #1 we port from the WGSL, not the GLSL.
//    // TODO(verify): confirm no double Y flip vs NM_FLIP_Y at the framebuffer.
//  * Off-screen culling uses clip (2,2,0,1) like the WGSL (NDC>1 → fully clipped),
//    NOT the GLSL gl_PointSize=0 path. Same visual result.
//  * WGSL textureLoad(inputTex, vec2<i32>(x,y), 0) → inputTex.Load(int3(x,y,0))
//    (integer texel fetch, point, no filtering) — used in the VERTEX stage.
//  * WGSL textureSampleLevel(t, s, uv, 0.0) → t.SampleLevel(sampler_t, uv, 0.0)
//    (linear, clamp-to-edge, non-sRGB) — used by frag_blend for inputTex/accumTex.
//  * Integer wrap arithmetic uses HLSL `%` (trunc-toward-zero, matching WGSL i32
//    `%`); the reference re-adds the modulus (`((x % w) + w) % w`) to fix negatives
//    rather than nm_positiveModulo — reproduced VERBATIM.
//  * radians(deg) = deg * (PI/180). fract→frac, mix→lerp.
//  * oklabL ported verbatim, inline, per program. NONE of the NMCore primitives
//    (pcg/prng/random/nm_mod/...) are used by this effect.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Inputs (runtime rebinds per pass per definition.js inputs{}) -----------
// deposit: inputTex (Load, vertex stage)
// blend:   inputTex (Sample), accumTex (Sample)
Texture2D    inputTex;   SamplerState sampler_inputTex;
Texture2D    accumTex;   SamplerState sampler_accumTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
// deposit: kink, stride, rotation, wrap
// blend:   alpha
float kink;       // globals.kink     default 1
float stride;     // globals.stride   default 1
float rotation;   // globals.rotation default 0   (degrees)
int   wrap;       // globals.wrap     default 1    (0=mirror,1=repeat,2=clamp)
float alpha;      // globals.alpha    default 1

static const float TAU = 6.28318530717959;

// OKLab L channel extraction (matches JS rgbToOklab -> L). Ported verbatim.
float wormhole_oklabL(float3 rgb)
{
    float3 c = clamp(rgb, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
    float l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
    float m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
    float s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;
    float l_ = pow(max(l, 0.0), 1.0 / 3.0);
    float m_ = pow(max(m, 0.0), 1.0 / 3.0);
    float s_ = pow(max(s, 0.0), 1.0 / 3.0);
    return 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_;
}

// =============================================================================
// PASS: clear — zero the accumulation texture (frag_clear)
// =============================================================================
float4 frag_clear(NMVaryings i) : SV_Target
{
    return float4(0.0, 0.0, 0.0, 0.0);
}

// =============================================================================
// PASS: deposit — points-scatter input pixels into the accumulation texture
// drawMode:"points"; count:"input" → N = inputTex.w * inputTex.h points
// (one per input pixel); additive Blend One One.
// =============================================================================
struct WormholeDepositVaryings
{
    float4 positionCS : SV_POSITION;
    float4 color      : TEXCOORD0;
};

WormholeDepositVaryings vert_deposit(uint vertexIndex : SV_VertexID)
{
    WormholeDepositVaryings o;

    // Source texel grid = inputTex dimensions (WGSL textureDimensions(inputTex,0)).
    uint tw, th;
    inputTex.GetDimensions(tw, th);
    int w = (int)tw;
    int h = (int)th;

    // Cull vertices beyond w*h (WGSL: clip (2,2,0,1) → fully clipped).
    if ((int)vertexIndex >= w * h)
    {
        o.positionCS = float4(2.0, 2.0, 0.0, 1.0);
        o.color = float4(0.0, 0.0, 0.0, 0.0);
        return o;
    }

    int srcX = (int)vertexIndex % w;
    int srcY = (int)vertexIndex / w;

    // Vertex-stage integer texel fetch (point, no filter).
    float4 src = inputTex.Load(int3(srcX, srcY, 0));
    float lum = wormhole_oklabL(src.rgb);

    // JS: deg = valuesArr[idx] * TAU * kink + radians(rotation)
    float angle = lum * TAU * kink + radians(rotation);

    // JS: stride = 1024 * inputStride
    float pixelStride = 1024.0 * stride;

    // JS: xo = (cos(deg) + 1) * stride, yo = (sin(deg) + 1) * stride
    float ox = (cos(angle) + 1.0) * pixelStride;
    float oy = (sin(angle) + 1.0) * pixelStride;

    int destX = (int)floor((float)srcX + ox);
    int destY = (int)floor((float)srcY + oy);

    // Branchless wrap modes (reference reproduced verbatim; HLSL `%` truncates
    // toward zero like WGSL i32 `%`, and the re-add fixes negatives).
    if (wrap == 0)
    {
        // Mirror
        int mx = ((destX % (w * 2)) + w * 2) % (w * 2);
        int my = ((destY % (h * 2)) + h * 2) % (h * 2);
        destX = w - 1 - abs(mx - w + 1);
        destY = h - 1 - abs(my - h + 1);
    }
    else if (wrap == 2)
    {
        // Clamp
        destX = clamp(destX, 0, w - 1);
        destY = clamp(destY, 0, h - 1);
    }
    else
    {
        // Repeat (default)
        destX = ((destX % w) + w) % w;
        destY = ((destY % h) + h) % h;
    }

    // Convert to clip space (WGSL mapping: top-left, Y flipped vs WebGL2).
    float clipX = ((float)destX + 0.5) / (float)w * 2.0 - 1.0;
    float clipY = 1.0 - ((float)destY + 0.5) / (float)h * 2.0;

    o.positionCS = float4(clipX, clipY, 0.0, 1.0);

    // JS: out[dest + k] += src[base + k] * lum * lum (RGB only; a=0)
    o.color = float4(src.rgb * lum * lum, 0.0);
    return o;
}

float4 frag_deposit(WormholeDepositVaryings i) : SV_Target
{
    return i.color;
}

// =============================================================================
// PASS: blend — mean-normalize accumulation, sqrt, blend with original
// (frag_blend). Fullscreen.
// =============================================================================
float4 frag_blend(NMVaryings i) : SV_Target
{
    float alphaU = alpha;

    // WGSL: uv = position.xy / resolution; src/accum sampled at uv (linear,
    // clamp-to-edge). NM_FragCoord(i) == position.xy (top-left, +0.5 centered).
    float2 uv = NM_FragCoord(i) / resolution;

    float4 src = inputTex.SampleLevel(sampler_inputTex, uv, 0.0);
    float4 accum = accumTex.SampleLevel(sampler_accumTex, uv, 0.0);

    // Estimate mean of accum buffer from a 32x32 grid (1024 samples).
    float sum = 0.0;
    float count = 0.0;
    for (int gy = 0; gy < 32; gy = gy + 1)
    {
        for (int gx = 0; gx < 32; gx = gx + 1)
        {
            float2 sampleUV = (float2((float)gx, (float)gy) + float2(0.5, 0.5)) / 32.0;
            float4 s = accumTex.SampleLevel(sampler_accumTex, sampleUV, 0.0);
            float v = (s.r + s.g + s.b) / 3.0;
            sum = sum + v;
            count = count + 1.0;
        }
    }
    float mean = sum / count;

    // Normalize: scale so mean maps to ~0.25 (after sqrt → ~0.5).
    float3 normalized;
    if (mean > 0.0)
    {
        normalized = clamp(accum.rgb / (mean * 4.0), float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
    }
    else
    {
        normalized = accum.rgb;
    }

    float3 sqrtVal = sqrt(normalized);

    return float4(lerp(src.rgb, sqrtVal, alphaU), src.a);
}

#endif // NM_EFFECT_WORMHOLE_INCLUDED
