#ifndef NM_WOBBLE_INCLUDED
#define NM_WOBBLE_INCLUDED

// =============================================================================
// Wobble.hlsl — filter/wobble, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/wobble/wgsl/wobble.wgsl
//
// Offsets the entire frame using noise-driven jitter. Single render pass
// (definition.js passes[].length == 1, program "wobble").
//
// PORTING-GUIDE notes:
//  * pcg comes from NMCore (nm_pcg) — the ONLY shared primitive. hash31 / noise3d
//    / simplexRandom / applyWrap are this effect's OWN helpers, ported VERBATIM
//    inline here (golden rule 2). Do not substitute generic versions.
//  * hash31 uses ONLY pcg(seed).x (not the full .xyz), divided by 0xffffffffu
//    (= 4294967295.0, NOT 2^32; H11). The sign-fold matches nm_prng exactly but
//    we keep the effect's literal form. uint3(seed) is float->uint TRUNCATION via
//    the WGSL select(...) expressions, NOT asuint.
//  * WGSL select(false_val, true_val, cond) is REVERSED vs HLSL ternary — the
//    select args are translated to `cond ? true_val : false_val` literally.
//  * uv is the fullscreen pass UV (top-left, WGSL convention) — the WGSL samples
//    `in.uv + offset`, NOT fragCoord/texSize. We pass i.uv straight through; no
//    Y flip needed (ported from WGSL). offset uses speed*0.1 added to time and
//    the offsetScale formula r*(0.01 + speed*0.02) verbatim.
//  * wrap: int uniform {mirror:0, repeat:1, clamp:2}. WGSL/GLSL branch chain
//    reproduced with [branch]. Mirror uses the WGSL's explicit floor form, NOT
//    nm_mod, to match the canonical source literally.
//  * Linear, clamp-to-edge, non-sRGB sampler (H7) — set on the SamplerState in
//    Wobble.shader / supplied by the Shader Graph node. (repeat/mirror wrap is
//    emulated in-shader by applyWrap, so the HW sampler stays clamp.)
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
// Bound by the runtime via MaterialPropertyBlock under these exact names.
float speed;   // globals.speed.uniform "speed", default 5.0
float range;   // globals.range.uniform "range", default 0.5
// The reference delivers `wrap` as a FLOAT uniform (wobble.glsl: `uniform float
// wrap;` -> `int mode = int(wrap);`), and the runtime UniformBinder only ever
// writes pass uniforms via MaterialPropertyBlock.SetFloat — an `int wrap;` shader
// constant would therefore stay unset (garbage), breaking the branch. Declare it
// float and truncate in-shader exactly like the GLSL `int(wrap)`.
float wrap;    // globals.wrap.uniform  "wrap",  default 0 (mirror)
// `time` is an engine global aliased by NMFullscreen.

static const float NM_WOBBLE_TAU = 6.28318530717959;
static const float3 NM_WOBBLE_X_NOISE_SEED = float3(17.0, 29.0, 11.0);
static const float3 NM_WOBBLE_Y_NOISE_SEED = float3(41.0, 23.0, 7.0);

// -----------------------------------------------------------------------------
// hash31 — ported VERBATIM from wobble.wgsl. Uses the shared pcg (nm_pcg) but the
// sign-fold + .x extraction + 0xffffffffu divisor are this effect's own form.
// WGSL:
//   let seed = vec3<u32>(
//       u32(select(-p.x * 2.0 + 1.0, p.x * 2.0, p.x >= 0.0)),
//       u32(select(-p.y * 2.0 + 1.0, p.y * 2.0, p.y >= 0.0)),
//       u32(select(-p.z * 2.0 + 1.0, p.z * 2.0, p.z >= 0.0)));
//   return f32(pcg(seed).x) / f32(0xffffffffu);
// select(false, true, cond) -> cond ? true : false.
// -----------------------------------------------------------------------------
float hash31(float3 p)
{
    uint3 seed = uint3(
        (uint)(p.x >= 0.0 ? p.x * 2.0 : -p.x * 2.0 + 1.0),
        (uint)(p.y >= 0.0 ? p.y * 2.0 : -p.y * 2.0 + 1.0),
        (uint)(p.z >= 0.0 ? p.z * 2.0 : -p.z * 2.0 + 1.0)
    );
    return (float)(nm_pcg(seed).x) / (float)(0xffffffffu);
}

// -----------------------------------------------------------------------------
// noise3d — ported VERBATIM from wobble.wgsl. Trilinear value noise on the PCG
// lattice with smoothstep weights. Redundant per-corner hash calls kept literal.
// -----------------------------------------------------------------------------
float noise3d(float3 p)
{
    float3 i = floor(p);
    float3 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);

    float n000 = hash31(i);
    float n100 = hash31(i + float3(1.0, 0.0, 0.0));
    float n010 = hash31(i + float3(0.0, 1.0, 0.0));
    float n110 = hash31(i + float3(1.0, 1.0, 0.0));
    float n001 = hash31(i + float3(0.0, 0.0, 1.0));
    float n101 = hash31(i + float3(1.0, 0.0, 1.0));
    float n011 = hash31(i + float3(0.0, 1.0, 1.0));
    float n111 = hash31(i + float3(1.0, 1.0, 1.0));

    float x0 = lerp(n000, n100, f.x);
    float x1 = lerp(n010, n110, f.x);
    float x2 = lerp(n001, n101, f.x);
    float x3 = lerp(n011, n111, f.x);

    float y0 = lerp(x0, x1, f.y);
    float y1 = lerp(x2, x3, f.y);

    return lerp(y0, y1, f.z);
}

// -----------------------------------------------------------------------------
// simplexRandom — ported VERBATIM from wobble.wgsl. The +spd*0.317/0.519/0.1
// constants are deliberate; reproduce literally (do not reassociate).
// -----------------------------------------------------------------------------
float simplexRandom(float t, float spd, float3 seed)
{
    float angle = t * NM_WOBBLE_TAU;
    // Include speed in the noise coordinates so output varies with speed even at time=0
    float z = cos(angle) * spd + seed.x + spd * 0.317;
    float w = sin(angle) * spd + seed.y + spd * 0.519;
    float n = noise3d(float3(z, w, seed.z + spd * 0.1));
    return clamp(n, 0.0, 1.0);
}

// -----------------------------------------------------------------------------
// applyWrap — ported VERBATIM from wobble.wgsl. Mirror uses the WGSL's explicit
// floor form (NOT nm_mod) to match the canonical source byte-for-byte.
// WGSL:
//   if (wrap == 0) { abs((uv + 1) - floor((uv + 1) * 0.5) * 2 - 1) }   // mirror
//   else if (wrap == 1) { fract(uv) }                                   // repeat
//   else { clamp(uv, 0, 1) }                                            // clamp
// -----------------------------------------------------------------------------
float2 applyWrap(float2 uv)
{
    int mode = (int)wrap;  // GLSL: int mode = int(wrap);
    [branch]
    if (mode == 0) {
        // Mirror: abs(mod(uv + 1, 2) - 1)
        float mx = abs((uv.x + 1.0) - floor((uv.x + 1.0) * 0.5) * 2.0 - 1.0);
        float my = abs((uv.y + 1.0) - floor((uv.y + 1.0) * 0.5) * 2.0 - 1.0);
        return float2(mx, my);
    } else if (mode == 1) {
        return frac(uv);  // repeat
    }
    return clamp(uv, float2(0.0, 0.0), float2(1.0, 1.0));  // clamp
}

// -----------------------------------------------------------------------------
// nm_wobble — core per-pixel evaluation. Computes the noise-driven UV offset and
// returns the sampled input. Ported VERBATIM from wobble.wgsl main().
//   let spd = max(speed, 0.001);
//   let r   = max(range, 0.0);
//   let xRandom = simplexRandom(time + speed * 0.1, spd, X_NOISE_SEED);
//   let yRandom = simplexRandom(time + speed * 0.1, spd, Y_NOISE_SEED);
//   let offsetScale = r * (0.01 + speed * 0.02);
//   let offset = (vec2(xRandom, yRandom) - 0.5) * offsetScale;
//   var sampleCoord = in.uv + offset; sampleCoord = applyWrap(sampleCoord);
//   return textureSample(inputTex, u_sampler, sampleCoord);
// `inUV` is the fullscreen-pass UV (in.uv), top-left, WGSL convention.
// -----------------------------------------------------------------------------
float4 nm_wobble(Texture2D inputTex, SamplerState ss, float2 inUV)
{
    // Speed directly affects the noise sampling position
    // This ensures changing speed produces different noise values
    float spd = max(speed, 0.001);
    float r = max(range, 0.0);

    // Compute jitter offsets - speed affects both the noise input and output scale
    float xRandom = simplexRandom(time + speed * 0.1, spd, NM_WOBBLE_X_NOISE_SEED);
    float yRandom = simplexRandom(time + speed * 0.1, spd, NM_WOBBLE_Y_NOISE_SEED);

    // Scale offset by range - controls displacement amount
    float offsetScale = r * (0.01 + speed * 0.02);
    float2 offset = (float2(xRandom, yRandom) - 0.5) * offsetScale;

    // Apply offset to texture coordinate
    float2 sampleCoord = inUV + offset;
    sampleCoord = applyWrap(sampleCoord);

    float4 sampled = inputTex.Sample(ss, sampleCoord);

    return sampled;
}

#endif // NM_WOBBLE_INCLUDED
