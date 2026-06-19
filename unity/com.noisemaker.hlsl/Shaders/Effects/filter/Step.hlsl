#ifndef NM_STEP_INCLUDED
#define NM_STEP_INCLUDED

// =============================================================================
// Step.hlsl — filter/step, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/step/wgsl/step.wgsl
//
// Hard threshold at specified value, with optional anti-aliasing via smoothstep.
//
// WGSL main():
//   let texSize = vec2<f32>(textureDimensions(inputTex));
//   let uv = pos.xy / texSize;
//   var color = textureSample(inputTex, inputSampler, uv);
//   if (uniforms.antialias != 0) {
//       let fw = fwidth(color.rgb);
//       color = vec4<f32>(
//           smoothstep(threshold - fw * 0.5, threshold + fw * 0.5, color.rgb),
//           color.a );
//   } else {
//       color = vec4<f32>(step(vec3<f32>(threshold), color.rgb), color.a);
//   }
//   return color;
//
// PORTING-GUIDE notes:
//  * uv = fragCoord / INPUT TEXTURE's own dimensions (textureDimensions(inputTex)).
//    Not fullResolution. Follows WGSL literally.
//  * antialias is bool in definition.js but carried as int in WGSL (uniforms.antialias: i32).
//    Declare as int and test != 0 to match WGSL exactly.
//  * No PRNG, no per-effect math helpers beyond HLSL builtins step/smoothstep/fwidth.
//  * fwidth is available in HLSL pixel shaders (ddx/ddy-based). #pragma target 4.5.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// Per-effect uniforms (definition.js globals[*].uniform)
float threshold;  // default 0.5, range [0,1]
int   antialias;  // boolean: 1 = on, 0 = off (WGSL: uniforms.antialias != 0)

// -----------------------------------------------------------------------------
// nm_step — core per-pixel evaluation.
// color : already-sampled RGBA from inputTex
// Returns thresholded RGBA.
// -----------------------------------------------------------------------------
float4 nm_step(float4 color)
{
    // WGSL: if (uniforms.antialias != 0) { ... } else { ... }
    [branch]
    if (antialias != 0)
    {
        // WGSL: let fw = fwidth(color.rgb);
        //       color = vec4<f32>(
        //           smoothstep(threshold - fw * 0.5, threshold + fw * 0.5, color.rgb),
        //           color.a);
        float3 fw = fwidth(color.rgb);
        return float4(
            smoothstep(threshold - fw * 0.5, threshold + fw * 0.5, color.rgb),
            color.a
        );
    }
    else
    {
        // WGSL: color = vec4<f32>(step(vec3<f32>(threshold), color.rgb), color.a);
        return float4(step((float3)threshold, color.rgb), color.a);
    }
}

#endif // NM_STEP_INCLUDED
