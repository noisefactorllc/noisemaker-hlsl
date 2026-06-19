#ifndef NM_EDGE_INCLUDED
#define NM_EDGE_INCLUDED

// =============================================================================
// Edge.hlsl — filter/edge, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/edge/wgsl/edge.wgsl
//
// Edge detection with multiple kernels, sizes, and blend modes.
//
// WGSL summary:
//   uv = pos.xy / textureDimensions(inputTex)   (top-left, +0.5 centered)
//   convolve neighbor samples; scale by amount/50; clamp; threshold; invert;
//   blend edgeColor with origColor; mix by mixAmt/100.
//
// PORTING-GUIDE notes:
//  * uv divides by inputTex dimensions, NOT fullResolution. Mirrored exactly.
//  * WGSL uniforms are f32 in the struct; compared as floats (> 0.5 for bools).
//    We declare ints for kernel/size/blend/invert/channel where definition.js
//    says type:"int", but WGSL comparisons (u.invert > 0.5, u.channel > 0.5)
//    mean we test `> 0` from int uniforms — equivalent because values are 0/1.
//  * select(false_val, true_val, cond) in WGSL = cond ? true_val : false_val
//    in HLSL — reversed operand order. Translated literally below.
//  * nm_mod not fmod (though this effect has no float mod).
//  * No PRNG in this effect.
//  * Radius: i32(u.size) + 1, with size choices {kernel5x5:1, kernel7x7:2} so
//    radius is 2 (5x5) or 3 (7x7). Loop bounds are -3..3 with continue guard.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// Per-effect named uniforms (definition.js globals[*].uniform)
// WGSL declares ALL of these as f32 in the Uniforms struct, and the runtime
// UniformBinder binds every numeric per-effect uniform via SetFloat. Declaring
// them as `int` here would make the shader reinterpret the float bit-pattern as
// an integer (e.g. 1.0 -> 0x3F800000 -> 1065353216), producing garbage
// kernel/size/blend indices. Declare as float (matching WGSL) and truncate to
// int in the body via i32(...) exactly as the WGSL does.
// NOTE: declared `kernel_u`, NOT `kernel`. `kernel` is a RESERVED KEYWORD in Metal
// (the compute-function qualifier); Unity's HLSL->Metal compiler does not mangle it,
// so a uniform named `kernel` produces an invalid `FGlobals.kernel` and the whole
// shader fails to compile (-> error shader -> pass draws nothing). The runtime binds
// the reference uniform `kernel` to this safe name via UniformBinder.SafeName().
float kernel_u;     // 0=fine (cross Laplacian), 1=bold (all neighbors)  [ref uniform "kernel"]
float size;         // 1=kernel5x5 (radius 2), 2=kernel7x7 (radius 3)
float blend;        // 0=add,1=darken,2=difference,3=dodge,4=lighten,5=multiply,6=normal,7=overlay,8=screen
float invert;       // 0=off, 1=on
float channel;      // 0=color, 1=luminance
float threshold;    // 0..100
float amount;       // 0..500
float mixAmt;       // 0..100 (uniform name "mixAmt", param key "mix")

// WGSL: const LUMA = vec3<f32>(0.2126, 0.7152, 0.0722);
static const float3 LUMA = float3(0.2126, 0.7152, 0.0722);

// -----------------------------------------------------------------------------
// getWeight — verbatim from WGSL.
// fine (kernelType==0): cardinal neighbors (dx==0 || dy==0) -> -1, else 0.
// bold (kernelType!=0): all neighbors -> -1.
// Center (dx==0 && dy==0) -> 0 always (handled by caller continue, but matches
// the explicit guard in WGSL).
// -----------------------------------------------------------------------------
float nm_edge_getWeight(int dx, int dy, int kernelType)
{
    if (dx == 0 && dy == 0) { return 0.0; }

    if (kernelType == 0) {
        // fine: cardinal neighbors only (cross Laplacian)
        if (dx == 0 || dy == 0) { return -1.0; }
        return 0.0;
    } else {
        // bold: all neighbors equally
        return -1.0;
    }
}

// -----------------------------------------------------------------------------
// applyBlend — verbatim from WGSL.
// WGSL select(b,a,cond) = cond ? a : b (true->second arg, false->first arg).
// Translated to HLSL ternary preserving operand semantics.
// -----------------------------------------------------------------------------
float4 nm_edge_applyBlend(float4 edge, float4 orig, int mode)
{
    if (mode == 0) { return min(orig + edge, (float4)1.0); }                                     // add
    if (mode == 1) { return min(orig, edge); }                                                    // darken
    if (mode == 2) { return abs(orig - edge); }                                                   // difference
    if (mode == 3) { return min(orig / max(1.0 - edge, (float4)0.001), (float4)1.0); }           // dodge
    if (mode == 4) { return max(orig, edge); }                                                    // lighten
    if (mode == 5) { return orig * edge; }                                                        // multiply
    if (mode == 7) {                                                                               // overlay
        // WGSL: select(1.0 - 2.0*(1.0-orig.r)*(1.0-edge.r), 2.0*orig.r*edge.r, orig.r < 0.5)
        // select(false_val, true_val, cond) -> cond ? true_val : false_val
        float r = (orig.r < 0.5) ? (2.0 * orig.r * edge.r) : (1.0 - 2.0 * (1.0 - orig.r) * (1.0 - edge.r));
        float g = (orig.g < 0.5) ? (2.0 * orig.g * edge.g) : (1.0 - 2.0 * (1.0 - orig.g) * (1.0 - edge.g));
        float b = (orig.b < 0.5) ? (2.0 * orig.b * edge.b) : (1.0 - 2.0 * (1.0 - orig.b) * (1.0 - edge.b));
        return float4(r, g, b, orig.a);
    }
    if (mode == 8) { return 1.0 - (1.0 - orig) * (1.0 - edge); }                                // screen
    return edge;                                                                                   // normal (6)
}

// -----------------------------------------------------------------------------
// nm_edge_frag — full per-pixel evaluation, called from the .shader pass.
// Takes the input texture + sampler so it can be shared with the SG wrapper.
// -----------------------------------------------------------------------------
float4 nm_edge_frag(
    Texture2D    inputTex,
    SamplerState sampler_inputTex,
    float2       fragCoord)   // NM_FragCoord(i), top-left, +0.5 centered
{
    uint tw, th;
    inputTex.GetDimensions(tw, th);
    float2 texSize   = float2(tw, th);
    float2 uv        = fragCoord / texSize;
    float2 texelSize = 1.0 / texSize;

    float4 origColor = inputTex.Sample(sampler_inputTex, uv);

    int kernelType = (int)kernel_u;      // WGSL: i32(u.kernel)
    int radius     = (int)size + 1;      // WGSL: i32(u.size)+1; default size=1 -> radius=2
    int blendMode  = (int)blend;         // WGSL: i32(u.blend)
    bool doInvert  = (invert > 0.5);     // WGSL: u.invert > 0.5
    bool useLuma   = (channel > 0.5);    // WGSL: u.channel > 0.5

    // Convolution
    float3 conv         = float3(0.0, 0.0, 0.0);
    float  centerWeight = 0.0;

    [loop]
    for (int dy = -3; dy <= 3; dy = dy + 1) {
        [loop]
        for (int dx = -3; dx <= 3; dx = dx + 1) {
            if (abs(dx) > radius || abs(dy) > radius) { continue; }
            if (dx == 0 && dy == 0) { continue; }

            float w = nm_edge_getWeight(dx, dy, kernelType);
            if (w == 0.0) { continue; }

            float2 offset = float2((float)dx, (float)dy) * texelSize;
            float3 s = inputTex.Sample(sampler_inputTex, uv + offset).rgb;

            if (useLuma) {
                conv = conv + float3(dot(s, LUMA), dot(s, LUMA), dot(s, LUMA)) * w;
            } else {
                conv = conv + s * w;
            }

            centerWeight = centerWeight - w;
        }
    }

    // Center sample
    float3 centerSample = origColor.rgb;
    if (useLuma) {
        centerSample = float3(dot(centerSample, LUMA), dot(centerSample, LUMA), dot(centerSample, LUMA));
    }
    conv = conv + centerSample * centerWeight;

    // Amount
    conv = conv * (amount / 50.0);
    conv = clamp(conv, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));

    // Threshold (before invert so it measures actual edge strength)
    if (threshold > 0.0) {
        float thresh = threshold / 100.0;
        float edgeVal;
        if (useLuma) {
            edgeVal = conv.r;
        } else {
            edgeVal = dot(conv, LUMA);
        }
        float mask = smoothstep(thresh - 0.01, thresh + 0.01, edgeVal);
        conv = conv * mask;
    }

    // Invert
    if (doInvert) {
        conv = 1.0 - conv;
    }

    // Blend
    float4 edgeColor = float4(conv, origColor.a);
    float4 blended   = nm_edge_applyBlend(edgeColor, origColor, blendMode);

    // Mix
    float m = mixAmt / 100.0;
    return float4(lerp(origColor.rgb, blended.rgb, m), origColor.a);
}

#endif // NM_EDGE_INCLUDED
