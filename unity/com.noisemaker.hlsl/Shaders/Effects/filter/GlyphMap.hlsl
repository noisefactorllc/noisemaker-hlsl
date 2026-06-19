#ifndef NM_GLYPHMAP_INCLUDED
#define NM_GLYPHMAP_INCLUDED

// =============================================================================
// GlyphMap.hlsl — filter/glyphMap, ported PIXEL-IDENTICALLY from the canonical
// WGSL:  shaders/effects/filter/glyphMap/wgsl/glyphMap.wgsl
//
// Converts the input image to ASCII/glyph art using hardcoded 5x7 glyph bitmaps
// ordered by density. Each cell maps input brightness to a glyph. Single render
// pass (definition.js passes[].length == 1, program "glyphMap").
//
// PORTING-GUIDE notes:
//  * pcg PRNG: nm_pcg from NMCore is byte-identical to this effect's WGSL `pcg`,
//    so we reuse it. The effect's own `hash(vec2)` is ported VERBATIM inline (it
//    builds the uint3 with the sign-fold select() and a fixed 0u z-component,
//    matching the GLSL ternary order on disambiguation). Do NOT substitute the
//    shared nm_random/nm_prng — z is hardcoded 0u and only x/y are folded.
//  * select() reversal: WGSL `select(false_val, true_val, cond)` -> HLSL ternary
//    `cond ? true_val : false_val`. GLSL line 37 confirms the order:
//      p.x >= 0.0 ? p.x * 2.0 : -p.x * 2.0 + 1.0
//  * glyphRow / glyphPixel: hardcoded bitmap tables ported VERBATIM from WGSL.
//    The bit extract uses `>> u32(4 - x)` (WGSL requires u32 RHS); HLSL `>>` on
//    int with an int RHS is identical for the 0..4 range of (4 - x).
//  * Coordinate / sampling parity: the WGSL divides the cell-center sample coord
//    by the INPUT TEXTURE's own dimensions (textureDimensions(inputTex)), NOT
//    fullResolution. We mirror that with inputTex.GetDimensions in the .shader.
//  * tileOffset: the non-tiling path (length(tileOffset) == 0) is the common case
//    and must be byte-identical to the pre-tile shader. We reproduce the WGSL
//    tile branch literally (renderScale-scaled cell clamped to [1,512], global
//    pixel grid, edge-clamped sample uv).
//  * Determinism: variant selection from cellHash; WGSL only special-cases
//    variant == 2 (the GLSL variant==1 branch is a no-op self-assign and omitted
//    by the WGSL — we follow the WGSL).
//  * Full 32-bit float (PCG is bit-sensitive). Linear, clamp-to-edge, non-sRGB
//    sampler (H7) supplied by the .shader / Shader Graph node.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
int cellSize;    // globals.cellSize.uniform  "cellSize",  default 16 (4..32)
int seed;        // globals.seed.uniform      "seed",      default 1  (1..100)
int colorMode;   // globals.colorMode.uniform "colorMode", default 1  (mono 0 / rgb 1)

static const int GLYPH_COUNT = 16;

// -----------------------------------------------------------------------------
// nm_glyphMap_hash — ported VERBATIM from glyphMap.wgsl `hash(vec2<f32>)`.
// WGSL:
//   let v = pcg(vec3<u32>(
//       u32(select(-p.x * 2.0 + 1.0, p.x * 2.0, p.x >= 0.0)),
//       u32(select(-p.y * 2.0 + 1.0, p.y * 2.0, p.y >= 0.0)),
//       0u));
//   return f32(v.x) / f32(0xffffffffu);
// select(false, true, cond) -> ternary cond ? true : false.
// -----------------------------------------------------------------------------
float nm_glyphMap_hash(float2 p)
{
    uint3 v = nm_pcg(uint3(
        (uint)(p.x >= 0.0 ? p.x * 2.0 : -p.x * 2.0 + 1.0),
        (uint)(p.y >= 0.0 ? p.y * 2.0 : -p.y * 2.0 + 1.0),
        0u));
    return (float)v.x / (float)0xffffffffu;
}

// -----------------------------------------------------------------------------
// nm_glyphMap_glyphRow — ported VERBATIM from glyphMap.wgsl `glyphRow(g, y)`.
// Returns the 5-bit row value for glyph g (0..15), row y (0..6).
// -----------------------------------------------------------------------------
int nm_glyphMap_glyphRow(int g, int y)
{
    // Glyph 0: space
    if (g == 0) { return 0; }
    // Glyph 1: period
    if (g == 1) {
        if (y == 5) { return 4; }
        return 0;
    }
    // Glyph 2: colon
    if (g == 2) {
        if (y == 1 || y == 5) { return 4; }
        return 0;
    }
    // Glyph 3: dash
    if (g == 3) {
        if (y == 3) { return 14; }
        return 0;
    }
    // Glyph 4: plus
    if (g == 4) {
        if (y == 1 || y == 2 || y == 4 || y == 5) { return 4; }
        if (y == 3) { return 14; }
        return 0;
    }
    // Glyph 5: equals
    if (g == 5) {
        if (y == 2 || y == 4) { return 14; }
        return 0;
    }
    // Glyph 6: asterisk
    if (g == 6) {
        if (y == 1 || y == 5) { return 10; }
        if (y == 2 || y == 4) { return 4; }
        if (y == 3) { return 14; }
        return 0;
    }
    // Glyph 7: o
    if (g == 7) {
        if (y == 2 || y == 5) { return 14; }
        if (y == 3 || y == 4) { return 10; }
        return 0;
    }
    // Glyph 8: X
    if (g == 8) {
        if (y == 1 || y == 2 || y == 4 || y == 5) { return 10; }
        if (y == 3) { return 4; }
        return 0;
    }
    // Glyph 9: hash #
    if (g == 9) {
        if (y == 1 || y == 3 || y == 5) { return 10; }
        if (y == 2 || y == 4) { return 31; }
        return 0;
    }
    // Glyph 10: percent %
    if (g == 10) {
        if (y == 0) { return 25; }
        if (y == 1) { return 26; }
        if (y == 2) { return 4; }
        if (y == 3) { return 9; }
        if (y == 4) { return 11; }
        if (y == 5) { return 19; }
        return 0;
    }
    // Glyph 11: A
    if (g == 11) {
        if (y == 0) { return 4; }
        if (y == 1) { return 10; }
        if (y == 2) { return 17; }
        if (y == 3) { return 31; }
        if (y == 4 || y == 5) { return 17; }
        return 0;
    }
    // Glyph 12: W
    if (g == 12) {
        if (y == 0 || y == 1) { return 17; }
        if (y == 2 || y == 3) { return 21; }
        if (y == 4) { return 27; }
        if (y == 5) { return 10; }
        return 0;
    }
    // Glyph 13: M
    if (g == 13) {
        if (y == 0) { return 17; }
        if (y == 1) { return 27; }
        if (y == 2 || y == 3) { return 21; }
        if (y == 4 || y == 5) { return 17; }
        return 0;
    }
    // Glyph 14: @
    if (g == 14) {
        if (y == 0 || y == 6) { return 14; }
        if (y == 1) { return 17; }
        if (y == 2) { return 23; }
        if (y == 3) { return 21; }
        if (y == 4) { return 22; }
        if (y == 5) { return 16; }
        return 0;
    }
    // Glyph 15: full block
    return 31;
}

// -----------------------------------------------------------------------------
// nm_glyphMap_glyphPixel — ported VERBATIM from glyphMap.wgsl `glyphPixel`.
// WGSL:  let bit = (row >> u32(4 - x)) & 1;  return f32(bit);
// (4 - x) is in 0..4, so int >> int matches the u32 RHS exactly.
// -----------------------------------------------------------------------------
float nm_glyphMap_glyphPixel(int g, int x, int y)
{
    int row = nm_glyphMap_glyphRow(g, y);
    int bit = (row >> (uint)(4 - x)) & 1;
    return (float)bit;
}

// -----------------------------------------------------------------------------
// nm_glyphMap — core per-pixel evaluation. Takes the target pixel coord (the
// WGSL @builtin(position).xy analog) and the input texture size, samples the
// cell center and returns the glyph-mapped RGBA. Pure function so the render
// pass and any wrapper share identical math. Ported VERBATIM from glyphMap.wgsl
// main().
// -----------------------------------------------------------------------------
float4 nm_glyphMap(float2 pos, float2 texSize, Texture2D inputTex, SamplerState ss)
{
    float2 tileOffsetLocal = tileOffset;
    bool isTile = length(tileOffsetLocal) > 0.0;
    // Non-tiling path is byte-identical to the previous shader. When tiling,
    // mirror glsl/glyphMap.glsl: global pixel grid + renderScale-scaled cell
    // (clamped to 512) so cells align across tiles.
    float2 pixelCoord = pos;
    int cs = max(cellSize, 1);
    if (isTile) {
        pixelCoord = pos + tileOffsetLocal;
        cs = clamp((int)((float)cellSize * renderScale), 1, 512);
    }
    float csf = (float)cs;

    // Which cell are we in?
    float2 cellIndex = floor(pixelCoord / csf);

    // Local position within the cell, mapped to 5x7 glyph grid
    float2 localPos = frac(pixelCoord / csf);
    int gx = (int)(floor(localPos.x * 5.0));
    int gy = (int)(floor(localPos.y * 7.0));
    gx = clamp(gx, 0, 4);
    gy = clamp(gy, 0, 6);

    // Sample the center of the cell for brightness
    float2 cellCenter = (cellIndex + 0.5) * csf;
    float2 sampleUV = cellCenter / texSize;
    if (isTile) {
        sampleUV = clamp((cellCenter - tileOffsetLocal) / texSize, float2(0.0, 0.0), float2(1.0, 1.0));
    }
    float4 srcColor = inputTex.Sample(ss, sampleUV);

    // Compute luminance
    float luma = dot(srcColor.rgb, float3(0.299, 0.587, 0.114));

    // Map luminance to glyph index (0 to GLYPH_COUNT-1)
    int glyphIdx = (int)(floor(luma * (float)GLYPH_COUNT));
    glyphIdx = clamp(glyphIdx, 0, GLYPH_COUNT - 1);

    // Use seed to rotate/shift glyph selection for variety
    float cellHash = nm_glyphMap_hash(cellIndex + (float)seed * 0.37);
    int variant = (int)(floor(cellHash * 3.0));

    if (variant == 2 && glyphIdx > 1) {
        glyphIdx = glyphIdx - 1;
    }

    // Get the glyph pixel value
    float glyphVal = nm_glyphMap_glyphPixel(glyphIdx, gx, gy);

    if (colorMode > 0) {
        return float4(srcColor.rgb * glyphVal, 1.0);
    } else {
        return float4(glyphVal, glyphVal, glyphVal, 1.0);
    }
}

#endif // NM_GLYPHMAP_INCLUDED
