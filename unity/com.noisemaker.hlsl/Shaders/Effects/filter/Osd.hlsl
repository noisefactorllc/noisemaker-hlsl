#ifndef NM_OSD_INCLUDED
#define NM_OSD_INCLUDED

// =============================================================================
// Osd.hlsl — filter/osd, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/osd/wgsl/osd.wgsl
//
// On-screen display overlay: bank_ocr pseudo-glyph digit readout in a corner,
// with a subtle scanline tint and a dark background panel. Time-cycling digits.
//
// PORTING NOTES (WGSL is canonical, GLSL only disambiguates):
//  * The WGSL is a compute shader writing an output_buffer, but operationally it
//    is a per-pixel filter: each invocation reads one input texel and writes one
//    output pixel. We port it as a single fullscreen render pass.
//  * COORDINATE SYSTEM: the canonical WGSL is a COMPUTE shader and uses gid.xy
//    with y=0 at the TOP (output_buffer row 0 = top; no render flip). This port
//    is a render PASS: NM_FragCoord(i).y, like gl_FragCoord, has y=0 at the
//    BOTTOM (confirmed against the verified filter/spookyTicker pair). So we
//    flip Y ONCE inside nm_osd (coord.y = (h-1) - icoord.y) to recover the
//    WGSL's top-origin layout — equivalent to the render-path GLSL osd.glsl,
//    which documents "GL coords: y=0 is bottom" and uses local_y = (CELL_H-1)-ly.
//    See the detailed note at the coord setup in nm_osd.
//  * NO renderScale scaling: the WGSL uses fixed integer SCALE/PADDING constants.
//    (The GLSL multiplies sizes by renderScale; that is a GLSL-only export path.
//    WGSL is canonical, so we use the fixed constants.) // TODO(verify) at
//    renderScale != 1 the WGSL path is the reference.
//  * width/height come from params.width/height in the WGSL, which equal the
//    input texture's own dimensions. We read inputTex.GetDimensions() and use
//    those for both the sample size and corner positioning — matching Invert and
//    the WGSL (which uses the same w/h for textureLoad and layout).
//  * coord & globalCoord are identical here (WGSL has no tileOffset). We use the
//    pixel coord directly; tileOffset does not enter the math.
//  * PRNG: pcg(uint)/hash2/hash3 are this effect's OWN scalar variants (NMCore
//    only provides nm_pcg(uint3)); ported verbatim inline. PCG arg order and the
//    select/redundant expressions are copied literally (H3/H4/H6).
//  * Sampling is by integer texel (textureLoad), reproduced with NM_FragCoord ->
//    int coord and a single .Sample at the texel-center UV (linear+clamp gives
//    the exact texel since the coord is pixel-centered).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
float alpha;   // 0..1 blend
int   seed;    // 1..100
float speed;   // 0..50 (digit cycle speed)
int   corner;  // 0=TL 1=TR 2=BL 3=BR

// ---- Compile-time constants (WGSL `const`) ----------------------------------
static const int GLYPH_W = 7;
static const int GLYPH_H = 8;
static const int SCALE   = 3;
static const int CELL_W  = 21;  // GLYPH_W * SCALE
static const int CELL_H  = 24;  // GLYPH_H * SCALE
static const int GAP     = 3;   // SCALE
static const int PADDING = 25;

// Bank OCR bitmaps: 10 digits, 7 wide x 8 tall each (verbatim from WGSL).
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

// ---- PRNG (this effect's own scalar variants — ported verbatim) -------------
uint nm_osd_pcg(uint v_in)
{
    uint state = v_in * 747796405u + 2891336453u;
    uint word  = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

uint nm_osd_hash2(uint a, uint b)
{
    return nm_osd_pcg(a ^ (b * 0x9e3779b9u + 0x632be59bu));
}

uint nm_osd_hash3(uint a, uint b, uint c)
{
    return nm_osd_pcg(nm_osd_hash2(a, b) ^ (c * 0x94d049bbu + 0x5bf03635u));
}

// Sample the bitmap for a given digit at pixel-local coords.
float nm_osd_sample_glyph(int digit, int localX, int localY)
{
    int gx = localX / SCALE;
    int gy = localY / SCALE;
    if (gx < 0 || gx >= GLYPH_W || gy < 0 || gy >= GLYPH_H) {
        return 0.0;
    }
    int row = GLYPHS[digit * 8 + gy];
    // WGSL: f32((row >> u32(6 - gx)) & 1)
    return (float)((row >> (uint)(6 - gx)) & 1);
}

// -----------------------------------------------------------------------------
// nm_osd — core per-pixel evaluation. `texel` is the already-sampled input
// color, `icoord` is the integer pixel coord (top-left origin, == WGSL gid.xy),
// and (w,h) are the input texture dimensions (== WGSL params.width/height).
// Returns the final RGBA.
// -----------------------------------------------------------------------------
float4 nm_osd(float4 texel, int2 icoord, int w, int h)
{
    // Y-ORIENTATION: the canonical WGSL is a COMPUTE shader and indexes its
    // output_buffer by gid.y with y=0 at the TOP (no render flip). This HLSL
    // render-pass port receives NM_FragCoord(i), which — like gl_FragCoord — has
    // y=0 at the BOTTOM (verified against the sibling filter/spookyTicker pair,
    // whose @fragment WGSL uses `1.0 - uv.y`). The render-path GLSL osd.glsl
    // therefore documents "GL coords: y=0 is bottom" and flips the glyph row via
    //   `int local_y = (CELL_H - 1) - ly;`
    // To reproduce the WGSL's top-origin layout exactly, flip the Y coord ONCE
    // here so the WGSL body below (corner placement, panel test, local_y = ly,
    // scanline coord.y&1) operates in top-origin space, matching the golden.
    // X is unaffected. `texel`/base_rgb stay at the un-flipped fragment pixel
    // (input and output share the same coord in both the WGSL and this port).
    int2 coord = int2(icoord.x, (h - 1) - icoord.y);

    float blend_alpha = clamp(alpha, 0.0, 1.0);

    // Subtle scanline tint across entire image (OSD monitor feel)
    float scanline = 1.0 - 0.03 * blend_alpha * (float)(coord.y & 1);
    float3 base_rgb = texel.rgb * scanline;

    if (blend_alpha <= 0.0) {
        return float4(base_rgb.x, base_rgb.y, base_rgb.z, texel.a);
    }

    uint base_seed = (uint)max((float)seed, 1.0);
    int width  = w;
    int height = h;

    // Glyph count: 3-6 from seed
    int glyph_count = 3 + (int)(nm_osd_hash2(base_seed, 42u) % 4u);

    // Overlay dimensions
    int overlay_w = glyph_count * CELL_W + (glyph_count - 1) * GAP;
    int overlay_h = CELL_H;

    // Position based on corner (WebGPU coords: y=0 is top)
    // 0=TL, 1=TR, 2=BL, 3=BR
    int corner_val = corner;
    int origin_x;
    int origin_y;
    if (corner_val == 0) { // top-left
        origin_x = PADDING;
        origin_y = PADDING;
    } else if (corner_val == 1) { // top-right
        origin_x = width - overlay_w - PADDING;
        origin_y = PADDING;
    } else if (corner_val == 2) { // bottom-left
        origin_x = PADDING;
        origin_y = height - overlay_h - PADDING;
    } else { // bottom-right (default)
        origin_x = width - overlay_w - PADDING;
        origin_y = height - overlay_h - PADDING;
    }
    if (origin_x < 0) {
        origin_x = 0;
    }
    if (origin_y < 0) {
        origin_y = 0;
    }

    // Expand OSD region with padding for background panel
    int panel_pad = GAP * 2;
    int panel_x0 = origin_x - panel_pad;
    int panel_y0 = origin_y - panel_pad;
    int panel_x1 = origin_x + overlay_w + panel_pad;
    int panel_y1 = origin_y + overlay_h + panel_pad;

    // Outside panel region: just scanline
    if (coord.x < panel_x0 || coord.x >= panel_x1 || coord.y < panel_y0 || coord.y >= panel_y1) {
        return float4(base_rgb.x, base_rgb.y, base_rgb.z, texel.a);
    }

    // Check if pixel is in OSD glyph region
    int lx = coord.x - origin_x;
    int ly = coord.y - origin_y;

    float mask = 0.0;
    if (lx >= 0 && lx < overlay_w && ly >= 0 && ly < overlay_h) {
        // Determine which glyph
        int cell_stride = CELL_W + GAP;
        int glyph_idx = lx / cell_stride;
        int within_glyph_x = lx - glyph_idx * cell_stride;

        if (within_glyph_x < CELL_W && glyph_idx < glyph_count) {
            // Local Y within glyph (y=0 is top in WebGPU, glyph row 0 is top)
            int local_y = ly;

            // Time-cycling digit selection
            int time_cell = (int)floor(time * max(speed, 0.001));
            uint digit_hash = nm_osd_hash3(base_seed, (uint)glyph_idx, (uint)time_cell);
            int digit = (int)(digit_hash % 10u);

            mask = nm_osd_sample_glyph(digit, within_glyph_x, local_y);
        }
    }

    // Dark background panel behind digits
    float3 panel_bg = base_rgb * (1.0 - 0.5 * blend_alpha);

    if (mask < 0.5) {
        return float4(
            clamp(panel_bg.x, 0.0, 1.0),
            clamp(panel_bg.y, 0.0, 1.0),
            clamp(panel_bg.z, 0.0, 1.0),
            texel.a);
    }

    // Green/white OSD tint
    float3 osd_color = float3(0.7, 1.0, 0.75);
    float3 highlight = max(panel_bg, osd_color * mask);
    float3 blended = lerp(panel_bg, highlight, blend_alpha);
    return float4(
        clamp(blended.x, 0.0, 1.0),
        clamp(blended.y, 0.0, 1.0),
        clamp(blended.z, 0.0, 1.0),
        texel.a);
}

#endif // NM_OSD_INCLUDED
