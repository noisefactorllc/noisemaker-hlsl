#ifndef NM_COLORSPACE_INCLUDED
#define NM_COLORSPACE_INCLUDED

// =============================================================================
// Colorspace.hlsl — filter/colorspace, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/colorspace/wgsl/colorspace.wgsl
//
// Reinterprets input RGB channels as HSV, OKLab, or OKLCH values and converts to RGB.
//
// Modes (globals.mode):
//   0 = HSV   — treat rgb as (hue, sat, val) → rgb
//   1 = OKLab — remap rgb to OKLab coords, linear_srgb_from_oklab, linearToSrgb
//   2 = OKLCH — treat rgb as (L, C, H) → Lab → linear_srgb_from_oklab, linearToSrgb
//
// PORTING-GUIDE notes:
//  * Single render pass (definition.js passes length == 1, program "colorspace").
//  * mode: definition.js globals.mode is type "int" with choices {hsv:0,oklab:1,oklch:2}.
//    Declared as `int` uniform; branch with [branch].
//  * uv = fragCoord / textureDimensions(inputTex) — WGSL canonical, NOT fullResolution.
//    NM_FragCoord(i) / inputTex dimensions, exactly as WGSL line:
//      let texSize = vec2<f32>(textureDimensions(inputTex));
//      let uv = pos.xy / texSize;
//  * floorMod, hsv2rgb, fwdA, fwdB, linear_srgb_from_oklab, linearToSrgb are
//    ALL this effect's own helpers — ported VERBATIM inline (PORTING-GUIDE rule 2).
//  * WGSL matrix constants fwdA/fwdB: mat3x3 is column-major in WGSL (vec3 args =
//    columns). HLSL float3x3 rows are the first index. Transpose accordingly so
//    multiplication `fwdA * c` (WGSL) becomes `mul(fwdA_hlsl, c)` with transposed
//    initializer, OR use mul(c, fwdA_transposed). We declare them column-major via
//    explicit float3x3 with transposed layout and use mul(mat, vec) matching WGSL.
//    WGSL fwdA columns: col0=(1,1,1), col1=(0.3963377774,-0.1055613458,-0.0894841775),
//    col2=(0.2158037573,-0.0638541728,-1.2914855480).
//    HLSL float3x3 row-major: row0 = WGSL col0, row1 = WGSL col1, row2 = WGSL col2
//    gives transposed matrix; mul(c, fwdA_t) == fwdA * c in WGSL.
//    We use mul(mat, vec) with the mat stored so it represents the same linear map:
//    declare fwdA_m with rows = WGSL columns, then mul(fwdA_m, c) = dot each row with c.
//    WGSL: lms = fwdA * c means lms[i] = dot(fwdA_row_i_in_wgsl, c). In WGSL mat3x3,
//    fwdA[col][row]. HLSL mul(M, v) = M row dot v. So declare HLSL rows = WGSL rows
//    (accessed as fwdA[row][col]). WGSL row 0 = (fwdA[0][0],fwdA[1][0],fwdA[2][0])
//    = (1.0, 0.3963377774, 0.2158037573); row 1 = (1.0, -0.1055613458, -0.0638541728);
//    row 2 = (1.0, -0.0894841775, -1.2914855480).
//    Similarly for fwdB. See verbatim values below.
//  * linearToSrgb: for loop over 3 components — ported verbatim (loop unrolled).
//  * TAU = 6.28318530718 — verbatim constant.
//  * No PRNG/atan2/select hazards (cos/sin are straightforward).
//  * Linear, clamp-to-edge, non-sRGB sampler (H7).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniform (definition.js globals[*].uniform) ------------
int mode;   // globals.mode.uniform "mode", default 0 (hsv)

// ---- Effect-local constant --------------------------------------------------
// WGSL: const TAU: f32 = 6.28318530718;
static const float TAU = 6.28318530718;

// -----------------------------------------------------------------------------
// floorMod — ported VERBATIM from colorspace.wgsl.
// WGSL:
//   fn floorMod(x: f32, y: f32) -> f32 {
//       return x - y * floor(x / y);
//   }
// Note: equivalent to nm_mod but copied verbatim as this effect's own helper.
// -----------------------------------------------------------------------------
float floorMod(float x, float y)
{
    return x - y * floor(x / y);
}

// -----------------------------------------------------------------------------
// hsv2rgb — ported VERBATIM from colorspace.wgsl. Per-effect copy.
// WGSL:
//   fn hsv2rgb(hsv: vec3<f32>) -> vec3<f32> {
//       let h = fract(hsv.x); let s = hsv.y; let v = hsv.z;
//       let c = v * s;
//       let x = c * (1.0 - abs(floorMod(h * 6.0, 2.0) - 1.0));
//       let m = v - c;
//       var rgb: vec3<f32>;
//       if (h < 1.0/6.0) { rgb = vec3<f32>(c, x, 0.0); }
//       else if (h < 2.0/6.0) { rgb = vec3<f32>(x, c, 0.0); }
//       else if (h < 3.0/6.0) { rgb = vec3<f32>(0.0, c, x); }
//       else if (h < 4.0/6.0) { rgb = vec3<f32>(0.0, x, c); }
//       else if (h < 5.0/6.0) { rgb = vec3<f32>(x, 0.0, c); }
//       else { rgb = vec3<f32>(c, 0.0, x); }
//       return rgb + m;
//   }
// -----------------------------------------------------------------------------
float3 hsv2rgb(float3 hsv)
{
    float h = frac(hsv.x);
    float s = hsv.y;
    float v = hsv.z;
    float c = v * s;
    float x = c * (1.0 - abs(floorMod(h * 6.0, 2.0) - 1.0));
    float m = v - c;
    float3 rgb;
    if      (h < 1.0/6.0) { rgb = float3(c, x, 0.0); }
    else if (h < 2.0/6.0) { rgb = float3(x, c, 0.0); }
    else if (h < 3.0/6.0) { rgb = float3(0.0, c, x); }
    else if (h < 4.0/6.0) { rgb = float3(0.0, x, c); }
    else if (h < 5.0/6.0) { rgb = float3(x, 0.0, c); }
    else                   { rgb = float3(c, 0.0, x); }
    return rgb + m;
}

// -----------------------------------------------------------------------------
// OKLab matrix constants — ported VERBATIM from colorspace.wgsl.
//
// WGSL fwdA (column-major, columns = vec3 args):
//   col0 = (1.0,             1.0,            1.0           )
//   col1 = (0.3963377774,   -0.1055613458,  -0.0894841775  )
//   col2 = (0.2158037573,   -0.0638541728,  -1.2914855480  )
// WGSL: lms = fwdA * c  →  lms[row] = sum over col of fwdA[col][row] * c[col]
//   lms.x = 1.0*c.x + 0.3963377774*c.y + 0.2158037573*c.z
//   lms.y = 1.0*c.x - 0.1055613458*c.y - 0.0638541728*c.z
//   lms.z = 1.0*c.x - 0.0894841775*c.y - 1.2914855480*c.z
// HLSL float3x3 mul(M, v): M[row] dotted with v. So declare:
//   row0 = (1.0,  0.3963377774,  0.2158037573)
//   row1 = (1.0, -0.1055613458, -0.0638541728)
//   row2 = (1.0, -0.0894841775, -1.2914855480)
//
// WGSL fwdB (column-major):
//   col0 = ( 4.0767245293, -1.2681437731, -0.0041119885)
//   col1 = (-3.3072168827,  2.6093323231, -0.7034763098)
//   col2 = ( 0.2307590544, -0.3411344290,  1.7068625689)
// WGSL: rgb = fwdB * lms3
//   rgb.x =  4.0767245293*l3 - 3.3072168827*m3 + 0.2307590544*s3
//   rgb.y = -1.2681437731*l3 + 2.6093323231*m3 - 0.3411344290*s3
//   rgb.z = -0.0041119885*l3 - 0.7034763098*m3 + 1.7068625689*s3
// HLSL rows:
//   row0 = ( 4.0767245293, -3.3072168827,  0.2307590544)
//   row1 = (-1.2681437731,  2.6093323231, -0.3411344290)
//   row2 = (-0.0041119885, -0.7034763098,  1.7068625689)
// -----------------------------------------------------------------------------
static const float3x3 fwdA_m = float3x3(
     1.0,           0.3963377774,  0.2158037573,
     1.0,          -0.1055613458, -0.0638541728,
     1.0,          -0.0894841775, -1.2914855480
);

static const float3x3 fwdB_m = float3x3(
     4.0767245293, -3.3072168827,  0.2307590544,
    -1.2681437731,  2.6093323231, -0.3411344290,
    -0.0041119885, -0.7034763098,  1.7068625689
);

// -----------------------------------------------------------------------------
// linear_srgb_from_oklab — ported VERBATIM from colorspace.wgsl.
// WGSL:
//   fn linear_srgb_from_oklab(c: vec3<f32>) -> vec3<f32> {
//       let lms = fwdA * c;
//       return fwdB * (lms * lms * lms);
//   }
// -----------------------------------------------------------------------------
float3 linear_srgb_from_oklab(float3 c)
{
    float3 lms = mul(fwdA_m, c);
    return mul(fwdB_m, lms * lms * lms);
}

// -----------------------------------------------------------------------------
// linearToSrgb — ported VERBATIM from colorspace.wgsl.
// WGSL:
//   fn linearToSrgb(linear: vec3<f32>) -> vec3<f32> {
//       var srgb: vec3<f32>;
//       for (var i: i32 = 0; i < 3; i = i + 1) {
//           if (linear[i] <= 0.0031308) { srgb[i] = linear[i] * 12.92; }
//           else { srgb[i] = 1.055 * pow(linear[i], 1.0 / 2.4) - 0.055; }
//       }
//       return srgb;
//   }
// Loop unrolled (i = 0, 1, 2) to avoid HLSL indexing complications.
// -----------------------------------------------------------------------------
float3 linearToSrgb(float3 lin)
{
    float3 srgb;
    // i = 0
    if (lin[0] <= 0.0031308) { srgb[0] = lin[0] * 12.92; }
    else                      { srgb[0] = 1.055 * pow(lin[0], 1.0 / 2.4) - 0.055; }
    // i = 1
    if (lin[1] <= 0.0031308) { srgb[1] = lin[1] * 12.92; }
    else                      { srgb[1] = 1.055 * pow(lin[1], 1.0 / 2.4) - 0.055; }
    // i = 2
    if (lin[2] <= 0.0031308) { srgb[2] = lin[2] * 12.92; }
    else                      { srgb[2] = 1.055 * pow(lin[2], 1.0 / 2.4) - 0.055; }
    return srgb;
}

// -----------------------------------------------------------------------------
// nm_colorspace — core per-pixel evaluation. Ported VERBATIM from colorspace.wgsl main().
// WGSL:
//   var color = textureSample(inputTex, inputSampler, uv);
//   if (uniforms.mode == 0) { color = vec4<f32>(hsv2rgb(color.rgb), color.a); }
//   else if (uniforms.mode == 1) {
//       var lab = color.rgb;
//       lab.g = lab.g * -0.509 + 0.276;
//       lab.b = lab.b * -0.509 + 0.198;
//       var rgb = linear_srgb_from_oklab(lab);
//       rgb = linearToSrgb(rgb);
//       color = vec4<f32>(rgb, color.a);
//   } else {
//       let L = color.r; let C = color.g * 0.4; let H = color.b * TAU;
//       let a = C * cos(H); let b = C * sin(H);
//       var rgb = linear_srgb_from_oklab(vec3<f32>(L, a, b));
//       rgb = linearToSrgb(rgb);
//       color = vec4<f32>(rgb, color.a);
//   }
//   return color;
// -----------------------------------------------------------------------------
float4 nm_colorspace(float4 color)
{
    [branch]
    if (mode == 0)
    {
        // HSV
        color = float4(hsv2rgb(color.rgb), color.a);
    }
    else if (mode == 1)
    {
        // OKLab
        float3 lab = color.rgb;
        lab.g = lab.g * -0.509 + 0.276;
        lab.b = lab.b * -0.509 + 0.198;
        float3 rgb = linear_srgb_from_oklab(lab);
        rgb = linearToSrgb(rgb);
        color = float4(rgb, color.a);
    }
    else
    {
        // OKLCH
        float L = color.r;
        float C = color.g * 0.4;
        float H = color.b * TAU;
        float a = C * cos(H);
        float b = C * sin(H);
        float3 rgb = linear_srgb_from_oklab(float3(L, a, b));
        rgb = linearToSrgb(rgb);
        color = float4(rgb, color.a);
    }
    return color;
}

#endif // NM_COLORSPACE_INCLUDED
