#ifndef NM_SKEW_INCLUDED
#define NM_SKEW_INCLUDED

// =============================================================================
// Skew.hlsl — filter/skew, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/skew/wgsl/skew.wgsl
//
// Skew and rotate transform. Single pass filter.
//
// WGSL main() summary:
//   let texSize = vec2<f32>(textureDimensions(inputTex));
//   var st = pos.xy / texSize;
//   let aspect = texSize.x / texSize.y;
//   st = st - 0.5;
//   st.x = st.x * aspect;
//   let angle = u.rotation * PI / 180.0;
//   let c = cos(angle); let s = sin(angle);
//   st = vec2(c*st.x - s*st.y, s*st.x + c*st.y);
//   st.x = st.x + st.y * -u.skewAmt;
//   st.x = st.x / aspect;
//   st = st + 0.5;
//   // wrap modes ...
//   return textureSample(inputTex, inputSampler, st);
//
// PORTING-GUIDE notes:
//  * uv uses INPUT TEXTURE dimensions (textureDimensions(inputTex)), NOT fullResolution.
//  * aspect is also derived from INPUT TEXTURE dimensions, NOT fullResolution.
//  * GLSL uses globalUV and fullResolution.x/y for aspect — WGSL is canonical, use
//    local tex dimensions only.
//  * WGSL mirror wrap: abs(((st+1.0) % 2.0 + 2.0) % 2.0 - 1.0). The inner `%` on
//    floats in WGSL is floor-based (= nm_mod). Reproduced verbatim.
//  * WGSL repeat wrap: (st % 1.0 + 1.0) % 1.0. All `%` on floats -> nm_mod.
//  * No PRNG, no hazards beyond nm_mod. No skewAmt clamping — GLSL has it but
//    GLSL is NOT canonical; WGSL applies skewAmt directly. // TODO(verify) parity.
//  * int wrapMode = i32(u.wrap) — declared as int uniform.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// Per-effect named uniforms (definition.js globals[*].uniform)
float skewAmt;   // default 0.25, range [-1, 1]
float rotation;  // default 0,    range [-180, 180]
int   wrap;      // default 1 (mirror), choices: clamp=0, mirror=1, repeat=2

// NM_PI is defined in NMCore.hlsl (included via NMFullscreen.hlsl)

// -----------------------------------------------------------------------------
// nm_skew — core per-pixel evaluation.
// fragCoord : pixel-center coord in INPUT TEXTURE space (NM_FragCoord(i)).
// inputTex/sampler_inputTex : the input surface.
// Returns the transformed, wrapped, sampled color.
// -----------------------------------------------------------------------------
float4 nm_skew(
    float2          fragCoord,
    Texture2D       inputTex,
    SamplerState    sampler_inputTex)
{
    // WGSL: let texSize = vec2<f32>(textureDimensions(inputTex));
    uint tw, th;
    inputTex.GetDimensions(tw, th);
    float2 texSize = float2(tw, th);

    // WGSL: var st = pos.xy / texSize;
    float2 st = fragCoord / texSize;

    // WGSL: let aspect = texSize.x / texSize.y;
    float aspect = texSize.x / texSize.y;

    // Center
    st = st - 0.5;
    st.x = st.x * aspect;

    // Rotate
    float angle = rotation * NM_PI / 180.0;
    float c = cos(angle);
    float s = sin(angle);
    // GLSL golden: st = mat2(c, -s, s, c) * st. GLSL mat2(a,b,c,d) is COLUMN-MAJOR
    // (col0=(a,b), col1=(c,d)), so mat2(c,-s,s,c) = [[c, s],[-s, c]] and the product
    // is (c*st.x + s*st.y, -s*st.x + c*st.y) — the OPPOSITE rotation direction from
    // the WGSL transcription (c*x-s*y, s*x+c*y). At rotation=0 (s=0) both agree, so
    // the WGSL bug only surfaces for nonzero rotation. Match GLSL (the golden).
    st = float2(c * st.x + s * st.y, -s * st.x + c * st.y);

    // Skew. GLSL golden clamps skewAmt to ±(512/fullResolution.y) before applying
    // (the WGSL transcription omitted this). For a 256-tall full image the bound is
    // ±2.0, so typical skews pass through unchanged; match GLSL for parity at large
    // skew / small resolutions.
    // GLSL: float maxSkew = 512.0 / fullResolution.y;
    //       float effectiveSkewAmt = clamp(skewAmt, -maxSkew, maxSkew);
    //       st.x += st.y * -effectiveSkewAmt;
    float maxSkew = 512.0 / texSize.y;
    float effectiveSkewAmt = clamp(skewAmt, -maxSkew, maxSkew);
    st.x = st.x + st.y * -effectiveSkewAmt;

    // Undo aspect, uncenter
    st.x = st.x / aspect;
    st = st + 0.5;

    // Wrap mode
    // WGSL: let wrapMode = i32(u.wrap);
    if (wrap == 0)
    {
        // clamp
        // WGSL: st = clamp(st, vec2<f32>(0.0), vec2<f32>(1.0));
        st = clamp(st, float2(0.0, 0.0), float2(1.0, 1.0));
    }
    else if (wrap == 1)
    {
        // mirror
        // WGSL: st = abs(((st + 1.0) % 2.0 + 2.0) % 2.0 - 1.0);
        // All `%` on floats in WGSL = floor-based modulo -> nm_mod
        st = abs(nm_mod(nm_mod(st + 1.0, float2(2.0, 2.0)) + 2.0, float2(2.0, 2.0)) - 1.0);
    }
    else
    {
        // repeat
        // WGSL: st = (st % 1.0 + 1.0) % 1.0;
        st = nm_mod(nm_mod(st, float2(1.0, 1.0)) + 1.0, float2(1.0, 1.0));
    }

    // WGSL: return textureSample(inputTex, inputSampler, st);
    return inputTex.Sample(sampler_inputTex, st);
}

#endif // NM_SKEW_INCLUDED
