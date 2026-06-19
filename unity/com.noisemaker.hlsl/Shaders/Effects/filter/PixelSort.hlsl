#ifndef NM_EFFECT_PIXELSORT_INCLUDED
#define NM_EFFECT_PIXELSORT_INCLUDED

// =============================================================================
// PixelSort.hlsl — filter/pixelSort (func: "pixelSort")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL sources:
//   shaders/effects/filter/pixelSort/wgsl/{prepare,luminance,findBrightest,
//                                          computeRank,gatherSorted,finalize}.wgsl
//
// Multi-pass GPGPU pipeline (6 passes). Textures used as data buffers:
//   1. prepare      — rotate input by angle, optional invert (darkest), wrap.
//   2. luminance     — per-pixel oklab L; store (L, normalized x, 0, 1).
//   3. findBrightest — brightest x per row; store (norm x, maxL, 0, 1).
//   4. computeRank   — sparse 32-sample approximate rank per pixel.
//   5. gatherSorted  — sparse 64-sample gather aligned to brightest pixel.
//   6. finalize      — inverse rotate, max-blend with original, alpha mix.
//
// PORTING-GUIDE notes / hazards handled:
//  * prepare/finalize SAMPLE with bilinear via applyWrap-produced UV ->
//    Texture2D.Sample(SamplerState, uv). luminance/findBrightest/computeRank/
//    gatherSorted use WGSL textureLoad(coord,0) integer fetches -> Load(int3).
//  * @builtin(position).xy (top-left, +0.5) -> NM_FragCoord(i). No per-effect Y
//    flip (ported from WGSL).
//  * WGSL `wrap`/`darkest` are f32 uniforms tested `i32(wrap)` and `!= 0.0`.
//    Declared float here to reproduce that comparison exactly.
//  * applyWrap is this effect's OWN helper — copied VERBATIM inline (golden rule 2).
//  * oklab_l / srgb_to_lin are this effect's OWN luminance — copied VERBATIM.
//    Full-precision matrix literals preserved exactly. pow(abs(x),1.0/3.0) kept.
//  * WGSL `%` (gatherSorted sortedIndex) is truncating int mod; HLSL `%` truncates
//    identically. Operands are non-negative ((x - brightestX + width) >= 0,
//    width > 0) so the result matches without nm_positiveModulo.
//  * Integer division `(s * width) / NUM_SAMPLES` is integer truncation in both
//    WGSL and HLSL — `/` on ints matches.
//  * `round()` maps 1:1 (round-half-to-even in both). max/clamp/abs/floor/fract
//    -> max/clamp/abs/floor/frac map directly. `vec4<f32>(1.0)` splat -> float4(1,1,1,1).
//  * No PRNG / no PCG / no nm_mod in this effect — no bit hazards.
//  * Linear, clamp-to-edge, non-sRGB samplers (H7) — set on the SamplerStates in
//    PixelSort.shader.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

static const float PIXELSORT_PI = 3.141592653589793;

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
// Bound by the runtime via MaterialPropertyBlock under these exact names.
// `angled`/`darkest`/`wrap` are f32 uniforms in the WGSL — declared float to
// reproduce `i32(wrap)` truncation and `darkest != 0.0` / `wrap` comparisons.
float angled;   // globals.angled.uniform,  [-180,180]  default 0
float darkest;  // globals.darkest.uniform, bool->0/1   default 0
float wrap;     // globals.wrap.uniform,    0=mirror 1=repeat 2=clamp  default 0
float alpha;    // globals.alpha.uniform,   [0,1]        default 1

// ---- Pass input textures (named exactly as definition.js passes[].inputs) ----
Texture2D    inputTex;       // prepare: raw input | finalize: "sorted"
SamplerState sampler_inputTex;
Texture2D    originalTex;    // finalize: original input
SamplerState sampler_originalTex;
Texture2D    lumTex;         // findBrightest / computeRank: luminance texture
Texture2D    preparedTex;    // gatherSorted: prepared (rotated) colors
Texture2D    rankTex;        // gatherSorted: rank texture
Texture2D    brightestTex;   // gatherSorted: brightest-x texture

// -----------------------------------------------------------------------------
// applyWrap — ported VERBATIM from prepare.wgsl / finalize.wgsl. Per-effect copy.
//   var uv = coord / size;
//   mode = i32(wrap);
//   mode==0 mirror: abs((uv+1) - floor((uv+1)*0.5)*2 - 1) per component
//   mode==1 repeat: fract(uv)
//   else    clamp:  clamp(uv, 0, 1)
// -----------------------------------------------------------------------------
float2 nm_pixelSort_applyWrap(float2 coord, float2 size)
{
    float2 uv = coord / size;
    int mode = (int)wrap;
    if (mode == 0)
    {
        // Mirror
        float mx = abs((uv.x + 1.0) - floor((uv.x + 1.0) * 0.5) * 2.0 - 1.0);
        float my = abs((uv.y + 1.0) - floor((uv.y + 1.0) * 0.5) * 2.0 - 1.0);
        return float2(mx, my);
    }
    else if (mode == 1)
    {
        return frac(uv);  // repeat
    }
    return clamp(uv, float2(0.0, 0.0), float2(1.0, 1.0));  // clamp
}

// -----------------------------------------------------------------------------
// srgb_to_lin — ported VERBATIM from luminance.wgsl. Per-effect copy.
// -----------------------------------------------------------------------------
float nm_pixelSort_srgb_to_lin(float value)
{
    if (value <= 0.04045)
    {
        return value / 12.92;
    }
    return pow((value + 0.055) / 1.055, 2.4);
}

// -----------------------------------------------------------------------------
// oklab_l — ported VERBATIM from luminance.wgsl. Per-effect copy.
// Full-precision matrix literals preserved exactly as in the WGSL.
// -----------------------------------------------------------------------------
float nm_pixelSort_oklab_l(float3 rgb)
{
    float r = nm_pixelSort_srgb_to_lin(clamp(rgb.r, 0.0, 1.0));
    float g = nm_pixelSort_srgb_to_lin(clamp(rgb.g, 0.0, 1.0));
    float b = nm_pixelSort_srgb_to_lin(clamp(rgb.b, 0.0, 1.0));

    float l = 0.4121656120 * r + 0.5362752080 * g + 0.0514575653 * b;
    float m = 0.2118591070 * r + 0.6807189584 * g + 0.1074065790 * b;
    float s = 0.0883097947 * r + 0.2818474174 * g + 0.6302613616 * b;

    float l_c = pow(abs(l), 1.0 / 3.0);
    float m_c = pow(abs(m), 1.0 / 3.0);
    float s_c = pow(abs(s), 1.0 / 3.0);

    return 0.2104542553 * l_c + 0.7936177850 * m_c - 0.0040720468 * s_c;
}

// =============================================================================
// Pass 1: prepare — rotate input by angle, optional invert, wrap.
//   center      = texSize * 0.5
//   pixelCoord  = uv * resolution - center
//   rad = angle * PI / 180; c = cos, s = sin
//   srcCoord.x =  c*px + s*py;  srcCoord.y = -s*px + c*py;  srcCoord += center
//   color = sample(applyWrap(srcCoord, texSize)); if darkest: 1 - color, a=1
// =============================================================================
float4 NMFrag_prepare(NMVaryings i) : SV_Target
{
    uint w, h;
    inputTex.GetDimensions(w, h);
    float2 texSize = float2((float)w, (float)h);
    float2 center = texSize * 0.5;
    float2 pixelCoord = i.uv * resolution - center;

    float angle = angled;
    // Handle animation if needed

    float rad = angle * PIXELSORT_PI / 180.0;
    float c = cos(rad);
    float s = sin(rad);

    // Rotate
    float2 srcCoord;
    srcCoord.x = c * pixelCoord.x + s * pixelCoord.y;
    srcCoord.y = -s * pixelCoord.x + c * pixelCoord.y;

    srcCoord = srcCoord + center;

    float2 wrappedUV = nm_pixelSort_applyWrap(srcCoord, texSize);
    float4 color = inputTex.Sample(sampler_inputTex, wrappedUV);

    if (darkest != 0.0)
    {
        color = float4(1.0, 1.0, 1.0, 1.0) - color;
        color.a = 1.0;
    }

    return color;
}

// =============================================================================
// Pass 2: luminance — per-pixel oklab L.
//   coord = i32(position.xy); size = textureDimensions(inputTex)
//   texel = textureLoad(inputTex, coord, 0); lum = oklab_l(texel.rgb)
//   return (lum, coord.x / (size.x - 1), 0, 1)
//   Here `inputTex` is bound to the "prepared" texture (definition.js inputs).
// =============================================================================
float4 NMFrag_luminance(NMVaryings i) : SV_Target
{
    int2 coord = (int2)NM_FragCoord(i);
    uint w, h;
    inputTex.GetDimensions(w, h);
    int2 size = int2((int)w, (int)h);

    float4 texel = inputTex.Load(int3(coord, 0));
    float lum = nm_pixelSort_oklab_l(texel.rgb);

    // Store: luminance, normalized x position, 0, 1
    return float4(lum, (float)coord.x / (float)(size.x - 1), 0.0, 1.0);
}

// =============================================================================
// Pass 3: findBrightest — approximate brightest pixel x per row.
//   GOLDEN (GLSL findBrightest.glsl): SPARSE 32-sample scan, NOT the WGSL exact
//   full-width loop. The approximate brightestX drives the per-row rotation
//   alignment in gatherSorted, so it MUST match the GLSL sampling pattern (the
//   exact-scan WGSL produces a different brightestX -> shifted streaks).
//   for s in [0,32): sampleX=(s*width)/32; lum=load(lumTex,(sampleX,y)).r;
//     track max -> brightestX. return (brightestX/(width-1), maxLum, 0, 1).
// =============================================================================
float4 NMFrag_findBrightest(NMVaryings i) : SV_Target
{
    int2 coord = (int2)NM_FragCoord(i);
    uint w, h;
    lumTex.GetDimensions(w, h);
    int2 size = int2((int)w, (int)h);
    int y = coord.y;
    int width = size.x;

    // Sparse sampling to find approximate brightest pixel (GLSL golden).
    const int NUM_SAMPLES = 32;
    float maxLum = -1.0;
    int brightestX = 0;

    for (int s = 0; s < NUM_SAMPLES; s = s + 1)
    {
        int sampleX = (s * width) / NUM_SAMPLES;
        float lum = lumTex.Load(int3(sampleX, y, 0)).r;
        if (lum > maxLum)
        {
            maxLum = lum;
            brightestX = sampleX;
        }
    }

    // Output: normalized brightest x, max luminance
    return float4((float)brightestX / (float)(width - 1), maxLum, 0.0, 1.0);
}

// =============================================================================
// Pass 4: computeRank — sparse 32-sample approximate rank.
//   myLum = load(lumTex, coord).r; NUM_SAMPLES = 32
//   for s in [0,32): sampleX = (s*width)/32; if sampleX==x continue
//     otherLum = load(lumTex,(sampleX,y)).r
//     if (otherLum > myLum || (otherLum == myLum && sampleX < x)) count++
//   estimatedRank = count / 32
//   return (estimatedRank, myLum, x / (width - 1), 1)
// =============================================================================
float4 NMFrag_computeRank(NMVaryings i) : SV_Target
{
    int2 coord = (int2)NM_FragCoord(i);
    uint w, h;
    lumTex.GetDimensions(w, h);
    int2 size = int2((int)w, (int)h);
    int x = coord.x;
    int y = coord.y;
    int width = size.x;

    float myLum = lumTex.Load(int3(coord, 0)).r;

    // Use sparse sampling - sample a fixed number of points across the row
    // This gives O(1) approximate rank instead of O(n) exact rank
    const int NUM_SAMPLES = 32;
    int brighterCount = 0;

    for (int s = 0; s < NUM_SAMPLES; s = s + 1)
    {
        // Sample evenly across the row
        int sampleX = (s * width) / NUM_SAMPLES;
        if (sampleX == x)
        {
            continue;
        }

        float otherLum = lumTex.Load(int3(sampleX, y, 0)).r;
        if (otherLum > myLum || (otherLum == myLum && sampleX < x))
        {
            brighterCount = brighterCount + 1;
        }
    }

    // Estimate rank based on samples
    float estimatedRank = (float)brighterCount / (float)NUM_SAMPLES;

    // Output: rank (normalized), luminance, original x (normalized)
    return float4(estimatedRank, myLum, (float)x / (float)(width - 1), 1.0);
}

// =============================================================================
// Pass 5: gatherSorted — sparse 64-sample gather aligned to brightest pixel.
//   brightestXNorm = load(brightestTex,(0,y)).r
//   brightestX     = i32(round(brightestXNorm * (width - 1)))
//   sortedIndex    = (x - brightestX + width) % width
//   targetRank     = sortedIndex / (width - 1)
//   NUM_SAMPLES = 64; for s: sampleX=(s*width)/64; rank=load(rankTex,(sampleX,y)).r
//     diff=abs(rank - targetRank); track min -> bestX
//   return load(preparedTex,(bestX,y))
// =============================================================================
float4 NMFrag_gatherSorted(NMVaryings i) : SV_Target
{
    int2 coord = (int2)NM_FragCoord(i);
    uint w, h;
    preparedTex.GetDimensions(w, h);
    int2 size = int2((int)w, (int)h);
    int x = coord.x;
    int y = coord.y;
    int width = size.x;

    // Get brightest x for this row
    float brightestXNorm = brightestTex.Load(int3(0, y, 0)).r;
    int brightestX = (int)round(brightestXNorm * (float)(width - 1));

    // Python algorithm:
    // sortedIndex = (x - brightestX + width) % width
    // Output position x gets the pixel whose rank == sortedIndex
    int sortedIndex = (x - brightestX + width) % width;
    float targetRank = (float)sortedIndex / (float)(width - 1);

    // Use sparse sampling to find a pixel with approximately matching rank
    // Instead of exact match, find the closest match
    const int NUM_SAMPLES = 64;
    float bestDiff = 2.0;
    int bestX = x;

    for (int s = 0; s < NUM_SAMPLES; s = s + 1)
    {
        int sampleX = (s * width) / NUM_SAMPLES;
        float4 rankData = rankTex.Load(int3(sampleX, y, 0));
        float pixelRank = rankData.r;

        float diff = abs(pixelRank - targetRank);
        if (diff < bestDiff)
        {
            bestDiff = diff;
            bestX = sampleX;
        }
    }

    // Fetch the color from the best matching pixel
    float4 result = preparedTex.Load(int3(bestX, y, 0));

    return result;
}

// =============================================================================
// Pass 6: finalize — inverse rotate, max-blend with original, alpha mix.
//   center = texSize*0.5; pixelCoord = uv*resolution - center
//   rad = angle*PI/180; c=cos, s=sin
//   srcCoord.x = c*px - s*py;  srcCoord.y = s*px + c*py;  srcCoord += center
//   originalColor = sample(originalTex, uv)
//   sortedColor   = sample(inputTex, applyWrap(srcCoord, texSize))  [inputTex="sorted"]
//   if darkest: invert rgb of both (keep a)
//   blended = max(working_source * alpha, working_sorted); clamp 0..1; a = source.a
//   if darkest: blended = 1 - blended.rgb, a = originalColor.a; else blended.a = originalColor.a
// =============================================================================
float4 NMFrag_finalize(NMVaryings i) : SV_Target
{
    uint w, h;
    inputTex.GetDimensions(w, h);   // inputTex bound to "sorted"
    float2 texSize = float2((float)w, (float)h);
    float2 center = texSize * 0.5;
    float2 pixelCoord = i.uv * resolution - center;

    float angle = angled;
    float rad = angle * PIXELSORT_PI / 180.0;
    float c = cos(rad);
    float s = sin(rad);

    // Inverse Rotate
    float2 srcCoord;
    srcCoord.x = c * pixelCoord.x - s * pixelCoord.y;
    srcCoord.y = s * pixelCoord.x + c * pixelCoord.y;

    srcCoord = srcCoord + center;

    float4 originalColor = originalTex.Sample(sampler_originalTex, i.uv);

    float2 wrappedUV = nm_pixelSort_applyWrap(srcCoord, texSize);
    float4 sortedColor = inputTex.Sample(sampler_inputTex, wrappedUV);

    float4 working_source = originalColor;
    float4 working_sorted = sortedColor;

    if (darkest != 0.0)
    {
        working_source = float4(float3(1.0, 1.0, 1.0) - working_source.rgb, working_source.a);
        working_sorted = float4(float3(1.0, 1.0, 1.0) - working_sorted.rgb, working_sorted.a);
    }

    float4 blended = max(working_source * alpha, working_sorted);
    blended = clamp(blended, float4(0.0, 0.0, 0.0, 0.0), float4(1.0, 1.0, 1.0, 1.0));
    blended.a = working_source.a;

    if (darkest != 0.0)
    {
        blended = float4(float3(1.0, 1.0, 1.0) - blended.rgb, originalColor.a);
    }
    else
    {
        blended.a = originalColor.a;
    }

    return blended;
}

#endif // NM_EFFECT_PIXELSORT_INCLUDED
