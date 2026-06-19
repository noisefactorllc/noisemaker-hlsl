#ifndef NM_EFFECT_GLITCH_INCLUDED
#define NM_EFFECT_GLITCH_INCLUDED

// =============================================================================
// Glitch.hlsl — classicNoisedeck/glitch (func: "glitch")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/classicNoisedeck/glitch/wgsl/glitch.wgsl
// (GLSL consulted only to disambiguate; see notes below.)
//
// Single-input filter. Deterministic noise fields drive scanline shears, snow
// bursts, channel offsets (chromatic aberration), and barrel/pincushion lensing.
// Single render pass (program "glitch").
//
// PORTING-GUIDE notes / hazards handled:
//  * PRNG: this effect's prng() is PLAIN (uint3)p TRUNCATION with NO sign-fold.
//    The shared NMCore nm_prng() adds a sign-fold (p>=0 ? p*2 : -p*2+1), which
//    would change drift/offset/snow samples (e.g. `floor(st*freq) - 10.0` and
//    `floor(st*freq) - 10.0` can be negative) -> NOT bit-identical. So we port
//    this effect's own prng() INLINE (reusing nm_pcg, the identical PCG-3D).
//  * periodicFunction: THIS effect uses map(SIN(p*TAU),-1,1,0,1) = (sin+1)*0.5.
//    NMCore's nm_periodicFunction is COS-based -> DIFFERENT. Ported inline (sin).
//  * `f`/`bicubic`: per-effect noise helpers, ported verbatim (bicubic builds the
//    Q/S/T matrices and the redundant finite-difference terms exactly as WGSL).
//    HLSL matrices are row-major in source; the WGSL builds column vectors. We
//    keep the same numeric mat product A = mul(mul(T,Q),S) and the same dot-form
//    `dot(mul(tv, A), uv)`; see bicubic() for the explicit column construction.
//  * `% 1.0` in WGSL float-`%` = e1 - e2*trunc(e1/e2) (sign of DIVIDEND) =
//    HLSL fmod, NOT GLSL mod / nm_mod. The dividend here can go negative, so the
//    distinction is pixel-visible. (This is WGSL `%`, not a `mod()` call -> fmod.)
//  * Coordinate: WGSL `uv = fragCoord.xy / resolution`; snow uses raw
//    `fragCoord.xy` (NOT +tileOffset). We use NM_FragCoord(i) (top-left, +0.5),
//    dividing by resolution for uv. Sampling is done in 0..1 lensedCoords space
//    EXACTLY as the WGSL textureSample(inputTex, samp, coord) — NO division by
//    input texture dimensions, NO fullResolution (the WGSL does neither). The
//    GLSL's localUV `fract((coord*fullResolution - tileOffset)/textureSize)` is a
//    tiling reconciliation that is identity when untiled; we follow the WGSL.
//  * VIGNETTE: ported from WGSL parenthesised form `color.rgb * (1.0 - pow(...))`.
//    The GLSL drops the parens (`color.rgb * 1.0 - pow(...)`) — a different result.
//    WGSL is canonical (golden rule 1).
//  * aspectLens is a bool uniform -> int, tested `> 0` (WGSL tests `aspectLens
//    > 0.5` on a float; 1/0 -> `> 0` is exact).
//  * mat * mat in HLSL: WGSL `mat4x4` multiply is column-vector convention. We
//    reproduce the identical scalar layout by writing matrices with the same
//    component order and using mul() in the WGSL evaluation order; the per-element
//    products are bit-identical because they are the same sums of the same terms.
//  * Full 32-bit float; PCG is bit-sensitive.
//  * TODO(verify): runtime must bind a bilinear, clamp-to-edge, NON-sRGB sampler
//    (H7). Confirm bicubic matrix product matches WGSL byte-for-byte on the parity
//    harness (matrix-convention sensitivity).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (reference binding: sampler@0, inputTex@1) ------
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
float glitchiness;   // globals.glitchiness.uniform   default 0    [0,100]
float aberration;    // globals.aberration.uniform    default 0    [0,100]
int   xChonk;        // globals.xChonk.uniform         default 1    [1,100]
int   yChonk;        // globals.yChonk.uniform         default 1    [1,100]
int   seed;          // globals.seed.uniform           default 1    [1,100]
int   scanlinesAmt;  // globals.scanlinesAmt.uniform   default 0    [0,100]
float snowAmt;       // globals.snowAmt.uniform        default 0    [0,100]
float vignetteAmt;   // globals.vignetteAmt.uniform    default 0    [-100,100]
float distortion;    // globals.distortion.uniform     default 0    [-100,100]
int   aspectLens;    // globals.aspectLens.uniform     default 0    (bool 0/1)

#define G_PI  3.14159265359
#define G_TAU 6.28318530718

// ---- This effect's own PRNG (plain truncation, NO sign-fold) -----------------
// WGSL: fn prng(p: vec3f) -> vec3f { return vec3f(pcg(vec3u(...))) / f32(0xffffffffu); }
// pcg is the identical PCG-3D (nm_pcg). (uint3)p is float->uint TRUNCATION.
float3 g_prng(float3 p)
{
    return float3(nm_pcg((uint3)p)) / 4294967295.0;
}

// map(value, inMin, inMax, outMin, outMax) — verbatim (no clamp).
float g_map(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

// periodicFunction(p) = map(sin(p*TAU), -1, 1, 0, 1)  (THIS effect: SIN-based).
float g_periodicFunction(float p)
{
    return g_map(sin(p * G_TAU), -1.0, 1.0, 0.0, 1.0);
}

// f(st, seed) = prng(vec3(floor(st), float(seed))).x
float g_f(float2 st, int seedv)
{
    return g_prng(float3(floor(st), (float)seedv)).x;
}

// bicubic(p, seed) — verbatim from WGSL bicubic().
float g_bicubic(float2 p, int seedv)
{
    float x = p.x;
    float y = p.y;
    float x1 = floor(x);
    float y1 = floor(y);
    float x2 = x1 + 1.0;
    float y2 = y1 + 1.0;
    float f11 = g_f(float2(x1, y1), seedv);
    float f12 = g_f(float2(x1, y2), seedv);
    float f21 = g_f(float2(x2, y1), seedv);
    float f22 = g_f(float2(x2, y2), seedv);
    float f11x = (g_f(float2(x1 + 1.0, y1), seedv) - g_f(float2(x1 - 1.0, y1), seedv)) / 2.0;
    float f12x = (g_f(float2(x1 + 1.0, y2), seedv) - g_f(float2(x1 - 1.0, y2), seedv)) / 2.0;
    float f21x = (g_f(float2(x2 + 1.0, y1), seedv) - g_f(float2(x2 - 1.0, y1), seedv)) / 2.0;
    float f22x = (g_f(float2(x2 + 1.0, y2), seedv) - g_f(float2(x2 - 1.0, y2), seedv)) / 2.0;
    float f11y = (g_f(float2(x1, y1 + 1.0), seedv) - g_f(float2(x1, y1 - 1.0), seedv)) / 2.0;
    float f12y = (g_f(float2(x1, y2 + 1.0), seedv) - g_f(float2(x1, y2 - 1.0), seedv)) / 2.0;
    float f21y = (g_f(float2(x2, y1 + 1.0), seedv) - g_f(float2(x2, y1 - 1.0), seedv)) / 2.0;
    float f22y = (g_f(float2(x2, y2 + 1.0), seedv) - g_f(float2(x2, y2 - 1.0), seedv)) / 2.0;
    float f11xy = (g_f(float2(x1 + 1.0, y1 + 1.0), seedv) - g_f(float2(x1 + 1.0, y1 - 1.0), seedv) - g_f(float2(x1 - 1.0, y1 + 1.0), seedv) + g_f(float2(x1 - 1.0, y1 - 1.0), seedv)) / 4.0;
    float f12xy = (g_f(float2(x1 + 1.0, y2 + 1.0), seedv) - g_f(float2(x1 + 1.0, y2 - 1.0), seedv) - g_f(float2(x1 - 1.0, y2 + 1.0), seedv) + g_f(float2(x1 - 1.0, y2 - 1.0), seedv)) / 4.0;
    float f21xy = (g_f(float2(x2 + 1.0, y1 + 1.0), seedv) - g_f(float2(x2 + 1.0, y1 - 1.0), seedv) - g_f(float2(x2 - 1.0, y1 + 1.0), seedv) + g_f(float2(x2 - 1.0, y1 - 1.0), seedv)) / 4.0;
    float f22xy = (g_f(float2(x2 + 1.0, y2 + 1.0), seedv) - g_f(float2(x2 + 1.0, y2 - 1.0), seedv) - g_f(float2(x2 - 1.0, y2 + 1.0), seedv) + g_f(float2(x2 - 1.0, y2 - 1.0), seedv)) / 4.0;

    // WGSL constructs Q/S/T as 4 COLUMN vectors. HLSL float4x4(...) takes ROWS,
    // so we transpose the component layout here to reproduce the same matrices,
    // then evaluate A = T * Q * S and dot(tv * A, uv) in the WGSL order.
    // WGSL column vectors:
    //   Q col0=(f11,f21,f11x,f21x) col1=(f12,f22,f12x,f22x)
    //     col2=(f11y,f21y,f11xy,f21xy) col3=(f12y,f22y,f12xy,f22xy)
    float4x4 Q = float4x4(
        f11,  f12,  f11y,  f12y,
        f21,  f22,  f21y,  f22y,
        f11x, f12x, f11xy, f12xy,
        f21x, f22x, f21xy, f22xy
    );
    //   S col0=(1,0,0,0) col1=(0,0,1,0) col2=(-3,3,-2,-1) col3=(2,-2,1,1)
    float4x4 S = float4x4(
        1.0, 0.0, -3.0,  2.0,
        0.0, 0.0,  3.0, -2.0,
        0.0, 1.0, -2.0,  1.0,
        0.0, 0.0, -1.0,  1.0
    );
    //   T col0=(1,0,-3,2) col1=(0,0,3,-2) col2=(0,1,-2,1) col3=(0,0,-1,1)
    float4x4 T = float4x4(
        1.0,  0.0, 0.0,  0.0,
        0.0,  0.0, 1.0,  0.0,
        -3.0, 3.0, -2.0, -1.0,
        2.0, -2.0, 1.0,  1.0
    );

    // WGSL `T * Q * S` (column-vector / pre-multiply) == HLSL mul(mul(T,Q),S)
    // when matrices are stored as above (transposed-on-load). Each output entry
    // is the same sum of the same products.
    float4x4 A = mul(mul(T, Q), S);

    float t = frac(p.x);
    float uu = frac(p.y);
    float4 tv = float4(1.0, t, t * t, t * t * t);
    float4 uv = float4(1.0, uu, uu * uu, uu * uu * uu);
    // WGSL `tv * A` is rowVector * matrix == HLSL mul(tv, A).
    return dot(mul(tv, A), uv);
}

// scanlines(color, st, resolution, scanlinesAmt, time, seed) — verbatim.
float4 g_scanlines(float4 color, float2 st, float2 res, float scanlinesAmtv, float timev, int seedv)
{
    float centerDistance = length(float2(0.5, 0.5) - st) * G_PI * 0.5;
    float noise = g_periodicFunction(g_bicubic(st * 4.0, seedv) - timev) * g_map(scanlinesAmtv, 0.0, 100.0, 0.0, 0.5);
    float hatch = (sin(lerp(st.y, st.y + noise, pow(centerDistance, 8.0)) * res.y * 1.5) + 1.0) * 0.5;
    float4 result = color;
    result = float4(lerp(color.rgb, color.rgb * hatch, g_map(scanlinesAmtv, 0.0, 100.0, 0.0, 0.5)), color.a);
    return result;
}

// snow(color, fragCoord, snowAmt, time) — verbatim.
float4 g_snow(float4 color, float2 fragCoord, float snowAmtv, float timev)
{
    float amt = snowAmtv / 100.0;
    float noise = g_prng(float3(fragCoord, timev * 1000.0)).x;

    float maskNoise = g_prng(float3(fragCoord + 10.0, timev * 1000.0)).x;
    float maskNoiseSparse = clamp(maskNoise - 0.93875, 0.0, 0.06125) * 16.0;

    float mask;
    if (amt < 0.5)
    {
        mask = lerp(0.0, maskNoiseSparse, amt * 2.0);
    }
    else
    {
        mask = lerp(maskNoiseSparse, maskNoise * maskNoise, g_map(amt, 0.5, 1.0, 0.0, 1.0));
        if (amt > 0.75)
        {
            mask = lerp(mask, 1.0, g_map(amt, 0.75, 1.0, 0.0, 1.0));
        }
    }

    return float4(lerp(color.rgb, float3(noise, noise, noise), mask), color.a);
}

// glitch(st, aspectRatio, time, xChonk, yChonk, glitchiness, aspectLens,
//        distortion, aberration) — verbatim from WGSL glitch().
float4 g_glitch(float2 st_in, float aspectRatioV, float timev, float xChonkV, float yChonkV,
                float glitchinessV, float aspectLensV, float distortionV, float aberrationV)
{
    float2 st = st_in;
    float2 freq = float2(1.0, 1.0);
    freq.x = freq.x * g_map(xChonkV, 1.0, 100.0, 50.0, 1.0);
    freq.y = freq.y * g_map(yChonkV, 1.0, 100.0, 50.0, 1.0);

    freq = freq * float2(g_periodicFunction(g_prng(float3(floor(st * freq), 0.0)).x - timev),
                         g_periodicFunction(g_prng(float3(floor(st * freq), 0.0)).x - timev));

    float g = g_map(glitchinessV, 0.0, 100.0, 0.0, 1.0);

    // get drift value from somewhere far away
    float xDrift = g_prng(float3(floor(st * freq) + 10.0, 0.0)).x * g;
    float yDrift = g_prng(float3(floor(st * freq) - 10.0, 0.0)).x * g;

    float sparseness = g_map(glitchinessV, 0.0, 100.0, 8.0, 2.0);

    // clamp for sparseness
    float rand = g_prng(float3(floor(st * freq), 0.0)).x;
    float xOffset = clamp((g_periodicFunction(rand + xDrift - timev) - g_periodicFunction(xDrift - timev) * sparseness) * 4.0, 0.0, 1.0);
    float yOffset = clamp((g_periodicFunction(rand + yDrift - timev) - g_periodicFunction(yDrift - timev) * sparseness) * 4.0, 0.0, 1.0);

    float refractAmt = g * 0.125;

    // WGSL `%` on floats = e1 - e2*trunc(e1/e2) (sign of DIVIDEND, like fmod) —
    // NOT GLSL mod / nm_mod (sign of divisor). Dividend can be negative here
    // (st.x near 0, sin(...)*refractAmt in [-0.125,0.125]), so the two differ:
    // fmod(-0.04,1)=-0.04 vs nm_mod(-0.04,1)=0.96. WGSL source uses `%` -> fmod.
    st.x = fmod(st.x + sin(xOffset * G_TAU) * refractAmt, 1.0);
    st.y = fmod(st.y + sin(yOffset * G_TAU) * refractAmt, 1.0);

    // aberration and lensing
    float2 diff = float2(0.5 - st.x, 0.5 - st.y);
    if (aspectLensV > 0.5)
    {
        diff = float2(0.5 * aspectRatioV, 0.5) - float2(st.x * aspectRatioV, st.y);
    }
    float centerDist = length(diff);

    float distort = 0.0;
    float zoom = 1.0;
    if (distortionV < 0.0)
    {
        distort = g_map(distortionV, -100.0, 0.0, -0.5, 0.0);
        zoom = g_map(distortionV, -100.0, 0.0, 0.01, 0.0);
    }
    else
    {
        distort = g_map(distortionV, 0.0, 100.0, 0.0, 0.5);
        zoom = g_map(distortionV, 0.0, 100.0, 0.0, -0.25);
    }

    float2 lensedCoords = frac((st - diff * zoom) - diff * centerDist * centerDist * distort);

    float aberrationOffset = g_map(aberrationV, 0.0, 100.0, 0.0, 0.05) * centerDist * G_PI * 0.5;

    float redOffset = lerp(clamp(lensedCoords.x + aberrationOffset, 0.0, 1.0), lensedCoords.x, lensedCoords.x);
    float4 red = inputTex.Sample(sampler_inputTex, float2(redOffset, lensedCoords.y));

    float4 green = inputTex.Sample(sampler_inputTex, lensedCoords);

    float blueOffset = lerp(lensedCoords.x, clamp(lensedCoords.x - aberrationOffset, 0.0, 1.0), lensedCoords.x);
    float4 blue = inputTex.Sample(sampler_inputTex, float2(blueOffset, lensedCoords.y));

    return float4(red.r, green.g, blue.b, green.a);
}

// ---- Pass: "glitch" (progName "glitch") -------------------------------------
float4 NMFrag_glitch(NMVaryings i) : SV_Target
{
    float2 res = resolution;
    float aspectRatioV = res.x / res.y;

    float2 fragCoord = NM_FragCoord(i);    // WGSL @builtin(position).xy (top-left)
    float2 uv = fragCoord / res;

    float4 color = g_glitch(uv, aspectRatioV, time, (float)xChonk, (float)yChonk,
                            glitchiness, (float)aspectLens, distortion, aberration);
    color = g_scanlines(color, uv, res, (float)scanlinesAmt, time, seed);
    color = g_snow(color, fragCoord, snowAmt, time);

    // vignette (WGSL parenthesised form)
    if (vignetteAmt < 0.0)
    {
        color = float4(
            lerp(color.rgb * (1.0 - pow(length(float2(0.5, 0.5) - uv) * 1.125, 2.0)), color.rgb, g_map(vignetteAmt, -100.0, 0.0, 0.0, 1.0)),
            max(color.a, length(float2(0.5, 0.5) - uv) * g_map(vignetteAmt, -100.0, 0.0, 1.0, 0.0))
        );
    }
    else
    {
        color = float4(
            lerp(color.rgb, 1.0 - (1.0 - color.rgb * (1.0 - pow(length(float2(0.5, 0.5) - uv) * 1.125, 2.0))), g_map(vignetteAmt, 0.0, 100.0, 0.0, 1.0)),
            max(color.a, length(float2(0.5, 0.5) - uv) * g_map(vignetteAmt, -100.0, 0.0, 1.0, 0.0))
        );
    }

    return color;
}

#endif // NM_EFFECT_GLITCH_INCLUDED
