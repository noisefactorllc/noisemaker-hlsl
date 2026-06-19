#ifndef NM_TESTPATTERN_INCLUDED
#define NM_TESTPATTERN_INCLUDED

// =============================================================================
// TestPattern.hlsl — synth/testPattern, ported PIXEL-IDENTICALLY from the
// canonical WGSL source:
//   shaders/effects/synth/testPattern/wgsl/testPattern.wgsl
//
// Test patterns for debugging and calibration. Single render pass selecting one
// of 7 patterns (checkerboard, colorBars, gradient, uvMap, gridLines, colorGrid,
// dotGrid) by the `pattern` int uniform.
//
// Helpers (sampleGlyph, renderNumber, hue2rgb, the seven pattern fns) are ported
// VERBATIM and INLINE per PORTING-GUIDE. There are no shared color/dist libs in
// use. This effect uses NO PCG/prng. Only nm_mod et al. would come from NMCore,
// but this effect needs none of them.
//
// NUMERIC / TRANSLATION HAZARDS handled:
//  * UV: uv = (globalCoord) / fr, where
//      fr = select(resolution, fullResolution, fullResolution.x > 0.0)
//        -> HLSL: (fullResolution.x > 0.0) ? fullResolution : resolution.
//    NOTE this effect divides globalCoord by the FULL vec2 `fr` (both axes),
//    NOT by .y only. Mirrors WGSL main() exactly. (uv.x then spans [0,1], not
//    [0,aspect]; the test patterns are defined in 0..1 screen-UV space.)
//  * i32(float) is float->int TRUNCATION toward zero (HLSL (int) cast).
//  * `%` on ints truncates toward zero in WGSL/GLSL/HLSL alike. The reference
//    relies on uv being >= 0 so cellX/cellY/temp%10 are non-negative; we keep
//    the bare `%` exactly as written (do NOT substitute nm_positiveModulo).
//  * GLYPH bit shift uses u32(bitIndex); bitIndex in [0,14] is always >= 0, so
//    (uint) cast is exact. `>> u32(bitIndex)` -> HLSL `>> (uint)bitIndex`.
//  * select(a,b,cond) ternaries copied with WGSL arg order:
//      select(cellColor, glyphColor, isGlyph) -> isGlyph ? glyphColor : cellColor
//      select(0.0, 1.0, isWhiteCell)          -> isWhiteCell ? 1.0 : 0.0
//      select(1.0, 0.0, isWhiteCell)          -> isWhiteCell ? 0.0 : 1.0
//  * gridLines uses fwidthFine(uv*n) on the NON-tiling path. WGSL fwidthFine ->
//    HLSL ddx_fine/ddy_fine; fwidth-style magnitude = |ddx_fine| + |ddy_fine|.
//    This is computed UNCONDITIONALLY in uniform control flow (as the WGSL does),
//    then overridden only when tiling. (Screen-space derivatives require a frag
//    stage; the Shader Graph wrapper has no derivatives, so it forces the tiling
//    analytic-width path — see ShaderGraph/CustomFunctions/TestPattern.hlsl.)
//  * golden-ratio hue constant kept full-precision: 0.618033988749895.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
// Bound by the runtime via MaterialPropertyBlock.
int gridSize;   // [1,16], default 4   (global "gridSize")
int pattern;    // enum 0..6, default 0 (global "pattern")

// 3x5 pixel font for digits 0-9. Each digit is encoded as 15 bits
// (3 columns x 5 rows, row-major). Verbatim from WGSL `GLYPH`.
static const int NMTP_GLYPH[10] = {
    0x7B6F,  // 0: 111 101 101 101 111
    0x2492,  // 1: 010 010 010 010 010
    0x73E7,  // 2: 111 001 111 100 111
    0x72CF,  // 3: 111 001 011 001 111
    0x5BC9,  // 4: 101 101 111 001 001
    0x79CF,  // 5: 111 100 111 001 111
    0x79EF,  // 6: 111 100 111 101 111
    0x7249,  // 7: 111 001 001 001 001
    0x7BEF,  // 8: 111 101 111 101 111
    0x7BCF   // 9: 111 101 111 001 111
};

// Sample a glyph at local coordinates (0-2, 0-4). Verbatim from WGSL.
bool nmtp_sampleGlyph(int digit, int x, int y)
{
    if (digit < 0 || digit > 9 || x < 0 || x > 2 || y < 0 || y > 4)
    {
        return false;
    }
    int bitIndex = y * 3 + (2 - x);  // row-major, top-left origin
    return ((NMTP_GLYPH[digit] >> (uint)bitIndex) & 1) == 1;
}

// Render a number at a position within a cell. Verbatim from WGSL.
bool nmtp_renderNumber(int number, float2 cellUV)
{
    // Determine how many digits we need
    int numDigits = 1;
    if (number >= 10) { numDigits = 2; }
    if (number >= 100) { numDigits = 3; }

    // Glyph dimensions in UV space (centered, scaled to fit nicely)
    float glyphWidth = 0.15;
    float glyphHeight = 0.35;
    float spacing = 0.05;

    float totalWidth = (float)numDigits * glyphWidth + (float)(numDigits - 1) * spacing;
    float startX = 0.5 - totalWidth * 0.5;
    float startY = 0.5 - glyphHeight * 0.5;

    // Check if we're in the vertical range for glyphs
    if (cellUV.y < startY || cellUV.y >= startY + glyphHeight)
    {
        return false;
    }

    // Extract digits (right to left)
    int digits[3] = { 0, 0, 0 };
    int temp = number;
    [loop]
    for (int i = 0; i < 3; i++)
    {
        digits[i] = temp % 10;
        temp = temp / 10;
    }

    // Check each digit position (left to right)
    [loop]
    for (int d = 0; d < numDigits; d++)
    {
        float digitX = startX + (float)d * (glyphWidth + spacing);

        if (cellUV.x >= digitX && cellUV.x < digitX + glyphWidth)
        {
            // We're in this digit's horizontal range
            float localX = (cellUV.x - digitX) / glyphWidth;
            float localY = (cellUV.y - startY) / glyphHeight;

            // Map to 3x5 grid
            int gx = (int)(localX * 3.0);
            int gy = (int)(localY * 5.0);

            // Get the correct digit (numDigits-1-d because digits[] is reversed)
            int digit = digits[numDigits - 1 - d];

            return nmtp_sampleGlyph(digit, gx, gy);
        }
    }

    return false;
}

// Pattern 0: Numbered checkerboard. Verbatim from WGSL.
float4 nmtp_checkerboard(float2 uv)
{
    int n = max(gridSize, 1);
    int cellX = (int)(uv.x * (float)n) % n;
    int cellY = (int)(uv.y * (float)n) % n;

    int cellNum = (n - 1 - cellY) * n + cellX;

    bool isWhiteCell = ((cellX + cellY) % 2) == 0;

    float2 cellUV = frac(uv * (float)n);

    bool isGlyph = nmtp_renderNumber(cellNum, cellUV);

    // WGSL select(a,b,cond) == cond ? b : a (arg order preserved literally).
    float cellColor = isWhiteCell ? 1.0 : 0.0;   // select(0.0, 1.0, isWhiteCell)
    float glyphColor = isWhiteCell ? 0.0 : 1.0;  // select(1.0, 0.0, isWhiteCell)
    float finalColor = isGlyph ? glyphColor : cellColor; // select(cellColor, glyphColor, isGlyph)

    return float4(float3(finalColor, finalColor, finalColor), 1.0);
}

// Pattern 1: 8 vertical SMPTE-style color bars. Verbatim from WGSL.
float4 nmtp_colorBars(float2 uv)
{
    int bar = (int)(uv.x * 8.0);
    bar = clamp(bar, 0, 7);

    // white, yellow, cyan, green, magenta, red, blue, black
    float3 colors[8] = {
        float3(1.0, 1.0, 1.0),
        float3(1.0, 1.0, 0.0),
        float3(0.0, 1.0, 1.0),
        float3(0.0, 1.0, 0.0),
        float3(1.0, 0.0, 1.0),
        float3(1.0, 0.0, 0.0),
        float3(0.0, 0.0, 1.0),
        float3(0.0, 0.0, 0.0)
    };

    return float4(colors[bar], 1.0);
}

// Pattern 2: Horizontal black-to-white gradient ramp. Verbatim from WGSL.
float4 nmtp_gradientRamp(float2 uv)
{
    return float4(float3(uv.x, uv.x, uv.x), 1.0);
}

// Pattern 3: UV map (R=u, G=v, B=0). Verbatim from WGSL.
float4 nmtp_uvMapPattern(float2 uv)
{
    return float4(uv.x, uv.y, 0.0, 1.0);
}

// Pattern 4: Thin white grid lines on black. Verbatim from WGSL.
// `fw` is computed unconditionally (fwidthFine must be evaluated in uniform
// control flow), then overridden on the tiling path with an analytic width.
float4 nmtp_gridLines(float2 uv)
{
    int n = max(gridSize, 1);
    float2 cellUV = frac(uv * (float)n);
    float2 edge = min(cellUV, 1.0 - cellUV);

    // Non-tiling: original fwidth-based AA (byte-identical baseline).
    // Tiling: analytic AA width mirroring glsl/testPattern.glsl, which is
    // seam-stable across tiles where screen-space derivatives are not.
    bool isTile = length(tileOffset) > 0.0;

    // WGSL fwidthFine(p) == |dpdxFine(p)| + |dpdyFine(p)|.
    float2 p = uv * (float)n;
    float2 fw = abs(ddx_fine(p)) + abs(ddy_fine(p));
    float edgeMul = 1.5;
    if (isTile)
    {
        // select(resolution, fullResolution, fullResolution.x > 0.0)
        float2 fr = (fullResolution.x > 0.0) ? fullResolution : resolution;
        fw = float2(1.0, 1.0) / fr * (float)n;
        edgeMul = 2.0;
    }
    float lineVal = 1.0 - smoothstep(0.0, edgeMul * fw.x, edge.x) * smoothstep(0.0, edgeMul * fw.y, edge.y);
    return float4(float3(lineVal, lineVal, lineVal), 1.0);
}

// HSV to RGB (hue only, full saturation & value). Verbatim from WGSL.
float3 nmtp_hue2rgb(float h)
{
    float r = abs(h * 6.0 - 3.0) - 1.0;
    float g = 2.0 - abs(h * 6.0 - 2.0);
    float b = 2.0 - abs(h * 6.0 - 4.0);
    return clamp(float3(r, g, b), float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

// Pattern 5: Each cell gets a unique hue. Verbatim from WGSL.
float4 nmtp_colorGrid(float2 uv)
{
    int n = max(gridSize, 1);
    int cellX = (int)(uv.x * (float)n) % n;
    int cellY = (int)(uv.y * (float)n) % n;
    int cellIndex = cellY * n + cellX;
    float hue = frac((float)cellIndex * 0.618033988749895);
    return float4(nmtp_hue2rgb(hue), 1.0);
}

// Pattern 6: Filled circle at each grid intersection. Verbatim from WGSL.
float4 nmtp_dotGrid(float2 uv)
{
    int n = max(gridSize, 1);
    float2 scaled = uv * (float)n;
    float2 nearest = round(scaled);
    float dist = length(scaled - nearest);
    float d = 1.0 - smoothstep(0.12, 0.15, dist);
    return float4(float3(d, d, d), 1.0);
}

// =============================================================================
// nm_testPattern — core per-pixel evaluation. `globalCoord` is the fragment's
// pixel coordinate plus tileOffset (i.e. NM_GlobalCoord(i)). Returns RGBA.
// Mirrors WGSL main() exactly. `res`/`fullRes_in` are the render target / full
// (untiled) sizes. gridLines reads engine globals tileOffset/resolution/
// fullResolution via the NMFullscreen aliases (the Shader Graph wrapper seeds
// them from its inputs).
// =============================================================================
float4 nm_testPattern(float2 globalCoord, float2 res, float2 fullRes_in)
{
    // Tile-aware global UV (mirror WGSL main()). Non-tiling
    // (tileOffset=(0,0), fullResolution=resolution) is byte-identical.
    // WGSL: fr = select(resolution, fullResolution, fullResolution.x > 0.0)
    float2 fr = (fullRes_in.x > 0.0) ? fullRes_in : res;
    float2 uv = globalCoord / fr;  // divides by FULL vec2 (both axes)

    if (pattern == 1)
    {
        return nmtp_colorBars(uv);
    }
    else if (pattern == 2)
    {
        return nmtp_gradientRamp(uv);
    }
    else if (pattern == 3)
    {
        return nmtp_uvMapPattern(uv);
    }
    else if (pattern == 4)
    {
        return nmtp_gridLines(uv);
    }
    else if (pattern == 5)
    {
        return nmtp_colorGrid(uv);
    }
    else if (pattern == 6)
    {
        return nmtp_dotGrid(uv);
    }
    else
    {
        return nmtp_checkerboard(uv);
    }
}

#endif // NM_TESTPATTERN_INCLUDED
