#ifndef NM_SPOOKYTICKER_INCLUDED
#define NM_SPOOKYTICKER_INCLUDED

// =============================================================================
// SpookyTicker.hlsl — filter/spookyTicker, ported PIXEL-IDENTICALLY from the
//   canonical WGSL source:
//   shaders/effects/filter/spookyTicker/wgsl/spookyTicker.wgsl
//
// Renders rows of hash-based segmented glyphs (bank-OCR digit bitmaps) that
// scroll horizontally across the bottom of the frame, with shadow and
// screen-mode blend composite over the input.
//
// PORTING-GUIDE notes / hazards handled:
//  * hash_mix is an effect-local helper — copied verbatim. It is NOT a shared
//    NMCore primitive.
//  * sample_glyph and ticker_row_mask are also local — copied verbatim.
//  * WGSL uses textureLoad (texel-integer address), not textureSample; we use
//    the same approach: compute uv = fragCoord / dims, then Sample with that uv.
//    The WGSL dims = vec2<f32>(textureDimensions(inputTex, 0)), i.e. the INPUT
//    texture's own dimensions — we mirror exactly with GetDimensions.
//  * `position.xy` (WGSL @builtin, top-left +0.5) maps to NM_FragCoord(i).
//    No per-effect Y flip (porting from WGSL).
//  * pyFromBottom = floor((1 - uv.y) * dims.y) — follows WGSL exactly.
//  * WGSL constants (SCALE=3, CELL_W=21, CELL_H=24, ROW_GAP=4) are hardcoded
//    as ints — the WGSL uses compile-time `const`, not uniforms. Note: the GLSL
//    version scales these by renderScale; the WGSL does NOT — WGSL is canonical.
//  * Integer shift: WGSL `row >> u32(6 - gx)` → HLSL `row >> (uint)(6 - gx)`.
//  * `select(b,a,cond)` in WGSL (reversed) is translated to `cond ? a : b`.
//  * `nm_mod` not needed (all division here is integer floor-division via the
//    manual negative-sx branch, copied verbatim).
//  * `time` and `seed` are engine/per-effect uniforms via NMFullscreen.hlsl.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler ------------------------------------------------
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
float speed;   // default 1.0, [0,5]
float alpha;   // default 0.75, [0,1]
int   rows;    // default 2, [1,3]
int   seed;    // default 1, [1,100]

// ---- WGSL compile-time constants (verbatim) ---------------------------------
static const int GLYPHS[80] = {
    // Digit 0
    0x3C, 0x42, 0x42, 0x42, 0x42, 0x42, 0x3C, 0x00,
    // Digit 1
    0x18, 0x08, 0x08, 0x08, 0x1C, 0x1C, 0x1C, 0x00,
    // Digit 2
    0x1C, 0x04, 0x04, 0x1C, 0x10, 0x10, 0x1C, 0x00,
    // Digit 3
    0x1C, 0x04, 0x04, 0x1C, 0x06, 0x06, 0x1E, 0x00,
    // Digit 4
    0x60, 0x60, 0x60, 0x60, 0x66, 0x7E, 0x06, 0x00,
    // Digit 5
    0x3C, 0x20, 0x20, 0x3C, 0x04, 0x04, 0x3C, 0x00,
    // Digit 6
    0x78, 0x48, 0x40, 0x40, 0x7E, 0x42, 0x7E, 0x00,
    // Digit 7
    0x3C, 0x24, 0x04, 0x0C, 0x08, 0x08, 0x08, 0x00,
    // Digit 8
    0x3C, 0x24, 0x24, 0x7E, 0x66, 0x66, 0x7E, 0x00,
    // Digit 9
    0x3E, 0x22, 0x22, 0x3E, 0x06, 0x06, 0x06, 0x00
};

static const int GLYPH_W = 7;
static const int GLYPH_H = 8;
static const int SCALE   = 3;
static const int CELL_W  = 21;  // GLYPH_W * SCALE
static const int CELL_H  = 24;  // GLYPH_H * SCALE
static const int ROW_GAP = 4;

// -----------------------------------------------------------------------------
// hash_mix — effect-local; verbatim from WGSL.
// WGSL:
//   r = v ^ (r >> 16u); r = r * 0x7feb352du; r = r ^ (r >> 15u);
//   r = r * 0x846ca68bu; r = r ^ (r >> 16u); return r;
// -----------------------------------------------------------------------------
uint hash_mix(uint v)
{
    uint r = v;
    r = r ^ (r >> 16u);
    r = r * 0x7feb352du;
    r = r ^ (r >> 15u);
    r = r * 0x846ca68bu;
    r = r ^ (r >> 16u);
    return r;
}

// -----------------------------------------------------------------------------
// sample_glyph — effect-local; verbatim from WGSL.
// WGSL `(row >> u32(6 - gx)) & 1` → HLSL `(row >> (uint)(6 - gx)) & 1`.
// -----------------------------------------------------------------------------
float sample_glyph(int digit, int localX, int localY)
{
    int gx = localX / SCALE;
    int gy = localY / SCALE;
    if (gx < 0 || gx >= GLYPH_W || gy < 0 || gy >= GLYPH_H)
    {
        return 0.0;
    }
    int row = GLYPHS[digit * 8 + gy];
    // WGSL: f32((row >> u32(6 - gx)) & 1)
    return (float)((row >> (uint)(6 - gx)) & 1);
}

// -----------------------------------------------------------------------------
// ticker_row_mask — effect-local; verbatim from WGSL.
// Negative-sx branch: WGSL `(sx - CELL_W + 1) / CELL_W` copied literally.
// Hash expression: WGSL `hash_mix(u32(cellX) ^ (u32(rowSeed) * 997u))`.
// -----------------------------------------------------------------------------
float ticker_row_mask(int pixelX, int pixelY, int rowSeed, float t)
{
    // WGSL: 0.5 + f32(hash_mix(u32(rowSeed) ^ 17u) & 0xFFFFu) / 65535.0 * 1.5
    float scrollSpeed = 0.5 + (float)(hash_mix((uint)rowSeed ^ 17u) & 0xFFFFu) / 65535.0 * 1.5;
    int offset = (int)floor(t * scrollSpeed * 120.0);

    int sx = pixelX + offset;
    int cellX;
    if (sx >= 0)
    {
        cellX = sx / CELL_W;
    }
    else
    {
        cellX = (sx - CELL_W + 1) / CELL_W;
    }
    int localX = sx - cellX * CELL_W;

    // WGSL: hash_mix(u32(cellX) ^ (u32(rowSeed) * 997u))
    uint h = hash_mix((uint)cellX ^ ((uint)rowSeed * 997u));
    int digit = (int)(h % 10u);

    return sample_glyph(digit, localX, pixelY);
}

// =============================================================================
// NMFrag_spookyTicker — main fragment pass.
// Mirrors WGSL @fragment main() verbatim.
// =============================================================================
float4 NMFrag_spookyTicker(NMVaryings i) : SV_Target
{
    // WGSL: let dims = vec2<f32>(textureDimensions(inputTex, 0));
    uint tw, th;
    inputTex.GetDimensions(tw, th);
    float2 dims = float2((float)tw, (float)th);

    // WGSL: let uv = position.xy / dims;
    float2 uv = NM_FragCoord(i) / dims;

    // WGSL: let src = textureLoad(inputTex, vec2<i32>(position.xy), 0);
    // textureLoad samples at integer texel without filtering; Sample at uv
    // computed from the same fragCoord is pixel-identical for a 1:1 blit.
    float4 src = inputTex.Sample(sampler_inputTex, uv);

    float t = time * speed;
    uint baseSeed = hash_mix((uint)seed * 7919u);

    int totalH = rows * (CELL_H + ROW_GAP);

    // WGSL: let px = i32(floor(uv.x * dims.x));
    int px = (int)floor(uv.x * dims.x);
    // WGSL: let pyFromBottom = i32(floor((1.0 - uv.y) * dims.y));
    int pyFromBottom = (int)floor((1.0 - uv.y) * dims.y);

    if (pyFromBottom >= totalH)
    {
        return src;
    }

    int rowStride = CELL_H + ROW_GAP;
    int rowIdx    = pyFromBottom / rowStride;
    int localY    = pyFromBottom - rowIdx * rowStride;

    if (rowIdx >= rows || localY >= CELL_H)
    {
        return src;
    }

    // WGSL: let rowSeed = i32(hash_mix(u32(rowIdx) + baseSeed));
    int rowSeed = (int)hash_mix((uint)rowIdx + baseSeed);

    float mask = ticker_row_mask(px, localY, rowSeed, t);

    float shadow = 0.0;
    int shadowLocalY = localY + 2;
    if (shadowLocalY < CELL_H)
    {
        shadow = ticker_row_mask(px + 2, shadowLocalY, rowSeed, t);
    }

    float3 result = src.rgb;
    // WGSL: result = result * (1.0 - shadow * 0.4 * alpha);
    result = result * (1.0 - shadow * 0.4 * alpha);
    // WGSL: result = max(result, vec3<f32>(mask) * alpha);
    result = max(result, float3(mask, mask, mask) * alpha);

    return float4(clamp(result, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0)), src.a);
}

#endif // NM_SPOOKYTICKER_INCLUDED
