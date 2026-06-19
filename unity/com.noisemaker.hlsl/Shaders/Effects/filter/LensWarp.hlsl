#ifndef NM_EFFECT_LENSWARP_INCLUDED
#define NM_EFFECT_LENSWARP_INCLUDED

// =============================================================================
// LensWarp.hlsl — filter/lensWarp (func: "lensWarp")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/filter/lensWarp/wgsl/lensWarp.wgsl
//
// Noise-driven radial lens distortion. Two independent Perlin-noise fields drive
// X/Y UV displacement, masked toward the frame edges by a pow(5) aspect-correct
// radial singularity mask. UV is wrapped (mirror) and optionally 4-tap
// rotated-grid antialiased. Single render pass.
//
// PORTING-GUIDE notes / hazards handled:
//  * Tile-aware: the WGSL branches on `length(tileOffset) > 0.0`. Both branches
//    are ported verbatim. The non-tiling branch divides by the INPUT texture's
//    own dimensions (textureDimensions(inputTex)); the tiling branch uses
//    fullResolution for the global frame and re-maps to local UV via texSize.
//    `warpedUV` receives `pos.xy` (= NM_FragCoord, local fragcoord, NO tileOffset)
//    and adds tileOffset internally via `originOffset`. So we pass NM_FragCoord(i),
//    NOT NM_GlobalCoord(i).
//  * pcg/prng are the shared NMCore primitives (the WGSL pcg/prng are byte-identical
//    to NMCore, including the /f32(0xffffffff) = /4294967295.0 divisor).
//  * smootherstep/smoothlerp/grid/perlinNoise/warpedUV are this effect's OWN helpers,
//    copied verbatim inline. Do NOT substitute generic versions.
//  * WGSL `select(neg, pos, cond)` in prng -> handled inside nm_prng (NMCore).
//  * WGSL `%` on f32/vec2<f32> is floor-based -> nm_mod (NEVER fmod, H6).
//  * `time` and (engine animation) `speed` are external uniforms in the WGSL
//    (@binding 3/4). `time` is the NMFullscreen alias. `speed` is NOT in
//    definition.js globals; it is the engine oscillator speed. Declared here as a
//    runtime-supplied uniform `speed`.
//    // TODO(verify): confirm the runtime binds `speed` (oscillator speed, default
//    1.0) for effects that read it but do not list it in definition.js globals.
//  * antialias is a boolean in definition.js -> int uniform, tested != 0 ([branch]).
//  * Linear, clamp-to-edge, non-sRGB sampler (H7).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (reference binding: sampler@0, inputTex@1) ------
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
float displacement;  // globals.displacement.uniform, [0,0.25]  default 0.0625
int   antialias;     // globals.antialias.uniform,    boolean   default 1 (true)

// ---- Engine animation uniform (WGSL @binding(4) var<uniform> speed: f32) -----
// Not in definition.js globals; supplied by the runtime (oscillator speed).
float speed;

static const float NM_LENSWARP_PI  = 3.14159265359;
static const float NM_LENSWARP_TAU = 6.28318530718;

// ---- Helpers (verbatim from WGSL) --------------------------------------------

// smootherstep(x) = x*x*x*(x*(x*6-15)+10)
float nm_lensWarp_smootherstep(float x)
{
    return x * x * x * (x * (x * 6.0 - 15.0) + 10.0);
}

// smoothlerp(x,a,b) = a + smootherstep(x)*(b-a)
float nm_lensWarp_smoothlerp(float x, float a, float b)
{
    return a + nm_lensWarp_smootherstep(x) * (b - a);
}

// grid(st, cell, t, spd):
//   angle = prng(vec3(cell, 1.0)).r * TAU
//   angle += t * TAU * spd
//   gradient = vec2(cos(angle), sin(angle))
//   dist = st - cell
//   return dot(gradient, dist)
float nm_lensWarp_grid(float2 st, float2 cell, float t, float spd)
{
    float angle = nm_prng(float3(cell, 1.0)).r * NM_LENSWARP_TAU;
    angle = angle + t * NM_LENSWARP_TAU * spd;
    float2 gradient = float2(cos(angle), sin(angle));
    float2 dist = st - cell;
    return dot(gradient, dist);
}

// perlinNoise(st, noiseScale, t, spd)
float nm_lensWarp_perlinNoise(float2 st_in, float2 noiseScale, float t, float spd)
{
    float2 st = st_in * noiseScale;
    float2 cell = floor(st);
    float tl = nm_lensWarp_grid(st, cell, t, spd);
    float tr = nm_lensWarp_grid(st, float2(cell.x + 1.0, cell.y), t, spd);
    float bl = nm_lensWarp_grid(st, float2(cell.x, cell.y + 1.0), t, spd);
    float br = nm_lensWarp_grid(st, cell + 1.0, t, spd);
    float upper = nm_lensWarp_smoothlerp(st.x - cell.x, tl, tr);
    float lower = nm_lensWarp_smoothlerp(st.x - cell.x, bl, br);
    float val = nm_lensWarp_smoothlerp(st.y - cell.y, upper, lower);
    return val * 0.5 + 0.5;
}

// warpedUV(pos, frame, originOffset, disp, t, spd)
float2 nm_lensWarp_warpedUV(float2 pos, float2 frame, float2 originOffset, float disp, float t, float spd)
{
    // NOTE: `aspectRatio` is a #define macro in NMFullscreen.hlsl; use a local
    // name (`aspect`) to avoid the macro expanding into the declaration.
    float aspect = frame.x / frame.y;
    float2 uv = (pos + originOffset) / frame;
    float2 delta = abs(uv - float2(0.5, 0.5));
    float2 scaled = float2(delta.x * aspect, delta.y);
    float maxRadius = length(float2(aspect * 0.5, 0.5));
    float mask = pow(clamp(length(scaled) / maxRadius, 0.0, 1.0), 5.0);
    float2 noiseCoord = uv * float2(aspect, 1.0);
    float noiseX = nm_lensWarp_perlinNoise(noiseCoord + 42.0, float2(2.0, 2.0), t, spd);
    float noiseY = nm_lensWarp_perlinNoise(noiseCoord + 97.0, float2(2.0, 2.0), t, spd);
    uv.x = uv.x + (noiseX - 0.5) * disp * mask;
    uv.y = uv.y + (noiseY - 0.5) * disp * mask;
    // GLSL: abs(mod(uv + 1.0, 2.0) - 1.0). WGSL emulates GLSL mod via
    // ((x % 2 + 2) % 2); nm_mod is already floor-based (GLSL mod), so a single
    // nm_mod reproduces it exactly (the WGSL double-fold is idempotent here).
    return abs(nm_mod(uv + 1.0, 2.0) - 1.0);
}

// ---- Pass: "lensWarp" (progName "lensWarp") ----------------------------------
float4 NMFrag_lensWarp(NMVaryings i) : SV_Target
{
    // WGSL: texSize = vec2<f32>(textureDimensions(inputTex))
    uint w, h;
    inputTex.GetDimensions(w, h);
    float2 texSize = float2((float)w, (float)h);

    float2 to = tileOffset;
    bool isTile = length(to) > 0.0;
    float t = time;
    float spd = speed;

    float2 fragPos = NM_FragCoord(i);  // WGSL pos.xy (local, +0.5 centered)

    [branch]
    if (isTile)
    {
        // WGSL: fullRes = select(texSize, fullResolution, fullResolution.x > 0.0)
        float2 fullRes = (fullResolution.x > 0.0) ? fullResolution : texSize;
        float maxDisplacementUV = 256.0 / fullRes.x;
        float clampedDisp = clamp(displacement, -maxDisplacementUV, maxDisplacementUV);
        float2 uv = nm_lensWarp_warpedUV(fragPos, fullRes, to, clampedDisp, t, spd);
        float2 localUV = clamp((uv * fullRes - to) / texSize, float2(0.0, 0.0), float2(1.0, 1.0));

        [branch]
        if (antialias != 0)
        {
            float2 dx = ddx(localUV);
            float2 dy = ddy(localUV);
            float4 col = float4(0.0, 0.0, 0.0, 0.0);
            col += inputTex.Sample(sampler_inputTex, localUV + dx * -0.375 + dy * -0.125);
            col += inputTex.Sample(sampler_inputTex, localUV + dx *  0.125 + dy * -0.375);
            col += inputTex.Sample(sampler_inputTex, localUV + dx *  0.375 + dy *  0.125);
            col += inputTex.Sample(sampler_inputTex, localUV + dx * -0.125 + dy *  0.375);
            return col * 0.25;
        }
        return inputTex.Sample(sampler_inputTex, localUV);
    }

    // Non-tiling path: byte-identical to the previous shader.
    float2 uv = nm_lensWarp_warpedUV(fragPos, texSize, float2(0.0, 0.0), displacement, t, spd);
    [branch]
    if (antialias != 0)
    {
        float2 dx = ddx(uv);
        float2 dy = ddy(uv);
        float4 col = float4(0.0, 0.0, 0.0, 0.0);
        col += inputTex.Sample(sampler_inputTex, uv + dx * -0.375 + dy * -0.125);
        col += inputTex.Sample(sampler_inputTex, uv + dx *  0.125 + dy * -0.375);
        col += inputTex.Sample(sampler_inputTex, uv + dx *  0.375 + dy *  0.125);
        col += inputTex.Sample(sampler_inputTex, uv + dx * -0.125 + dy *  0.375);
        return col * 0.25;
    }
    return inputTex.Sample(sampler_inputTex, uv);
}

#endif // NM_EFFECT_LENSWARP_INCLUDED
