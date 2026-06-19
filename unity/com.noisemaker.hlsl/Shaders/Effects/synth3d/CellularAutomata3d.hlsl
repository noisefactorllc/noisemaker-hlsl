#ifndef NM_EFFECT_CELLULARAUTOMATA3D_INCLUDED
#define NM_EFFECT_CELLULARAUTOMATA3D_INCLUDED

// =============================================================================
// CellularAutomata3d.hlsl — synth3d/cellularAutomata3d (func: "cellularAutomata3d")
//
// 3D cellular-automata volume simulation. Ported PIXEL-IDENTICALLY from the
// canonical WGSL source (top-left origin, no per-effect Y flip):
//   wgsl/simulate.wgsl   progName "simulate"   (frag_simulate)
//
// 3D / VOLUME-WRITE TIER (reference 04 §8, reference 10 §3.7/§4.2):
//   This is a synth3d GENERATOR. It WRITES a 2D ATLAS RenderTexture that encodes
//   a 3D voxel volume. The atlas is (volumeSize) wide by (volumeSize^2) tall:
//   volumeSize Z-slices of (volumeSize x volumeSize) stacked vertically. Each
//   atlas texel (u, v) maps to voxel (x, y, z) via:
//       x = u
//       y = v % volumeSize
//       z = v / volumeSize     (integer divide)
//   and the inverse (voxel -> atlas) is atlasTexel():
//       atlas.x = wrap(x), atlas.y = wrap(y) + wrap(z) * volumeSize
//   with wrap(c) = (c + volumeSize) % volumeSize (periodic boundary). This is
//   reproduced EXACTLY below; getting the atlas mapping wrong scrambles the
//   volume. NOTE: definition.js's volumeCache/geoBuffer/global_ca_state declare
//   width={param volumeSize, default 32}, height={param volumeSize, power 2,
//   default 1024}. The pass viewport matches (volumeSize x volumeSize^2). At the
//   default volumeSize=32 the atlas is 32x1024 (NOT the generic 64x4096 vol*
//   surface — this effect uses param-sized internal/global atlases). The
//   downstream render3d/renderLit3d raymarches this atlas; this effect does NOT
//   raymarch — it only steps the CA.
//
// MULTI-FRAME FEEDBACK: 1 pass per frame. The persistent ('global_') state atlas
//   global_ca_state (r=alive, g=age, b=alive, a=1) is BOTH the pass input
//   (stateTex) and output. The runtime ping-pongs it across frames so each frame
//   reads the previous frame's volume (reference 04 §10.2/§10.7; isStateSurface
//   matches because the name contains "state"/"ca_state"). seedTex is the
//   upstream 'source' volume (inputTex3d) used only for first-frame / reset
//   seeding and optional weight blending. NO MRT (single fragColor). NO repeat.
//
// NOTE: 3D / multi-frame / atlas effect -> ships as a runtime-rendered Texture2D
//   atlas. No Shader Graph Custom Function wrapper is provided (SKIPPED per the
//   porting brief: 3D/multi-pass/atlas-write cannot be expressed as a stateless
//   generator node).
//
// PORTING-GUIDE / parity notes:
//  * WGSL textureLoad(t, coord, 0) -> t.Load(int3(coord, 0)) (integer texel
//    fetch, point, no filtering). State + seed atlases are rgba16f, read this
//    way. The GLSL twin uses texelFetch(t, coord, 0) — identical point fetch.
//  * fragCoord: WGSL @builtin(position).xy is top-left, +0.5 centered. The
//    reference does vec2<i32>(position.xy) which truncates the +0.5 center to the
//    integer pixel index. NM_FragCoord(i) reproduces position.xy; (int2) then
//    truncates -> the exact integer pixelCoord. // TODO(verify): confirm no Y
//    flip is needed for the atlas-write path on the target API (atlas rows are
//    Z-slices; a vertical flip would reorder slices). Ported from WGSL so should
//    need none, but this is a volume-write — validate against a reference atlas.
//  * int % : WGSL '%' truncates toward zero; HLSL '%' matches. atlasTexel adds
//    + volSize before % so operands are non-negative (periodic wrap) — exact.
//  * mix -> lerp, fract -> frac, min/length/dot kept verbatim. nm_mod NOT used
//    (the wrapping here is integer %, not float modulo).
//  * Booleans (resetState) arrive as float compared per the reference: the WGSL
//    declares resetState:i32 and tests 'resetState != 0'. We declare an int and
//    test '!= 0' to match the WGSL exactly. Other ints (volumeSize, seed,
//    ruleIndex, neighborMode) are int uniforms (i32(float) truncation parity).
//  * speed/density/weight are float uniforms (WGSL: f32). hash3 takes s = f32(seed).
//  * Helpers (hash3/atlasTexel/sampleState/sampleSeed/countMooreNeighbors/
//    countVonNeumannNeighbors/shouldBeBorn/shouldSurvive) ported verbatim,
//    inline. NONE come from NMCore (pcg/prng/random/nm_mod unused here).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input atlases (rebound by runtime per definition.js passes[].inputs) ----
// simulate: stateTex (global_ca_state, Load), seedTex ('source' volume, Load).
Texture2D    stateTex;   SamplerState sampler_stateTex;
Texture2D    seedTex;    SamplerState sampler_seedTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
int   volumeSize;     // globals.volumeSize   default 32
int   seed;           // globals.seed         default 1
int   ruleIndex;      // globals.ruleIndex    default 0
int   neighborMode;   // globals.neighborMode default 0
float speed;          // globals.speed        default 1   (WGSL f32)
float density;        // globals.density      default 50
float weight;         // globals.weight       default 0
int   resetState;     // globals.resetState   boolean (1/0), tested != 0

// =============================================================================
// PASS: simulate — step the 3D CA volume atlas (frag_simulate)
// =============================================================================

// Hash for initialization (verbatim from WGSL hash3; the WGSL passes s = f32(seed)).
float ca_hash3(float3 p, float s)
{
    float3 pp = p + s * 0.1;
    pp = frac(pp * float3(0.1031, 0.1030, 0.0973));
    pp = pp + dot(pp, pp.yxz + 33.33);
    return frac((pp.x + pp.y) * pp.z);
}

// 3D voxel coords -> 2D atlas texel coords with periodic wrapping (verbatim).
int2 ca_atlasTexel(int3 p, int volSize)
{
    int3 wrapped = int3(
        (p.x + volSize) % volSize,
        (p.y + volSize) % volSize,
        (p.z + volSize) % volSize
    );
    return int2(wrapped.x, wrapped.y + wrapped.z * volSize);
}

float4 ca_sampleState(int3 voxel, int volSize)
{
    return stateTex.Load(int3(ca_atlasTexel(voxel, volSize), 0));
}

float4 ca_sampleSeed(int3 voxel, int volSize)
{
    return seedTex.Load(int3(ca_atlasTexel(voxel, volSize), 0));
}

// Moore neighborhood (26 neighbors). Loop bounds inclusive (-1..1), verbatim.
int ca_countMooreNeighbors(int3 voxel, int volSize)
{
    int count = 0;
    for (int dz = -1; dz <= 1; dz = dz + 1)
    {
        for (int dy = -1; dy <= 1; dy = dy + 1)
        {
            for (int dx = -1; dx <= 1; dx = dx + 1)
            {
                if (dx == 0 && dy == 0 && dz == 0) { continue; }
                float4 neighbor = ca_sampleState(voxel + int3(dx, dy, dz), volSize);
                if (neighbor.r > 0.5) { count = count + 1; }
            }
        }
    }
    return count;
}

// Von Neumann neighborhood (6 neighbors), verbatim.
int ca_countVonNeumannNeighbors(int3 voxel, int volSize)
{
    int count = 0;
    float4 xp = ca_sampleState(voxel + int3(1, 0, 0), volSize);
    float4 xn = ca_sampleState(voxel + int3(-1, 0, 0), volSize);
    float4 yp = ca_sampleState(voxel + int3(0, 1, 0), volSize);
    float4 yn = ca_sampleState(voxel + int3(0, -1, 0), volSize);
    float4 zp = ca_sampleState(voxel + int3(0, 0, 1), volSize);
    float4 zn = ca_sampleState(voxel + int3(0, 0, -1), volSize);

    if (xp.r > 0.5) { count = count + 1; }
    if (xn.r > 0.5) { count = count + 1; }
    if (yp.r > 0.5) { count = count + 1; }
    if (yn.r > 0.5) { count = count + 1; }
    if (zp.r > 0.5) { count = count + 1; }
    if (zn.r > 0.5) { count = count + 1; }

    return count;
}

// Born / survive rule tables (verbatim; preserve operator grouping exactly).
bool ca_shouldBeBorn(int n, int rule)
{
    if (rule == 0) { return n == 4; }                                   // 445M
    if (rule == 1) { return n >= 6 && n <= 8; }                         // 678
    if (rule == 2) { return n >= 9; }                                   // Amoeba
    if (rule == 3) { return n == 4 || n == 6 || n == 8 || n == 9; }     // Builder1
    if (rule == 4) { return n == 3; }                                   // Builder2 (3D Life)
    if (rule == 5) { return n >= 13; }                                  // Clouds
    if (rule == 6) { return n == 1 || n == 3; }                         // Crystal
    if (rule == 7) { return (n >= 5 && n <= 7) || n == 12; }            // Diamoeba
    if (rule == 8) { return n >= 4 && n <= 7; }                         // Pyroclastic
    if (rule == 9) { return n == 4; }                                   // Slow Decay
    if (rule == 10) { return n >= 5 && n <= 8; }                        // Spikey
    return false;
}

bool ca_shouldSurvive(int n, int rule)
{
    if (rule == 0) { return n == 4; }                                              // 445M
    if (rule == 1) { return n >= 6 && n <= 8; }                                    // 678
    if (rule == 2) { return (n >= 5 && n <= 7) || n == 12 || n == 13 || n == 15; } // Amoeba
    if (rule == 3) { return (n >= 3 && n <= 6) || n == 9; }                        // Builder1
    if (rule == 4) { return n == 2 || n == 3; }                                    // Builder2 (3D Life)
    if (rule == 5) { return n >= 13; }                                             // Clouds
    if (rule == 6) { return n == 1 || n == 2 || n == 4; }                          // Crystal
    if (rule == 7) { return n >= 5 && n <= 8; }                                    // Diamoeba
    if (rule == 8) { return n >= 6 && n <= 8; }                                    // Pyroclastic
    if (rule == 9) { return n == 3 || n == 4; }                                    // Slow Decay
    if (rule == 10) { return n == 5 || n == 6 || n == 9; }                         // Spikey
    return false;
}

float4 frag_simulate(NMVaryings i) : SV_Target
{
    int volSize = volumeSize;
    float volSizeF = (float)volSize;

    // Decode voxel position from atlas. WGSL: vec2<i32>(position.xy) truncates
    // the +0.5 pixel center to the integer pixel index.
    int2 pixelCoord = int2(NM_FragCoord(i));
    int x = pixelCoord.x;
    int y = pixelCoord.y % volSize;
    int z = pixelCoord.y / volSize;
    int3 voxel = int3(x, y, z);

    // Bounds check.
    if (x >= volSize || y >= volSize || z >= volSize)
    {
        return float4(0.0, 0.0, 0.0, 0.0);
    }

    // Current state.
    float4 state = ca_sampleState(voxel, volSize);
    float alive = state.r;
    float age = state.g;

    // Self-initialization or reset: empty buffer (first frame) or reset button.
    bool bufferIsEmpty = (state.r == 0.0 && state.g == 0.0 && state.b == 0.0 && state.a == 0.0);

    if (bufferIsEmpty || resetState != 0)
    {
        // Check for input from seedTex (inputTex3d).
        float4 seedVal = ca_sampleSeed(voxel, volSize);
        bool hasSeedInput = (seedVal.r > 0.0 || seedVal.g > 0.0 || seedVal.b > 0.0);

        if (hasSeedInput)
        {
            // Seed texture luminance determines initial alive state.
            float lum = 0.299 * seedVal.r + 0.587 * seedVal.g + 0.114 * seedVal.b;
            if (lum > 0.5)
            {
                alive = 1.0;
            }
            else
            {
                alive = 0.0;
            }
            age = 0.0;
        }
        else
        {
            // Random sparse distribution.
            float3 p = float3((float)x, (float)y, (float)z);
            float h = ca_hash3(p, (float)seed);
            float thresh = density * 0.01;

            // Seed a sphere in the center plus random cells.
            float3 center = float3(volSizeF * 0.5, volSizeF * 0.5, volSizeF * 0.5);
            float dist = length(p - center);
            float radius = volSizeF * 0.15;

            if (h < thresh || dist < radius)
            {
                alive = 1.0;
                age = 0.0;
            }
            else
            {
                alive = 0.0;
                age = 0.0;
            }
        }

        return float4(alive, alive, alive, 1.0);
    }

    // Count neighbors by neighborhood mode.
    int neighbors;
    if (neighborMode == 0)
    {
        neighbors = ca_countMooreNeighbors(voxel, volSize);
    }
    else
    {
        neighbors = ca_countVonNeumannNeighbors(voxel, volSize);
    }

    // Apply CA rules.
    float newAlive = 0.0;
    float newAge = age;

    if (alive > 0.5)
    {
        // Alive — check survival.
        if (ca_shouldSurvive(neighbors, ruleIndex))
        {
            newAlive = 1.0;
            newAge = min(age + 0.01, 1.0);  // Age increases while alive.
        }
        else
        {
            newAlive = 0.0;
            newAge = 0.0;
        }
    }
    else
    {
        // Dead — check birth.
        if (ca_shouldBeBorn(neighbors, ruleIndex))
        {
            newAlive = 1.0;
            newAge = 0.0;
        }
        else
        {
            newAlive = 0.0;
            newAge = 0.0;
        }
    }

    // Speed control — interpolate between states.
    float animSpeed = speed * 0.01;
    float finalAlive = lerp(alive, newAlive, animSpeed);
    float finalAge = lerp(age, newAge, animSpeed);

    // Input weight blending from seedTex (inputTex3d).
    if (weight > 0.0)
    {
        float4 seedVal = ca_sampleSeed(voxel, volSize);
        float seedLum = 0.299 * seedVal.r + 0.587 * seedVal.g + 0.114 * seedVal.b;
        finalAlive = lerp(finalAlive, seedLum, weight * 0.01);
    }

    return float4(finalAlive, finalAlive, finalAlive, 1.0);
}

#endif // NM_EFFECT_CELLULARAUTOMATA3D_INCLUDED
