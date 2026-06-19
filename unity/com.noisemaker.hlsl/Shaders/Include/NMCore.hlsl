#ifndef NM_CORE_INCLUDED
#define NM_CORE_INCLUDED

// =============================================================================
// NMCore.hlsl — bit-exact shared primitives for the Noisemaker HLSL engine.
//
// These are the ONLY math primitives that are genuinely invariant across all
// reference effects and may be shared. Reference spec 08 (math-primitives)
// established that most same-named helpers (hsv2rgb, distance metrics, rotate2D)
// are subtly DIFFERENT per effect — those MUST be ported inline per-effect and
// must NOT be hoisted here. Only PCG/prng/random + a few exact utilities live
// here, because they are algorithmically identical in all 76 reference copies.
//
// Source of truth: shaders/effects/synth/noise/wgsl/noise.wgsl (and the
// riccardoscalco PCG-3D, MIT). WGSL is the canonical reference (top-left/D3D,
// matching Unity HLSL). See PORTING-GUIDE.md for the full translation rulebook.
//
// PARITY: compile everything as full 32-bit float. Do NOT let Unity downgrade
// to half/min16float (#pragma below). uint arithmetic wraps mod 2^32 in HLSL,
// matching GLSL `uint`/WGSL `u32`.
// =============================================================================

// Forbid half-precision promotion of these computations.
// (Effects that include this also declare `#pragma exclude_renderers gles` etc.
//  in their .shader where appropriate.)

#define NM_PI  3.14159265359
#define NM_TAU 6.28318530718

// -----------------------------------------------------------------------------
// PCG 3D PRNG (riccardoscalco/glsl-pcg-prng, MIT). Identical in all references.
//   uvec3 pcg(uvec3 v){ v=v*1664525u+1013904223u; v.x+=v.y*v.z; ...; v^=v>>16u; ... }
// All ops are unsigned 32-bit wraparound. HLSL `uint` matches GLSL/WGSL exactly.
// -----------------------------------------------------------------------------
uint3 nm_pcg(uint3 v)
{
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return v;
}

// prng(vec3 p): sign-fold each component into magnitude, hash, normalise by
// 0xffffffff (= 4294967295.0, NOT 2^32). `uint3(p)` is float->uint TRUNCATION
// toward zero (HLSL (uint3) cast), NOT asuint (bit-reinterpret).
float3 nm_prng(float3 p)
{
    p.x = p.x >= 0.0 ? p.x * 2.0 : -p.x * 2.0 + 1.0;
    p.y = p.y >= 0.0 ? p.y * 2.0 : -p.y * 2.0 + 1.0;
    p.z = p.z >= 0.0 ? p.z * 2.0 : -p.z * 2.0 + 1.0;
    return float3(nm_pcg((uint3)p)) / 4294967295.0;
}

// random(vec2 st) = prng(vec3(st, 0.0)).x
float nm_random(float2 st)
{
    return nm_prng(float3(st, 0.0)).x;
}

// -----------------------------------------------------------------------------
// Exact float modulo matching GLSL `mod` (result has sign of divisor).
// NEVER use HLSL `fmod` for ported `mod()` calls — fmod truncates toward zero
// and yields the wrong sign (PORTING-GUIDE H6).
// -----------------------------------------------------------------------------
float  nm_mod(float a,  float b)  { return a - b * floor(a / b); }
float2 nm_mod(float2 a, float2 b) { return a - b * floor(a / b); }
float3 nm_mod(float3 a, float3 b) { return a - b * floor(a / b); }
float4 nm_mod(float4 a, float4 b) { return a - b * floor(a / b); }

// positiveModulo on ints: GLSL/WGSL/HLSL `%` all truncate toward zero, then
// the +modulus fix makes negatives positive. modulus==0 returns 0.
int nm_positiveModulo(int value, int modulus)
{
    if (modulus == 0) return 0;
    int r = value % modulus;
    return r < 0 ? r + modulus : r;
}

// map(v,inMin,inMax,outMin,outMax) — affine remap (no clamp), as in references.
float nm_map(float v, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (v - inMin) / (inMax - inMin);
}

// periodicFunction(p) = map(cos(p*TAU), -1, 1, 0, 1) = (cos(p*TAU)+1)*0.5
float nm_periodicFunction(float p)
{
    return (cos(p * NM_TAU) + 1.0) * 0.5;
}

// =============================================================================
// Coordinate convention helpers. CANONICAL ORIGIN = WGSL/WebGPU (top-left),
// which matches Unity/D3D SV_Position. Effects ported from WGSL therefore need
// NO per-effect Y flip. The single Y reconciliation happens at the present blit
// (see NMBlit.shader) exactly where the reference WGSL blit does (1.0 - uv.y).
//
// _NM_Resolution / _NM_FullResolution / _NM_TileOffset are bound by the runtime
// (see UniformPacker). Effects compute fragCoord from the fullscreen UV so the
// orientation is controlled in ONE place (NMFullscreen.hlsl), not via the
// platform-dependent SV_Position.
//
// NM_FLIP_Y: set 1 to mirror vertically if the parity harness reveals a flip on
// a given Unity graphics API. Default 0 (port-from-WGSL, top-left).
// =============================================================================
#ifndef NM_FLIP_Y
#define NM_FLIP_Y 0
#endif

#endif // NM_CORE_INCLUDED
