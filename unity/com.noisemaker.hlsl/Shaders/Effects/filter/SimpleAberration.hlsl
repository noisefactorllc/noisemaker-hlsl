#ifndef NM_SIMPLEABERRATION_INCLUDED
#define NM_SIMPLEABERRATION_INCLUDED

// =============================================================================
// SimpleAberration.hlsl — filter/simpleAberration, ported PIXEL-IDENTICALLY
// from the canonical WGSL:
//   shaders/effects/filter/simpleAberration/wgsl/chromaticAberration.wgsl
//
// Chromatic aberration: sample R at (uv.x + displacement, uv.y),
//                        G at uv,
//                        B at (uv.x - displacement, uv.y),
// all clamped to [0,1] on X. Alpha from the green sample.
//
// MATCH THE GLSL (the WebGL2 golden), NOT the WGSL — they DIVERGE here. The
// GLSL (simpleAberration/glsl/chromaticAberration.glsl) main():
//   globalUV     = (gl_FragCoord.xy + tileOffset) / fullResolution;
//   bounded      = clamp(displacement, -256/fullResolution.x, 256/fullResolution.x);
//   redLocalUV   = (globalUV + vec2(bounded,0)) * fullResolution - tileOffset) / texSize;
//   redLocalUV.y = 1.0 - redLocalUV.y;            // <-- explicit per-channel Y FLIP
//   red          = texture(inputTex, redLocalUV);
//   green        = same with no x offset; blue = globalUV - vec2(bounded,0).
//   return vec4(red.r, green.g, blue.b, green.a);
// The WGSL omits BOTH the Y flip and the displacement bound, so following it
// produced a vertically-MIRRORED output (the reference's own chromaticAberration
// GLSL does NOT flip — the two diverge, and the golden for THIS effect flips).
//
// PORTING-GUIDE notes:
//  * texSize = textureDimensions(inputTex); fullResolution/tileOffset = engine
//    globals (NMFullscreen). For the untiled square case texSize==fullResolution
//    and tileOffset==0, so the localUV transform reduces to globalUV with Y flip.
//  * No helpers from NMCore are needed (no pcg/prng/random/nm_mod).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// Per-effect uniform (definition.js globals.displacement.uniform = "displacement")
float displacement;

// -----------------------------------------------------------------------------
// nm_simpleAberration — core per-pixel chromatic aberration, ported from the
// GLSL golden. globalPixel = NM_GlobalCoord(i) (= fragCoord + tileOffset).
// -----------------------------------------------------------------------------
float4 nm_simpleAberration(
    Texture2D    inputTex,
    SamplerState sampler_inputTex,
    float2       globalPixel,
    float2       texSize)
{
    float2 globalUV = globalPixel / fullResolution;

    // GLSL: bounded = clamp(displacement, -256/fullResolution.x, 256/fullResolution.x)
    float maxDisp = 256.0 / fullResolution.x;
    float bd      = clamp(displacement, -maxDisp, maxDisp);

    // Red: +x displacement, Y-flipped local UV
    float2 redL = ((globalUV + float2(bd, 0.0)) * fullResolution - tileOffset) / texSize;
    redL.y = 1.0 - redL.y;
    float4 red = inputTex.Sample(sampler_inputTex, redL);

    // Green: no x offset, Y-flipped
    float2 greenL = (globalUV * fullResolution - tileOffset) / texSize;
    greenL.y = 1.0 - greenL.y;
    float4 green = inputTex.Sample(sampler_inputTex, greenL);

    // Blue: -x displacement, Y-flipped
    float2 blueL = ((globalUV - float2(bd, 0.0)) * fullResolution - tileOffset) / texSize;
    blueL.y = 1.0 - blueL.y;
    float4 blue = inputTex.Sample(sampler_inputTex, blueL);

    // GLSL: fragColor = vec4(red.r, green.g, blue.b, green.a);
    return float4(red.r, green.g, blue.b, green.a);
}

#endif // NM_SIMPLEABERRATION_INCLUDED
