#ifndef NM_CELLSPLIT_INCLUDED
#define NM_CELLSPLIT_INCLUDED

// =============================================================================
// CellSplit.hlsl — mixer/cellSplit, ported PIXEL-IDENTICALLY from the canonical
// WGSL:  shaders/effects/mixer/cellSplit/wgsl/cellSplit.wgsl
//
// Split between two inputs (A = inputTex, B = tex) using Voronoi cell regions.
// Single render pass (definition.js passes.length == 1, program "cellSplit").
//
// PORTING-GUIDE notes:
//  * pcg/prng are the shared primitives — this effect's WGSL `prng` is
//    BIT-IDENTICAL to NMCore's nm_prng (sign-fold, (uint3)p truncation, divide by
//    4294967295.0), so we call nm_prng directly (golden rule 2 satisfied: same
//    algorithm, not a substitution of a differing helper).
//  * TAU is the effect's own local const (6.28318530718) — kept inline to mirror
//    the WGSL `const TAU` literally.
//  * `mode`, `invert`, `seed`: WGSL i32 uniforms -> int uniforms. `scale`,
//    `edgeWidth`, `speed`: WGSL f32 uniforms -> float uniforms. No compile-time
//    defines in this effect.
//  * Color sample uv: WGSL lines 41-45 divide position.xy by inputTex's OWN
//    dimensions (NOT fullResolution, NOT tileOffset-shifted), and use that same
//    `st` to sample BOTH inputTex and tex:
//        let dims = vec2<f32>(textureDimensions(inputTex, 0));
//        let st   = position.xy / dims;
//        colorA = textureSample(inputTex, samp, st);
//        colorB = textureSample(tex,      samp, st);
//    We follow the WGSL literally: NM_FragCoord(i) / inputTex dims, used for both.
//  * Voronoi uv: WGSL line 50 uses (position.xy + tileOffset) / fullResolution,
//    i.e. NM_GlobalCoord(i) / fullResolution. tileOffset DOES enter here (unlike
//    the color sample). aspect = fullResolution.x / fullResolution.y.
//  * Loop bounds inclusive exactly as written: pass 1 [-1,1]x[-1,1], pass 2
//    [-2,2]x[-2,2]. The `all(cellId == nearestCell) continue` skip is reproduced.
//  * step()/min()/max()/floor()/frac()/sin()/dot()/normalize()/abs()/mix map
//    directly; mix(a,b,t) -> lerp(a,b,t). No nm_mod / atan2 / select in this body.
//  * Linear, clamp-to-edge, non-sRGB samplers (H7) — set in CellSplit.shader.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
// Bound by the runtime via MaterialPropertyBlock under these exact names.
int   mode;       // globals.mode.uniform "mode",       default 0 (edges)
float scale;      // globals.scale.uniform "scale",     default 15.0
float edgeWidth;  // globals.edgeWidth.uniform "edgeWidth", default 0.08
int   seed;       // globals.seed.uniform "seed",       default 1
int   invert;     // globals.invert.uniform "invert",   default 0 (sourceA)
float speed;      // globals.speed.uniform "speed",     default 1 (int-typed, used as float)

// Effect-local constant — ported VERBATIM from cellSplit.wgsl `const TAU`.
static const float TAU = 6.28318530718;

// -----------------------------------------------------------------------------
// nm_cellSplit — core per-pixel evaluation. Takes the two already-sampled input
// colors (colorA = inputTex, colorB = tex) and the per-pixel Voronoi coordinate
// `p` (already aspect-corrected and tileOffset-shifted, computed in the frag from
// NM_GlobalCoord). Returns the composited RGBA. Ported VERBATIM from
// cellSplit.wgsl main() lines 54-129.
// -----------------------------------------------------------------------------
float4 nm_cellSplit(float4 colorA, float4 colorB, float2 p)
{
    float spd = floor(speed);
    float2 cellCoord = floor(p);
    float2 cellFract = frac(p);

    // Pass 1: find nearest cell center
    float  d1 = 1e10;
    float2 nearestPoint = float2(0.0, 0.0);
    float2 nearestCell  = float2(0.0, 0.0);
    float  nearestHash  = 0.0;

    for (int y = -1; y <= 1; y = y + 1) {
        for (int x = -1; x <= 1; x = x + 1) {
            float2 neighbor = float2((float)x, (float)y);
            float2 cellId = cellCoord + neighbor;
            float3 rnd = nm_prng(float3(cellId, (float)seed));
            float2 wobble = sin(TAU * time * spd + rnd.xy * TAU) * 0.15 * min(spd, 1.0);
            float2 pt = neighbor + rnd.xy + wobble - cellFract;
            float dist = dot(pt, pt);

            if (dist < d1) {
                d1 = dist;
                nearestPoint = pt;
                nearestCell = cellId;
                nearestHash = rnd.z;
            }
        }
    }

    // Pass 2: find minimum perpendicular distance to any Voronoi edge
    // (bisector between nearest center and each neighbor center)
    float edgeDistVal = 1e10;
    for (int y2 = -2; y2 <= 2; y2 = y2 + 1) {
        for (int x2 = -2; x2 <= 2; x2 = x2 + 1) {
            float2 neighbor = float2((float)x2, (float)y2);
            float2 cellId = cellCoord + neighbor;
            if (all(cellId == nearestCell)) { continue; }
            float3 rnd = nm_prng(float3(cellId, (float)seed));
            float2 wobble = sin(TAU * time * spd + rnd.xy * TAU) * 0.15 * min(spd, 1.0);
            float2 pt = neighbor + rnd.xy + wobble - cellFract;
            // Perpendicular distance to bisector between nearest and this neighbor
            float2 mid = (nearestPoint + pt) * 0.5;
            float2 edge = normalize(pt - nearestPoint);
            float d = abs(dot(mid, edge));
            edgeDistVal = min(edgeDistVal, d);
        }
    }

    float onEdge;
    if (edgeWidth > 0.0) {
        onEdge = step(edgeDistVal, edgeWidth);
    } else {
        onEdge = 0.0;
    }

    float mask;
    if (mode == 0) {
        // Edges mode: cells show A, edges show B
        mask = onEdge;
    } else {
        // Split mode: cells randomly assigned to A or B, edges show 50/50
        float cellChoice = step(0.5, nearestHash);
        if (invert == 1) {
            cellChoice = 1.0 - cellChoice;
        }
        mask = lerp(cellChoice, 0.5, onEdge);
    }

    // Apply invert (in edges mode, swaps cells/edges assignment)
    if (mode == 0 && invert == 1) {
        mask = 1.0 - mask;
    }

    float4 color = lerp(colorA, colorB, mask);
    color.a = max(colorA.a, colorB.a);

    return color;
}

#endif // NM_CELLSPLIT_INCLUDED
