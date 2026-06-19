#ifndef NM_EFFECT_REACTIONDIFFUSION3D_INCLUDED
#define NM_EFFECT_REACTIONDIFFUSION3D_INCLUDED

// =============================================================================
// ReactionDiffusion3d.hlsl — synth3d/reactionDiffusion3d (func: "reactionDiffusion3d")
//
// 3D Gray-Scott reaction-diffusion with a 6-neighbour Laplacian. Self-seeding:
// detects an empty buffer (first frame) and seeds; a reset button reseeds a
// 4x4x4 centre cube. Ported PIXEL-IDENTICALLY from the canonical WGSL source
// (top-left origin, no per-effect Y flip):
//   wgsl/simulate.wgsl   progName "simulate"   (frag_simulate)   repeat:iterations
//
// 3D VOLUME / ATLAS TIER (reference 04 §8, reference 10 §3.7/§4.2):
//   The 3D volume is stored as a 2D ATLAS RenderTexture of size
//   (volumeSize x volumeSize^2) — e.g. 32x1024 at the default volumeSize=32.
//   Layout = volumeSize stacked Z-slices, each volumeSize x volumeSize. The
//   fragment decodes its atlas texel (x,y) -> voxel (x, y%volSize, y/volSize),
//   simulates one Gray-Scott step, and writes the new voxel state back to the
//   SAME atlas. This is NOT a raymarch; it is an atlas-WRITE pass. Downstream
//   render/render3d raymarches the atlas to a 2D image.
//
// STATE / FEEDBACK: single PERSISTENT 'global_' surface global_rd_state
//   (rgba16f). Layout per voxel: .r = chemical B (density, read by render3d),
//   .g/.b = visualization colours, .a = chemical A (sim state). The runtime
//   ping-pongs global_rd_state on every write (within-frame + across frames)
//   and re-runs this single pass repeat:iterations times per frame. There is
//   NO injected iteration index; the shader reads `iterations` only to scale
//   the timestep. seedTex is the upstream 3D input volume atlas (inputTex3d,
//   bound from the `source` vol surface) sampled with the SAME atlas mapping.
//
// NOTE: 3D / multi-pass / atlas-write effect -> ships as a runtime-rendered
//   Texture2D. NO Shader Graph Custom Function wrapper is provided.
//
// PORTING-GUIDE / parity notes:
//  * WGSL textureLoad(t, coord, 0) -> t.Load(int3(coord, 0)) (integer texel
//    fetch, point, no filtering). rgba16f atlas state read this way.
//  * WGSL atlasTexel wraps via `(p + volSize) % volSize`; the offsets feed
//    p in [-1, volSize], so (p+volSize) is non-negative and HLSL `%` (trunc
//    toward zero) reproduces the WGSL `%` exactly. Reproduced literally.
//  * fragCoord = position.xy (@builtin(position), top-left, +0.5 centred) ->
//    NM_FragCoord(i); voxel decode int2(fragCoord) matches vec2<i32>(position.xy).
//  * fract->frac, mix->lerp. No float `mod` used (atlas wrap is integer `%`).
//  * hash3 ported verbatim, inline. NONE of pcg/prng/random from NMCore are
//    used by this effect.
//  * resetState is a boolean uniform (1.0/0.0); WGSL tests `resetState != 0`
//    on an i32 — declared int here and tested `!= 0` identically.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Inputs (runtime rebinds per pass per definition.js inputs{}) -----------
// stateTex = global_rd_state (own previous output, integer Load)
// seedTex  = source vol surface (inputTex3d), integer Load with atlas mapping
Texture2D    stateTex;   SamplerState sampler_stateTex;
Texture2D    seedTex;    SamplerState sampler_seedTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
int   volumeSize;   // globals.volumeSize  default 32
int   seed;         // globals.seed        default 1
float feed;         // globals.feed        default 110
float kill;         // globals.kill        default 62
float rate1;        // globals.rate1       default 120
float rate2;        // globals.rate2       default 30
float speed;        // globals.speed       default 100 (WGSL binds as f32)
float weight;       // globals.weight      default 0
int   iterations;   // globals.iterations  default 8
int   colorMode;    // globals.colorMode   default 0 (mono)
int   resetState;   // globals.resetState  boolean (1/0), tested != 0

// =============================================================================
// Helpers — ported verbatim, inline, from wgsl/simulate.wgsl
// =============================================================================

// Hash for initialization
float rd3_hash3(float3 p, float s)
{
    float3 pp = p + s * 0.1;
    pp = frac(pp * float3(0.1031, 0.1030, 0.0973));
    pp = pp + dot(pp, pp.yxz + 33.33);
    return frac((pp.x + pp.y) * pp.z);
}

// Helper to convert 3D voxel coords to 2D atlas texel coords with wrapping
int2 rd3_atlasTexel(int3 p, int volSize)
{
    // Wrap coordinates for periodic boundary
    int3 wrapped = int3(
        (p.x + volSize) % volSize,
        (p.y + volSize) % volSize,
        (p.z + volSize) % volSize
    );
    return int2(wrapped.x, wrapped.y + wrapped.z * volSize);
}

// Sample state at voxel coordinate with wrapping
float4 rd3_sampleState(int3 voxel, int volSize)
{
    return stateTex.Load(int3(rd3_atlasTexel(voxel, volSize), 0));
}

// Sample seed texture at voxel coordinate (for inputTex3d seeding)
float4 rd3_sampleSeed(int3 voxel, int volSize)
{
    return seedTex.Load(int3(rd3_atlasTexel(voxel, volSize), 0));
}

// 3D Laplacian using 6-neighbor stencil (face neighbors only)
float2 rd3_laplacian3D(int3 voxel, int volSize)
{
    float4 center = rd3_sampleState(voxel, volSize);

    // 6-neighbor stencil (face-adjacent neighbors)
    float4 xp = rd3_sampleState(voxel + int3(1, 0, 0), volSize);
    float4 xn = rd3_sampleState(voxel + int3(-1, 0, 0), volSize);
    float4 yp = rd3_sampleState(voxel + int3(0, 1, 0), volSize);
    float4 yn = rd3_sampleState(voxel + int3(0, -1, 0), volSize);
    float4 zp = rd3_sampleState(voxel + int3(0, 0, 1), volSize);
    float4 zn = rd3_sampleState(voxel + int3(0, 0, -1), volSize);

    // Standard discrete 3D Laplacian: sum of neighbors - 6 * center
    // State layout: .r = B (density), .a = A (chemical)
    float2 neighborSum = xp.ra + xn.ra + yp.ra + yn.ra + zp.ra + zn.ra;
    float2 lap = neighborSum - 6.0 * center.ra;

    return lap;
}

// =============================================================================
// PASS: simulate — one Gray-Scott step over the atlas (frag_simulate)
// repeat: "iterations" — runtime ping-pongs global_rd_state per iteration.
// =============================================================================
float4 frag_simulate(NMVaryings i) : SV_Target
{
    int volSize = volumeSize;
    // (volSizeF unused beyond decode; kept for parity with the WGSL body)

    // Decode voxel position from atlas
    int2 pixelCoord = int2(NM_FragCoord(i));
    int x = pixelCoord.x;
    int y = pixelCoord.y % volSize;
    int z = pixelCoord.y / volSize;
    int3 voxel = int3(x, y, z);

    // Bounds check
    if (x >= volSize || y >= volSize || z >= volSize)
    {
        return float4(0.0, 0.0, 0.0, 0.0);
    }

    // Current state
    float4 state = rd3_sampleState(voxel, volSize);
    float b = state.r;  // Chemical B (density, used by render3d)
    float a = state.a;  // Chemical A (simulation state)

    // Self-initialization: detect empty buffer (first frame) or reset requested
    bool bufferIsEmpty = (state.r == 0.0 && state.g == 0.0 && state.b == 0.0 && state.a == 0.0);

    if (bufferIsEmpty || resetState != 0)
    {
        a = 1.0;
        b = 0.0;

        if (resetState != 0)
        {
            // Reset behavior: reseed a 4x4x4 cube at the center of the volume.
            // For even sizes, this is indices [N/2-2 .. N/2+1] (inclusive).
            int start = max(0, (volSize / 2) - 2);
            int end = min(volSize - 1, start + 3);
            bool inCenterCube = (x >= start && x <= end && y >= start && y <= end && z >= start && z <= end);
            if (inCenterCube) { b = 1.0; }
        }
        else
        {
            // First-frame init: if we have input from seedTex (inputTex3d), use it.
            float4 seedVal = rd3_sampleSeed(voxel, volSize);
            bool hasSeedInput = (seedVal.r > 0.0 || seedVal.g > 0.0 || seedVal.b > 0.0);

            if (hasSeedInput)
            {
                float lum = 0.299 * seedVal.r + 0.587 * seedVal.g + 0.114 * seedVal.b;
                if (lum > 0.5) { b = 1.0; }
            }
            else
            {
                // Fallback: sparse random seeding of B
                float3 p = float3((float)x, (float)y, (float)z);
                if (rd3_hash3(p, (float)seed) > 0.97) { b = 1.0; }
            }
        }

        return float4(b, b, b, a);
    }

    // Compute Laplacian for diffusion
    float2 lap = rd3_laplacian3D(voxel, volSize);

    // Gray-Scott parameters (scaled from UI values)
    // Note: Laplacian in 3D is 6x larger than normalized form,
    // so we scale diffusion rates down by 6 to maintain stability
    float f = feed * 0.001;        // Feed rate
    float k = kill * 0.001;        // Kill rate
    float r1 = rate1 * 0.01 / 6.0; // Diffusion rate A (scaled for 3D)
    float r2 = rate2 * 0.01 / 6.0; // Diffusion rate B (scaled for 3D)
    // This pass is executed `iterations` times per frame (pipeline repeat).
    // Scale timestep per-iteration so "speed" behaves like a per-frame control.
    float iterF = max(1.0, (float)iterations);
    float s = (speed * 0.01) / iterF;

    // Gray-Scott reaction-diffusion equations
    // lap.x = Lap(B) from .r, lap.y = Lap(A) from .a
    float newA = clamp(a + (r1 * lap.y - a * b * b + f * (1.0 - a)) * s, 0.0, 1.0);
    float newB = clamp(b + (r2 * lap.x + a * b * b - (k + f) * b) * s, 0.0, 1.0);

    // Apply input weight blending from seedTex (inputTex3d)
    if (weight > 0.0)
    {
        float4 seedVal = rd3_sampleSeed(voxel, volSize);
        float seedLum = 0.299 * seedVal.r + 0.587 * seedVal.g + 0.114 * seedVal.b;
        // Seed influences chemical B (the visible one)
        newB = lerp(newB, seedLum, weight * 0.01);
    }

    // .r = B (density for render3d), .a = A (simulation state)
    // .rgb = visualization colors, .a = chemical A
    float density = newB;
    float3 outRgb;
    if (colorMode == 0)
    {
        outRgb = float3(density, density, density);
    }
    else
    {
        outRgb = float3(density, newA, 1.0 - density);
    }

    return float4(outRgb, newA);
}

#endif // NM_EFFECT_REACTIONDIFFUSION3D_INCLUDED
