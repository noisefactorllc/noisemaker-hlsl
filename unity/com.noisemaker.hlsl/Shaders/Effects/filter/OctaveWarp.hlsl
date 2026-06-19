#ifndef NM_EFFECT_OCTAVEWARP_INCLUDED
#define NM_EFFECT_OCTAVEWARP_INCLUDED

// =============================================================================
// OctaveWarp.hlsl — filter/octaveWarp (func: "octaveWarp")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/filter/octaveWarp/wgsl/octaveWarp.wgsl
//
// Per-octave noise warp distortion. For each octave i, generates value noise at
// frequency x 2^i, displaces the sample coordinate, and finally samples the
// input at the warped position. Displacement decreases per octave (/ 2^i).
// Single render pass. Optional 4-tap antialiasing using screen-space gradients.
//
// PORTING-GUIDE notes / hazards handled:
//  * WGSL is canonical. The WGSL derives `texSize = textureDimensions(inputTex)`
//    and uses `uv = pos.xy / texSize`, `sampleCoord = uv * texSize` — i.e. ALL
//    coordinates are relative to the INPUT TEXTURE's own size, NOT fullResolution
//    and NOT fullResolution.y. We mirror this exactly: width/height = input dims;
//    `pos.xy` (WGSL @builtin(position), top-left) -> NM_FragCoord(i).
//    (The GLSL instead uses fullResolution + tileOffset; that is the per-tile
//    reconciliation path. Per the guide we follow the WGSL literally.)
//  * `time` engine global is multiplied by the `speed` uniform exactly as WGSL.
//  * PRNG: hash21 uses the shared NMCore PCG (nm_pcg) but with the effect's own
//    sign-fold and seed-as-z lattice; divisor is 0xffffffffu (= 4294967295.0).
//    float->uint here is TRUNCATION ((uint) cast), NOT asuint (H matches WGSL u32).
//  * select(a,b,cond) (WGSL: returns a when cond false, b when true) -> ternary
//    cond ? b : a. Reproduced literally below.
//  * `pow(2.0, f32(octave))` -> pow(2.0, (float)octave) (kept as pow, not exp2).
//  * wrapFloat mirror branch uses the WGSL's explicit floor expansion of mod
//    (NOT nm_mod) because the WGSL itself open-codes it; reproduced verbatim.
//  * antialias: WGSL uses dpdx/dpdy on finalUV -> HLSL ddx/ddy. The tap weights
//    and accumulation order are copied literally.
//  * Linear, clamp-to-edge, non-sRGB sampler (H7) — set in OctaveWarp.shader.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (reference binding: sampler@0, inputTex@1) ------
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
float frequency;     // globals.freq.uniform,         default 2,   [1,10]
int   octaves;       // globals.octaves.uniform,       default 3,   [1,5]
float displacement;  // globals.displacement.uniform,  default 0.2, [0,1]
int   speed;         // globals.speed.uniform,         default 1,   [0,5]
int   seed;          // globals.seed.uniform,          default 1,   [1,100]
int   wrap;          // globals.wrap.uniform,          default 0    {mirror0,repeat1,clamp2}
int   antialias;     // globals.antialias.uniform,     default 1 (true)  bool as int

static const float TAU = 6.28318530717959;

// -----------------------------------------------------------------------------
// hash21 — WGSL:
//   pcg(vec3<u32>( u32(select(-p.x*2+1, p.x*2, p.x>=0)),
//                  u32(select(-p.y*2+1, p.y*2, p.y>=0)),
//                  u32(uniforms.seed) )).x / f32(0xffffffffu)
// select(a,b,c) returns a when c is false, b when c is true -> ternary c ? b : a.
// float->uint via (uint) truncation (matches WGSL u32). Uses shared nm_pcg.
// -----------------------------------------------------------------------------
float nm_octaveWarp_hash21(float2 p)
{
    uint3 v = uint3(
        (uint)(p.x >= 0.0 ? p.x * 2.0 : -p.x * 2.0 + 1.0),
        (uint)(p.y >= 0.0 ? p.y * 2.0 : -p.y * 2.0 + 1.0),
        (uint)seed
    );
    return (float)(nm_pcg(v).x) / (float)(0xffffffffu);
}

// -----------------------------------------------------------------------------
// noise — value noise with smoothstep interpolation (verbatim from WGSL).
// -----------------------------------------------------------------------------
float nm_octaveWarp_noise(float2 p)
{
    float2 i = floor(p);
    float2 f = frac(p);
    float2 ff = f * f * (3.0 - 2.0 * f);

    float a = nm_octaveWarp_hash21(i);
    float b = nm_octaveWarp_hash21(i + float2(1.0, 0.0));
    float c = nm_octaveWarp_hash21(i + float2(0.0, 1.0));
    float d = nm_octaveWarp_hash21(i + float2(1.0, 1.0));

    return lerp(lerp(a, b, ff.x), lerp(c, d, ff.x), ff.y);
}

// -----------------------------------------------------------------------------
// simplexNoise — multi-octave noise on a circular path (verbatim from WGSL).
// phase offsets the angle per octave; radius scales the circular path.
// -----------------------------------------------------------------------------
float nm_octaveWarp_simplexNoise(float2 p, float t, float phase, float radius)
{
    float angle = t * TAU + phase;
    float cx = cos(angle) * radius;
    float cy = sin(angle) * radius;
    float n = nm_octaveWarp_noise(p + float2(cx, cy));
    n = n + nm_octaveWarp_noise(p * 2.0 + float2(-cy, cx) * 0.75) * 0.5;
    n = n + nm_octaveWarp_noise(p * 4.0 + float2(cx, -cy) * 0.5) * 0.25;
    return n / 1.75;
}

// -----------------------------------------------------------------------------
// wrapFloat — WGSL verbatim. mode: 0=mirror, 1=repeat, 2(default)=clamp.
// Mirror branch open-codes the periodic reduction (matches WGSL, NOT nm_mod).
// NOTE: clamp branch clamps `value` (the raw coordinate) to [0, limit] — copied
// literally from the WGSL (the WGSL clamps `value`, not `norm*limit`).
// -----------------------------------------------------------------------------
float nm_octaveWarp_wrapFloat(float value, float limit, int mode)
{
    if (limit <= 0.0)
    {
        return 0.0;
    }
    float norm = value / limit;
    if (mode == 0)
    {
        // Mirror: abs(mod(norm + 1, 2) - 1) * limit
        float m = (norm + 1.0) - floor((norm + 1.0) * 0.5) * 2.0;
        return abs(m - 1.0) * limit;
    }
    else if (mode == 1)
    {
        // Repeat
        return (norm - floor(norm)) * limit;
    }
    // Clamp
    return clamp(value, 0.0, limit);
}

// =============================================================================
// nm_octaveWarp_warpCoord — runs the per-octave warp loop, returning the final
// 0..1 UV at which to sample the input. Mirrors WGSL main() up to finalUV.
// =============================================================================
float2 nm_octaveWarp_warpCoord(float2 fragPos, float2 texSize)
{
    float width = texSize.x;
    float height = texSize.y;

    // Adjust frequency for aspect ratio
    float baseFreq = 11.0 - frequency;
    float aspect = width / height;
    float2 freq = float2(baseFreq, baseFreq);
    if (aspect > 1.0)
    {
        freq.y = freq.y * aspect;
    }
    else
    {
        freq.x = freq.x / aspect;
    }

    float2 uv = fragPos / texSize;
    float2 sampleCoord = uv * texSize;

    int numOctaves = max((int)octaves, 1);
    float displaceBase = displacement;

    // Per-octave warping
    [loop]
    for (int octave = 1; octave <= 10; octave = octave + 1)
    {
        if (octave > numOctaves)
        {
            break;
        }

        float multiplier = pow(2.0, (float)octave);
        float2 freqScaled = freq * 0.5 * multiplier;

        if (freqScaled.x >= width || freqScaled.y >= height)
        {
            break;
        }

        // Per-octave phase and radius break up uniform circular motion
        float phase = (float)octave * 2.399;  // golden angle
        float radius = 0.5 / sqrt(multiplier);

        // Compute reference angles from noise
        float2 noiseCoord = (sampleCoord / texSize) * freqScaled;
        float refX = nm_octaveWarp_simplexNoise(noiseCoord + float2(17.0, 29.0), time * (float)speed, phase, radius) * 2.0 - 1.0;
        float refY = nm_octaveWarp_simplexNoise(noiseCoord + float2(23.0, 31.0), time * (float)speed, phase, radius) * 2.0 - 1.0;

        // Calculate displacement (decreases with each octave)
        float displaceScale = displaceBase / multiplier;
        float2 offset = float2(refX * displaceScale * width, refY * displaceScale * height);

        sampleCoord = sampleCoord + offset;
        sampleCoord = float2(
            nm_octaveWarp_wrapFloat(sampleCoord.x, width, (int)wrap),
            nm_octaveWarp_wrapFloat(sampleCoord.y, height, (int)wrap)
        );
    }

    float2 finalUV = float2(
        nm_octaveWarp_wrapFloat(sampleCoord.x, width, (int)wrap),
        nm_octaveWarp_wrapFloat(sampleCoord.y, height, (int)wrap)
    ) / texSize;

    return finalUV;
}

// ---- Pass: "octaveWarp" (progName "octaveWarp") ------------------------------
float4 NMFrag_octaveWarp(NMVaryings i) : SV_Target
{
    // WGSL: texSize = vec2<f32>(textureDimensions(inputTex));
    //       uv = pos.xy / texSize;  (pos = @builtin(position), top-left)
    uint w, h;
    inputTex.GetDimensions(w, h);
    float2 texSize = float2((float)w, (float)h);

    float2 finalUV = nm_octaveWarp_warpCoord(NM_FragCoord(i), texSize);

    if (antialias != 0)
    {
        float2 dx = ddx(finalUV);
        float2 dy = ddy(finalUV);
        float4 col = float4(0.0, 0.0, 0.0, 0.0);
        col += inputTex.Sample(sampler_inputTex, finalUV + dx * -0.375 + dy * -0.125);
        col += inputTex.Sample(sampler_inputTex, finalUV + dx *  0.125 + dy * -0.375);
        col += inputTex.Sample(sampler_inputTex, finalUV + dx *  0.375 + dy *  0.125);
        col += inputTex.Sample(sampler_inputTex, finalUV + dx * -0.125 + dy *  0.375);
        return col * 0.25;
    }
    else
    {
        return inputTex.Sample(sampler_inputTex, finalUV);
    }
}

#endif // NM_EFFECT_OCTAVEWARP_INCLUDED
