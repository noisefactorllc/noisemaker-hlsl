#ifndef NM_EFFECT_CELL_INCLUDED
#define NM_EFFECT_CELL_INCLUDED

// =============================================================================
// Cell.hlsl — synth/cell (Worley / Voronoi distance-field generator).
//
// Ported VERBATIM from shaders/effects/synth/cell/wgsl/cell.wgsl (canonical).
// WGSL is top-left / D3D-oriented like Unity HLSL: NO per-effect Y flip.
//
// Helpers ported inline per PORTING-GUIDE (polarShape/shape/smin are per-effect
// and must NOT be hoisted). Only pcg/prng/map come from NMCore via NMFullscreen
// (nm_prng matches the WGSL fold variant exactly; nm_map matches `map`).
// PI/TAU = NM_PI/NM_TAU. Engine globals (time, fullResolution) come from
// NMFullscreen aliases.
//
// PARITY HAZARDS handled here:
//   H3 — atan2 arg order: WGSL atan2(st.x, st.y) -> HLSL atan2(st.x, st.y) literal.
//   H4 — prng arg ORDER differs: point/r2 use prng(vec3(wrap, seed))
//        (= (wrap.x, wrap.y, seed)); r1 uses prng(vec3(seed, wrap))
//        (= (seed, wrap.x, wrap.y)). Reproduce exactly.
//   H13 — st divides by fullResolution.y (height).
//   H6 — no nm_mod needed (cell uses no float mod in the active path).
//   Full 32-bit float throughout (PCG bit-sensitive).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- per-effect named uniforms (definition.js globals[*].uniform) -----------
// `metric` <- globals.shape (uniform:"metric"). `seed` is int. All others float.
int   metric;       // shape enum: 0 circle,1 diamond,2 hexagon,3 octagon,4 square,6 triangle
float scale;        // noise scale  (1..100)
float cellScale;    // cell scale   (1..100)
float cellSmooth;   // cell smooth  (0..100)
float variation;    // cell variation (0..100)
float speed;        // animation speed (int 0..5 in UI; floored in shader)
int   seed;         // seed (1..100)

// polarShape: regular-polygon polar distance (verbatim from cell.wgsl L50-54).
// H3: atan2(st.x, st.y) — argument order copied literally (do NOT swap).
float nm_cell_polarShape(float2 st, int sides)
{
    float a = atan2(st.x, st.y) + NM_PI;
    float r = NM_TAU / (float)sides;
    return cos(floor(0.5 + a / r) * r - a) * length(st);
}

// shape: distance metric by `kind` (verbatim from cell.wgsl L56-73).
// kinds 1 and 5 fall through to d=1.0 (kind 1 is handled by metric==1 in cells).
float nm_cell_shape(float2 st0, float2 offset, int kind, float scaleArg)
{
    float2 st = st0 + offset;
    float d = 1.0;
    if (kind == 0) {
        d = length(st * 1.2);
    } else if (kind == 2) {
        d = nm_cell_polarShape(st * 1.2, 6);
    } else if (kind == 3) {
        d = nm_cell_polarShape(st * 1.2, 8);
    } else if (kind == 4) {
        d = nm_cell_polarShape(st * 1.5, 4);
    } else if (kind == 6) {
        float2 st2 = st;
        st2.y = st2.y + 0.05;
        d = nm_cell_polarShape(st2 * 1.5, 3);
    }
    return d * scaleArg;
}

// smin: iq polynomial smooth-min (verbatim from cell.wgsl L75-79).
float nm_cell_smin(float a, float b, float k)
{
    if (k == 0.0) { return min(a, b); }
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

// cells: 5x5 Worley neighborhood evaluation (verbatim from cell.wgsl L81-118).
float nm_cell_cells(float2 st0, float freq, float cellSize, int metricArg, int seedArg,
                    float speedArg, float variationArg, float cellSmoothArg,
                    float timeArg, float aspect)
{
    float2 st = st0;
    st = st - float2(0.5 * aspect, 0.5);
    st = st * freq;
    st = st + float2(0.5 * aspect, 0.5);
    st = st + nm_prng(float3((float)seedArg, (float)seedArg, (float)seedArg)).xy;

    float2 i = floor(st);
    float2 f = frac(st);

    float d = 1.0;
    for (int y = -2; y <= 2; y = y + 1) {
        for (int x = -2; x <= 2; x = x + 1) {
            float2 n = float2((float)x, (float)y);
            float2 wrap = i + n;
            // H4: pt/r2 use (wrap.x, wrap.y, seed); r1 uses (seed, wrap.x, wrap.y).
            // NB: 'point' is an HLSL reserved keyword (geometry primitive) -> renamed pt.
            float2 pt = nm_prng(float3(wrap, (float)seedArg)).xy;

            float3 r1 = nm_prng(float3((float)seedArg, wrap)) * 0.5 - float3(0.25, 0.25, 0.25);
            float3 r2 = nm_prng(float3(wrap, (float)seedArg)) * 2.0 - float3(1.0, 1.0, 1.0);
            float spd = floor(speedArg);
            pt = pt + float2(
                sin(timeArg * NM_TAU * spd + r2.x) * r1.x,
                cos(timeArg * NM_TAU * spd + r2.y) * r1.y
            );

            float2 diff = n + pt - f;
            float dist = nm_cell_shape(float2(diff.x, -diff.y), float2(0.0, 0.0), metricArg, cellSize);
            if (metricArg == 1) {
                dist = abs(n.x + pt.x - f.x) + abs(n.y + pt.y - f.y);
                dist = dist * cellSize;
            }

            dist = dist + r1.z * (variationArg * 0.01);
            d = nm_cell_smin(d, dist, cellSmoothArg * 0.01);
        }
    }
    return d;
}

// nm_cell: top-level generator. `st` is the WGSL `st` (globalCoord/fullResolution.y).
// Returns the mono distance field as float4 (rgb=d, a=1) matching cell.wgsl main().
float4 nm_cell(float2 st, float scaleArg, float cellScaleArg, int metricArg, int seedArg,
               float speedArg, float variationArg, float cellSmoothArg,
               float timeArg, float aspect)
{
    float freq     = nm_map(scaleArg,     1.0, 100.0, 20.0, 1.0);
    float cellSize = nm_map(cellScaleArg, 1.0, 100.0, 3.0,  0.75);

    float d = nm_cell_cells(st, freq, cellSize, metricArg, seedArg,
                            speedArg, variationArg, cellSmoothArg, timeArg, aspect);

    // Mono output only; WGSL preserves initial color.a = 1.0.
    return float4(d, d, d, 1.0);
}

#endif // NM_EFFECT_CELL_INCLUDED
