#ifndef NM_FLIPMIRROR_INCLUDED
#define NM_FLIPMIRROR_INCLUDED

// =============================================================================
// FlipMirror.hlsl — filter/flipMirror, ported PIXEL-IDENTICALLY from canonical WGSL:
//   shaders/effects/filter/flipMirror/wgsl/flipMirror.wgsl
//
// Applies horizontal/vertical flip and various mirroring modes to the input.
//
// WGSL main():
//   let texSize = vec2<f32>(textureDimensions(inputTex));
//   var uv = pos.xy / texSize;           // top-left origin, +0.5 centered
//   ... branch on uniforms.flipMode ...
//   return textureSampleLevel(inputTex, inputSampler, uv, 0.0);
//
// PORTING-GUIDE notes:
//  * Single uniform: flipMode (int). Declared as bare HLSL int.
//  * uv is fragCoord / INPUT TEXTURE's own dimensions (textureDimensions in WGSL),
//    NOT fullResolution. Follow WGSL literally.
//  * No per-effect math helpers. No PRNG. No hazards.
//  * textureSampleLevel(..., 0.0) → SampleLevel(..., 0) for mip 0.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// Per-effect uniform (definition.js globals.mode.uniform = "flipMode")
int flipMode;

// -----------------------------------------------------------------------------
// nm_flipMirror — core UV warp + sample.
// texSize: float2(width, height) of inputTex (matches WGSL textureDimensions).
// -----------------------------------------------------------------------------
float4 nm_flipMirror(Texture2D inputTex, SamplerState sampler_inputTex,
                     float2 texSize, float2 fragCoord)
{
    float2 uv = fragCoord / texSize;

    [branch]
    if (flipMode == 1) {
        // flip both
        uv.x = 1.0 - uv.x;
        uv.y = 1.0 - uv.y;
    } else if (flipMode == 2) {
        // flip horizontal
        uv.x = 1.0 - uv.x;
    } else if (flipMode == 3) {
        // flip vertical
        uv.y = 1.0 - uv.y;
    } else if (flipMode == 11) {
        // mirror left to right
        if (uv.x > 0.5) {
            uv.x = 1.0 - uv.x;
        }
    } else if (flipMode == 12) {
        // mirror right to left
        if (uv.x < 0.5) {
            uv.x = 1.0 - uv.x;
        }
    } else if (flipMode == 13) {
        // mirror up to down
        if (uv.y > 0.5) {
            uv.y = 1.0 - uv.y;
        }
    } else if (flipMode == 14) {
        // mirror down to up
        if (uv.y < 0.5) {
            uv.y = 1.0 - uv.y;
        }
    } else if (flipMode == 15) {
        // mirror left to right, up to down
        if (uv.x > 0.5) {
            uv.x = 1.0 - uv.x;
        }
        if (uv.y > 0.5) {
            uv.y = 1.0 - uv.y;
        }
    } else if (flipMode == 16) {
        // mirror left to right, down to up
        if (uv.x > 0.5) {
            uv.x = 1.0 - uv.x;
        }
        if (uv.y < 0.5) {
            uv.y = 1.0 - uv.y;
        }
    } else if (flipMode == 17) {
        // mirror right to left, up to down
        if (uv.x < 0.5) {
            uv.x = 1.0 - uv.x;
        }
        if (uv.y > 0.5) {
            uv.y = 1.0 - uv.y;
        }
    } else if (flipMode == 18) {
        // mirror right to left, down to up
        if (uv.x < 0.5) {
            uv.x = 1.0 - uv.x;
        }
        if (uv.y < 0.5) {
            uv.y = 1.0 - uv.y;
        }
    }
    // flipMode == 0 (none): uv unchanged

    // WGSL: textureSampleLevel(inputTex, inputSampler, uv, 0.0)
    return inputTex.SampleLevel(sampler_inputTex, uv, 0);
}

#endif // NM_FLIPMIRROR_INCLUDED
