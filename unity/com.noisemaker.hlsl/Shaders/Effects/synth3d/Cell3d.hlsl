#ifndef NM_EFFECT_CELL3D_INCLUDED
#define NM_EFFECT_CELL3D_INCLUDED

// =============================================================================
// Cell3d.hlsl — synth3d/cell3d (func: "cell3d")
//
// 3D cellular/Voronoi noise VOLUME GENERATOR. Ported PIXEL-IDENTICALLY from the
// canonical WGSL source (top-left origin, no per-effect Y flip):
//   wgsl/precompute.wgsl   progName "precompute"   (frag_precompute)
//
// VOLUME-WRITE / MRT (drawBuffers:2). This is a 3D generator: it WRITES a 3D
// voxel field stored as a 2D ATLAS. The render target is the canonical vol
// surface — a 64x4096 rgba16f atlas = 64 slices of 64x64 (reference 04 §8.4),
// here parameterized by `volumeSize` (atlas = volumeSize x volumeSize^2). One
// fullscreen fragment maps atlas pixel (x,y) -> voxel (x, y%volSize, y/volSize),
// evaluates 3D Worley/cell noise at the voxel, and emits TWO MRT attachments:
//   SV_Target0 color  -> volumeCache (vol surface): density + cell colors
//   SV_Target1 geoOut -> geoBuffer   (geo surface): xyz=encoded normal, w=depth
// Slot order MUST match definition.js passes[0].outputs{} insertion order
// (color, geoOut). The downstream render3d/renderLit3d effect RAYMARCHES this
// atlas into a 2D image; this effect only fills the atlas. No raymarch here.
//
// NOTE: 3D / multi-output volume-write effect → ships as a runtime-rendered
// volume texture (atlas). NO Shader Graph Custom Function wrapper is provided
// (the C# runtime drives the volume-write pass and binds the vol/geo surfaces).
//
// PORTING-GUIDE / parity notes:
//  * Ported from WGSL (golden rule 1). Where GLSL diverges it is NOT followed:
//      - gradient epsilon: WGSL `eps = 1.0 / volSizeF`  (GLSL uses 0.01/scale).
//      - normal anti-zero seed: WGSL `+ vec3(0.000001)`  (GLSL uses 1e-6).
//    Both divergences are intentional WGSL-fidelity choices. // TODO(verify):
//    confirm reference golden render is the WGSL path (it is the WebGPU source).
//  * position.xy (@builtin(position), top-left, +0.5 centered) -> NM_FragCoord(i).
//  * vec2<i32>(position.xy) truncates the +0.5-centered coord -> int2((int)...);
//    for the non-negative atlas range this yields the integer pixel index, as in
//    the WGSL. pixelCoord.y % volSize and / volSize use int trunc division.
//  * pcg3d: uint wraparound hash, ported verbatim. >> vec3<u32>(16u) -> >> 16u.
//  * hash3: `vec3<u32>(vec3<i32>(ps*1000.0) + 65536)` — the inner cast is a
//    NUMERIC float->int TRUNCATION (NOT asint), then a two's-complement int->uint
//    reinterpret: int3 t = (int3)(ps*1000.0); uint3 q = (uint3)(t + 65536). The
//    +65536 keeps the argument positive across the used range (matches WGSL/GLSL).
//  * PCG-style divisor 4294967295.0 reproduced literally (NOT 2^32).
//  * fract->frac, mix->lerp. nm_mod NOT used (no float modulo in this effect).
//  * Color hash constants (0.0127/0.0231/0.0347) and normalizers (0.866/1.5/0.6)
//    copied literally. Loop bounds inclusive (z<=1,y<=1,x<=1) exactly as written.
//  * Helpers (pcg3d/hash3/cellNoise3D) are ported verbatim, inline, per effect —
//    NONE come from NMCore (cell3d uses its own pcg3d, not the shared pcg).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
// scale (cell scale), seed, metric (cell shape), cellVariation (variation),
// volumeSize (atlas/voxel edge), colorMode. All bound by the runtime via
// MaterialPropertyBlock by these reference names.
float scale;          // globals.scale         default 10   (range 1..15)
int   seed;           // globals.seed          default 1    (range 0..100)
int   metric;         // globals.metric        default 0    (sphere/oct/cube)
float cellVariation;  // globals.variation     default 100  (range 0..100)
int   volumeSize;     // globals.volumeSize    default 64   (16/32/64/128)
int   colorMode;      // globals.colorMode     default 1    (mono=0/rgb=1)

// =============================================================================
// Helpers — ported verbatim from wgsl/precompute.wgsl (cell3d's OWN versions).
// =============================================================================

// PCG-based 3D hash for reproducible randomness.
uint3 cell3d_pcg3d(uint3 v_in)
{
    uint3 v = v_in * 1664525u + 1013904223u;
    v.x = v.x + v.y * v.z;
    v.y = v.y + v.z * v.x;
    v.z = v.z + v.x * v.y;
    v = v ^ (v >> 16u);
    v.x = v.x + v.y * v.z;
    v.y = v.y + v.z * v.x;
    v.z = v.z + v.x * v.y;
    return v;
}

float3 cell3d_hash3(float3 p)
{
    float3 ps = p + (float)seed * 0.1;
    int3   ti = (int3)(ps * 1000.0) + 65536;   // float->int trunc, then +65536
    uint3  q  = cell3d_pcg3d((uint3)ti);        // two's-complement int->uint
    return (float3)q / 4294967295.0;
}

// 3D Worley/Cell noise — returns (distance to nearest cell, cell ID).
float2 cell3d_cellNoise3D(float3 p)
{
    float3 i = floor(p);
    float3 f = frac(p);

    float minDist = 10.0;
    float cellId = 0.0;

    // Search 3x3x3 neighborhood.
    for (int z = -1; z <= 1; z = z + 1)
    {
        for (int y = -1; y <= 1; y = y + 1)
        {
            for (int x = -1; x <= 1; x = x + 1)
            {
                float3 neighbor = float3((float)x, (float)y, (float)z);
                float3 cellPos = i + neighbor;

                float3 randomOffset = cell3d_hash3(cellPos);
                float jitter = cellVariation * 0.01;
                float3 cellPoint = neighbor + lerp(float3(0.5, 0.5, 0.5), randomOffset, jitter);

                float3 diff = cellPoint - f;

                float dist;
                if (metric == 0)
                {
                    dist = length(diff);
                }
                else if (metric == 1)
                {
                    dist = abs(diff.x) + abs(diff.y) + abs(diff.z);
                }
                else
                {
                    dist = max(max(abs(diff.x), abs(diff.y)), abs(diff.z));
                }

                if (dist < minDist)
                {
                    minDist = dist;
                    cellId = cellPos.x * 73.0 + cellPos.y * 157.0 + cellPos.z * 311.0;
                }
            }
        }
    }

    return float2(minDist, cellId);
}

// =============================================================================
// PASS: precompute — volume-write, MRT (drawBuffers:2).
// SV_Target0 = color (volumeCache / vol surface),
// SV_Target1 = geoOut (geoBuffer / geo surface).
// Slot order matches definition.js passes[0].outputs{} (color, geoOut).
// =============================================================================
struct Cell3dFragOutput
{
    float4 color  : SV_Target0;   // -> volumeCache (vol)
    float4 geoOut : SV_Target1;   // -> geoBuffer   (geo)
};

Cell3dFragOutput frag_precompute(NMVaryings i)
{
    Cell3dFragOutput o;

    // Use uniform for volume size.
    int   volSize  = volumeSize;
    float volSizeF = (float)volSize;

    // Atlas is volSize x (volSize * volSize). position.xy -> NM_FragCoord(i).
    // Pixel (x, y) maps to 3D coordinate (x, y % volSize, y / volSize).
    float2 fragCoord = NM_FragCoord(i);
    int2 pixelCoord = int2((int)fragCoord.x, (int)fragCoord.y);

    int x = pixelCoord.x;
    int y = pixelCoord.y % volSize;
    int z = pixelCoord.y / volSize;

    // Bounds check.
    if (x >= volSize || y >= volSize || z >= volSize)
    {
        o.color  = float4(0.0, 0.0, 0.0, 0.0);
        o.geoOut = float4(0.5, 0.5, 0.5, 0.0);
        return o;
    }

    // Convert to normalized 3D coordinates in [-1, 1] world space (bounding box).
    // Use (volSizeF - 1.0) so texel 0 -> -1.0 and texel N-1 -> 1.0 exactly.
    float3 p = float3((float)x, (float)y, (float)z) / (volSizeF - 1.0) * 2.0 - 1.0;

    // Scale for cell noise density.
    float3 scaledP = p * (16.0 - scale);

    // Compute cell noise at this point.
    float2 result = cell3d_cellNoise3D(scaledP);
    float dist = result.x;
    float cellId = result.y;

    // Normalize distance based on metric.
    float normalizer;
    if (metric == 0)
    {
        normalizer = 0.866;  // Euclidean
    }
    else if (metric == 1)
    {
        normalizer = 1.5;    // Manhattan
    }
    else
    {
        normalizer = 0.6;    // Chebyshev
    }
    float normalizedDist = 1.0 - clamp(dist / normalizer, 0.0, 1.0);

    // Generate color from cell ID (for RGB mode).
    float h1 = frac(cellId * 0.0127);
    float h2 = frac(cellId * 0.0231);
    float h3 = frac(cellId * 0.0347);

    // Compute analytical gradient using finite differences (WGSL eps).
    float eps = 1.0 / volSizeF;
    float dx = cell3d_cellNoise3D(scaledP + float3(eps, 0.0, 0.0)).x;
    float dy = cell3d_cellNoise3D(scaledP + float3(0.0, eps, 0.0)).x;
    float dz = cell3d_cellNoise3D(scaledP + float3(0.0, 0.0, eps)).x;

    float3 gradient = float3(dx - dist, dy - dist, dz - dist) / eps;
    float3 normal = normalize(-gradient + float3(0.000001, 0.000001, 0.000001));

    // Pack output based on colorMode (0 = mono grayscale, 1 = rgb cell colors).
    float4 color;
    if (colorMode == 0)
    {
        color = float4(normalizedDist, normalizedDist, normalizedDist, 1.0);
    }
    else
    {
        color = float4(normalizedDist, h1, h2, h3);
    }
    float4 geoOut = float4(normal * 0.5 + 0.5, normalizedDist);

    o.color  = color;
    o.geoOut = geoOut;
    return o;
}

#endif // NM_EFFECT_CELL3D_INCLUDED
