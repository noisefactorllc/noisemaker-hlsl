#ifndef NM_CORRUPT_INCLUDED
#define NM_CORRUPT_INCLUDED

// =============================================================================
// Corrupt.hlsl — filter/corrupt, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/corrupt/wgsl/corrupt.wgsl
//
// Scanline-based data corruption: pixel sorting, horizontal byte-shifting, bit
// manipulation, channel separation, melt, and per-pixel scatter — all along
// horizontal scanlines (linear byte-stream corruption).
//
// PORTING-GUIDE notes:
//  * Single render pass (definition.js passes.length == 1, program "corrupt").
//  * Single-input FILTER: samples only inputTex (definition.js inputs.inputTex).
//  * pcg/prng come from NMCore (nm_pcg/nm_prng) — the ONLY shared primitives.
//    rowTime/lineHash/pixelSort/byteShift/bitCorrupt/meltDisplace/scatterDisplace
//    are this effect's OWN helpers, ported VERBATIM inline (golden rule 2).
//  * Coordinate parity: WGSL divides by the INPUT TEXTURE's own dimensions, NOT
//    fullResolution. resolution = textureDimensions(inputTex); resX = resolution.x;
//    uv = pos.xy / resolution. The WGSL does NOT scale by renderScale (that is a
//    GLSL-only tiling concession). WGSL is canonical, so NO renderScale here.
//  * fragCoord = pos.xy (top-left, +0.5) -> NM_FragCoord(i). tileOffset does NOT
//    enter any coordinate (WGSL omits it). H8 handled by NMFullscreen top-left UV.
//  * select / atan2: none in this effect. Ternaries copied literally.
//  * prng arg order copied literally; note scatterDisplace builds vec3 from
//    (floor(fragCoord) [vec2], scalar) — a 2+1 splice, reproduced exactly.
//  * textureSampleLevel(...,0.0) -> inputTex.SampleLevel(ss, uv, 0) (explicit mip,
//    no derivatives — needed because branches depend on per-pixel values).
//  * Float modulo: none used (only frac/floor/clamp). nm_mod not required here.
//  * Full 32-bit float (PCG is bit-sensitive). Linear, clamp-to-edge, non-sRGB
//    sampler (H7) — supplied by Corrupt.shader / the Shader Graph node.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
// Bound by the runtime via MaterialPropertyBlock under these exact names.
float intensity;    // globals.intensity.uniform    "intensity",    default 50
float bandHeight;   // globals.bandHeight.uniform   "bandHeight",   default 10
float sort;         // globals.sort.uniform         "sort",         default 50
float shift;        // globals.shift.uniform         "shift",        default 50
float channelShift; // globals.channelShift.uniform "channelShift", default 0
float melt;         // globals.melt.uniform         "melt",         default 0
float scatter;      // globals.scatter.uniform      "scatter",      default 0
float bits;         // globals.bits.uniform         "bits",         default 0
int   speed;        // globals.speed.uniform        "speed",        default 1  (int)
int   seed;         // globals.seed.uniform         "seed",         default 1  (int)

#define NM_CORRUPT_PI  3.14159265359
#define NM_CORRUPT_TAU 6.28318530718

// -----------------------------------------------------------------------------
// rowTime — WGSL: per-row staggered time. prng arg order copied literally.
// -----------------------------------------------------------------------------
float nm_corrupt_rowTime(float row, float sd, float t)
{
    float phase = nm_prng(float3(row, sd + 777.0, 0.0)).x;
    return floor((t + phase) * 8.0);
}

// -----------------------------------------------------------------------------
// lineHash — WGSL: prng(vec3(line, sd, rt)).
// -----------------------------------------------------------------------------
float3 nm_corrupt_lineHash(float lineId, float sd, float rt)
{
    return nm_prng(float3(lineId, sd, rt));
}

// -----------------------------------------------------------------------------
// pixelSort — WGSL verbatim.
// -----------------------------------------------------------------------------
float2 nm_corrupt_pixelSort(float2 uv_in, float row, float sortAmt, float rt, float sd, float resX)
{
    float2 uv = uv_in;
    float3 rh = nm_corrupt_lineHash(row, sd, rt);
    float threshold = lerp(0.8, 0.2, sortAmt);
    float regionSize = 3.0 + rh.y * 20.0;
    float region = floor(uv.x * resX / regionSize);
    float3 regionHash = nm_prng(float3(region, row, sd + rt));
    float regionPos = frac(uv.x * resX / regionSize);
    float sortShift = regionPos * regionHash.x * sortAmt * 0.15;
    if (regionHash.y > threshold) {
        uv.x = frac(uv.x + sortShift);
    }
    return uv;
}

// -----------------------------------------------------------------------------
// byteShift — WGSL verbatim.
// -----------------------------------------------------------------------------
float2 nm_corrupt_byteShift(float2 uv_in, float row, float shiftAmt, float rt, float sd, float resX)
{
    float2 uv = uv_in;
    float3 rh = nm_corrupt_lineHash(row, sd, rt);
    float chunkWidth = 8.0 + rh.x * 80.0;
    float chunk = floor(uv.x * resX / chunkWidth);
    float3 ch = nm_prng(float3(chunk, row + 200.0, sd + rt));
    float shiftPx = (ch.x - 0.5) * 2.0 * shiftAmt * resX * 0.15;
    float sparsity = lerp(0.85, 0.3, shiftAmt);
    if (ch.y > sparsity) {
        uv.x = frac(uv.x + shiftPx / resX);
    }
    return uv;
}

// -----------------------------------------------------------------------------
// bitCorrupt — WGSL verbatim. pow(2.0, bitShift) kept as pow (PORTING-GUIDE).
// -----------------------------------------------------------------------------
float3 nm_corrupt_bitCorrupt(float3 color_in, float2 uv, float row, float bitAmt, float rt, float sd, float resX)
{
    float3 color = color_in;
    float3 bh = nm_corrupt_lineHash(row + 400.0, sd, rt);
    float levels = lerp(256.0, 2.0, bitAmt * bitAmt);
    color = floor(color * levels + 0.5) / levels;
    if (bitAmt > 0.3) {
        float xorStrength = (bitAmt - 0.3) / 0.7;
        float px = floor(uv.x * resX);
        float3 xorHash = nm_prng(float3(px, row, sd + rt + 500.0));
        float3 mask = step(float3(1.0 - xorStrength * 0.5, 1.0 - xorStrength * 0.5, 1.0 - xorStrength * 0.5), xorHash);
        color = lerp(color, 1.0 - color, mask);
    }
    if (bitAmt > 0.6) {
        float shiftStr = (bitAmt - 0.6) / 0.4;
        float bitShift = floor(bh.x * 4.0) + 1.0;
        float scale = pow(2.0, bitShift);
        color = frac(color * lerp(1.0, scale, shiftStr));
    }
    return color;
}

// -----------------------------------------------------------------------------
// meltDisplace — WGSL verbatim.
// -----------------------------------------------------------------------------
float2 nm_corrupt_meltDisplace(float2 uv_in, float meltAmt, float t, float sd, float resX)
{
    float2 uv = uv_in;
    float col = floor(uv.x * resX / 3.0);
    float colPhase = nm_prng(float3(col, sd + 601.0, 0.0)).x;
    float3 dripHash = nm_prng(float3(col, sd + 600.0, floor((t + colPhase) * 8.0)));
    float gravity = (1.0 - uv.y) * (1.0 - uv.y);
    float dripAmt = dripHash.x * meltAmt * gravity * 0.4;
    float dripProb = lerp(0.9, 0.2, meltAmt);
    if (dripHash.y > dripProb) {
        float wobble = sin(uv.y * 20.0 + dripHash.z * NM_CORRUPT_TAU + t) * meltAmt * 0.02;
        uv.y = clamp(uv.y + dripAmt, 0.0, 1.0);
        uv.x = frac(uv.x + wobble);
    }
    return uv;
}

// -----------------------------------------------------------------------------
// scatterDisplace — WGSL verbatim. fragCoord = pos.xy (top-left). prng builds a
// vec3 from (floor(fragCoord) [vec2], scalar); the second call adds vec2(1000.0)
// to the floored coord BEFORE the splice — reproduced exactly.
// -----------------------------------------------------------------------------
float2 nm_corrupt_scatterDisplace(float2 uv_in, float scatterAmt, float t, float sd, float2 fragCoord)
{
    float2 uv = uv_in;
    float3 phaseHash = nm_prng(float3(floor(fragCoord), sd + 700.0));
    float pixTime = floor((t + phaseHash.x) * 8.0);
    float3 pixHash = nm_prng(float3(floor(fragCoord), pixTime + sd));
    float threshold = lerp(0.98, 0.1, scatterAmt * scatterAmt);
    if (pixHash.x > threshold) {
        float3 dirHash = nm_prng(float3(floor(fragCoord) + float2(1000.0, 1000.0), pixTime + sd));
        float dist = scatterAmt * 0.15 * (0.5 + pixHash.y * 0.5);
        uv.x = frac(uv.x + (dirHash.x - 0.5) * dist);
        uv.y = clamp(uv.y + (dirHash.y - 0.5) * dist, 0.0, 1.0);
    }
    return uv;
}

// -----------------------------------------------------------------------------
// nm_corrupt — core fragment evaluation. Takes the input Texture2D + SamplerState
// and the fragment coordinate (pos.xy, top-left, +0.5). Mirrors WGSL main().
// -----------------------------------------------------------------------------
float4 nm_corrupt(Texture2D inputTex, SamplerState ss, float2 fragCoord)
{
    float fseed = (float)seed;   // WGSL reads seed as f32 from the uniform block.
    float fspeed = (float)speed; // WGSL reads speed as f32; floor() applied below.

    uint tw, th;
    inputTex.GetDimensions(tw, th);
    float2 res = float2(tw, th);  // local (NOT macro `resolution`); input-tex size
    float resX = res.x;
    float2 uv = fragCoord / res;
    float spd = floor(fspeed);
    float t = time * NM_CORRUPT_TAU * spd;

    // Scanline grouping
    float rawRow = fragCoord.y;
    float bh = max(1.0, floor(bandHeight * 0.32));
    float row = floor(rawRow / bh);

    // Per-row staggered time
    float rt = nm_corrupt_rowTime(row, fseed, t);

    // Per-scanline corruption probability
    float3 rowHash = nm_corrupt_lineHash(row, fseed, rt);
    float prob = intensity / 100.0;
    bool isCorrupt = rowHash.x < prob;

    float2 sampleUv = uv;

    // 2D effects (not band-based)
    float meltAmt = melt / 100.0;
    if (meltAmt > 0.0) {
        sampleUv = nm_corrupt_meltDisplace(sampleUv, meltAmt, t, fseed, resX);
    }
    float scatterAmt = scatter / 100.0;
    if (scatterAmt > 0.0) {
        sampleUv = nm_corrupt_scatterDisplace(sampleUv, scatterAmt, t, fseed, fragCoord);
    }

    // Band-based corruption to UV
    if (isCorrupt) {
        float sortAmt = sort / 100.0;
        float shiftAmt = shift / 100.0;
        if (sortAmt > 0.0) {
            sampleUv = nm_corrupt_pixelSort(sampleUv, row, sortAmt, rt, fseed, resX);
        }
        if (shiftAmt > 0.0) {
            sampleUv = nm_corrupt_byteShift(sampleUv, row, shiftAmt, rt, fseed, resX);
        }
    }

    // Sample color from input. Explicit mip 0 (no derivatives) because the
    // branches below depend on per-pixel values (WGSL textureSampleLevel).
    float3 color = inputTex.SampleLevel(ss, sampleUv, 0).rgb;

    // Channel separation
    if (channelShift > 0.0 && isCorrupt) {
        float chAmt = channelShift / 100.0;
        float3 chHash = nm_corrupt_lineHash(row + 300.0, fseed, rt);
        float rShift = (chHash.x - 0.5) * chAmt * 0.08;
        float bShift = (chHash.y - 0.5) * chAmt * 0.08;
        float2 rUv = float2(frac(sampleUv.x + rShift), sampleUv.y);
        float2 bUv = float2(frac(sampleUv.x + bShift), sampleUv.y);
        color.r = inputTex.SampleLevel(ss, rUv, 0).r;
        color.b = inputTex.SampleLevel(ss, bUv, 0).b;
    }

    // Bit corruption
    if (bits > 0.0 && isCorrupt) {
        color = nm_corrupt_bitCorrupt(color, uv, row, bits / 100.0, rt, fseed, resX);
    }

    return float4(color, 1.0);
}

#endif // NM_CORRUPT_INCLUDED
