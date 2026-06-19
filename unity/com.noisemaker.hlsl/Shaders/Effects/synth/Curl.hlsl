#ifndef NM_CURL_INCLUDED
#define NM_CURL_INCLUDED

// =============================================================================
// Curl.hlsl — synth/curl, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/synth/curl/wgsl/curl.wgsl
//
// 3D curl noise generator (single pass, no inputs). OCTAVES, RIDGES and
// OUTPUT_MODE were compile-time constants in the WGSL/GLSL backends; here they
// are int uniforms branched at runtime with [branch] per PORTING-GUIDE.
//
// All helpers (permute3/4, taylorInvSqrt, simplex3D, fbmSimplex3D,
// curlNoise3D) are VERBATIM INLINE from the WGSL — no shared lib substitution.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
float  scale;       // [0.5, 20]   default 16    (global "scale")
int    seed;        // [0, 1000]   default 0     (global "seed")
float  speed;       // [0, 5]      default 1     (global "speed")
float  intensity;   // [0, 2]      default 1.0   (global "intensity")
// Compile-time defines in WGSL -> runtime int uniforms here. These three are
// DEFINES (definition.js globals.*.define), so the runtime UniformBinder binds
// them via mpb.SetInt(<defineName>, ...) — they MUST be declared by their
// uppercase define name, not the lowercase uniform name, or they never bind
// (octaves=0 -> fbm 0/0 NaN -> whole image breaks).
int    OCTAVES;     // [1, 3]      default 1     (global "octaves", define OCTAVES)
int    RIDGES;      // bool        default 1     (global "ridges",  define RIDGES)
int    OUTPUT_MODE; // [0, 4]      default 3     (global "outputMode", define OUTPUT_MODE)

// ============================================================================
// 3D Simplex Noise Implementation — Stefan Gustavson's implementation
// (verbatim from WGSL; % -> nm_mod; vec3f/4f -> float3/4; i32 -> int etc.)
// ============================================================================

// Permutation polynomial: (34x^2 + 10x) mod 289
float3 nmc_permute3(float3 x)
{
    return nm_mod(((x * 34.0) + 10.0) * x, 289.0);
}

float4 nmc_permute4(float4 x)
{
    return nm_mod(((x * 34.0) + 10.0) * x, 289.0);
}

float4 nmc_taylorInvSqrt(float4 r)
{
    return 1.79284291400159 - 0.85373472095314 * r;
}

// 3D Simplex noise with seed support
float nmc_simplex3D(float3 v)
{
    float2 C = float2(1.0 / 6.0, 1.0 / 3.0);
    float4 D = float4(0.0, 0.5, 1.0, 2.0);

    // Apply seed offset to input
    float3 vSeeded = v + (float)seed * 0.0001;

    // First corner
    float3 i  = floor(vSeeded + dot(vSeeded, C.yyy));
    float3 x0 = vSeeded - i + dot(i, C.xxx);

    // Other corners
    float3 g  = step(x0.yzx, x0.xyz);
    float3 l  = 1.0 - g;
    float3 i1 = min(g.xyz, l.zxy);
    float3 i2 = max(g.xyz, l.zxy);

    float3 x1 = x0 - i1 + C.xxx;
    float3 x2 = x0 - i2 + C.yyy;
    float3 x3 = x0 - D.yyy;

    // Permutations
    float3 iMod = nm_mod(i, 289.0);
    float4 p = nmc_permute4(nmc_permute4(nmc_permute4(
        iMod.z + float4(0.0, i1.z, i2.z, 1.0))
        + iMod.y + float4(0.0, i1.y, i2.y, 1.0))
        + iMod.x + float4(0.0, i1.x, i2.x, 1.0));

    // Gradients: 7x7 points over a square, mapped onto an octahedron
    float  n_  = 0.142857142857; // 1/7
    float3 ns  = n_ * D.wyz - D.xzx;

    float4 j   = p - 49.0 * floor(p * ns.z * ns.z);

    float4 x_  = floor(j * ns.z);
    float4 y_  = floor(j - 7.0 * x_);

    float4 x   = x_ * ns.x + ns.yyyy;
    float4 y   = y_ * ns.x + ns.yyyy;
    float4 h   = 1.0 - abs(x) - abs(y);

    float4 b0  = float4(x.xy, y.xy);
    float4 b1  = float4(x.zw, y.zw);

    float4 s0  = floor(b0) * 2.0 + 1.0;
    float4 s1  = floor(b1) * 2.0 + 1.0;
    float4 sh  = -step(h, (float4)0.0);

    float4 a0  = b0.xzyw + s0.xzyw * sh.xxyy;
    float4 a1  = b1.xzyw + s1.xzyw * sh.zzww;

    float3 p0n = float3(a0.xy, h.x);
    float3 p1n = float3(a0.zw, h.y);
    float3 p2n = float3(a1.xy, h.z);
    float3 p3n = float3(a1.zw, h.w);

    // Normalise gradients
    float4 norm = nmc_taylorInvSqrt(float4(dot(p0n, p0n), dot(p1n, p1n), dot(p2n, p2n), dot(p3n, p3n)));
    p0n = p0n * norm.x;
    p1n = p1n * norm.y;
    p2n = p2n * norm.z;
    p3n = p3n * norm.w;

    // Mix final noise value
    float4 m = max(0.6 - float4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), (float4)0.0);
    m = m * m;
    return 42.0 * dot(m * m, float4(dot(p0n, x0), dot(p1n, x1), dot(p2n, x2), dot(p3n, x3)));
}

// FBM — loop bound is the runtime OCTAVES int (a define in WGSL, bound by the
// UniformBinder via SetInt("OCTAVES",...); declared above by its define name).
float nmc_fbmSimplex3D(float3 p)
{
    float sum    = 0.0;
    float amp    = 1.0;
    float freq   = 1.0;
    float maxAmp = 0.0;

    [loop]
    for (int i = 0; i < OCTAVES; i = i + 1)
    {
        float n  = nmc_simplex3D(p * freq);
        sum      = sum + n * amp;
        maxAmp   = maxAmp + amp;
        freq     = freq * 2.0;
        amp      = amp * 0.5;
    }

    return sum / maxAmp;
}

// ============================================================================
// 3D Curl Noise
// curl(F) = (dFz/dy - dFy/dz, dFx/dz - dFz/dx, dFy/dx - dFx/dy)
// ============================================================================

float3 nmc_curlNoise3D(float3 p)
{
    float eps = 1.0;

    float a = (sin(time * 6.28318) * (speed) + 1.0) / (float)OCTAVES * 0.2;
    float b = (cos(time * 6.28318) * (speed) + 1.0) / (float)OCTAVES * 0.2;

    float3 offset1 = float3(a, b, 0.0);
    float3 offset2 = float3(31.416 - a, 47.853 - b, 12.793);
    float3 offset3 = float3(93.719 - b, 61.248 - a, 73.561);

    // Sample Fx derivatives
    float Fx_py = nmc_fbmSimplex3D(p + float3(0.0, eps, 0.0) - offset1);
    float Fx_ny = nmc_fbmSimplex3D(p - float3(0.0, eps, 0.0) + offset1);
    float Fx_pz = nmc_fbmSimplex3D(p + float3(0.0, 0.0, eps) - offset1);
    float Fx_nz = nmc_fbmSimplex3D(p - float3(0.0, 0.0, eps) + offset1);

    // Sample Fy derivatives
    float Fy_px = nmc_fbmSimplex3D(p + float3(eps, 0.0, 0.0) - offset2);
    float Fy_nx = nmc_fbmSimplex3D(p - float3(eps, 0.0, 0.0) + offset2);
    float Fy_pz = nmc_fbmSimplex3D(p + float3(0.0, 0.0, eps) - offset2);
    float Fy_nz = nmc_fbmSimplex3D(p - float3(0.0, 0.0, eps) + offset2);

    // Sample Fz derivatives
    float Fz_px = nmc_fbmSimplex3D(p + float3(eps, 0.0, 0.0) - offset3);
    float Fz_nx = nmc_fbmSimplex3D(p - float3(eps, 0.0, 0.0) + offset3);
    float Fz_py = nmc_fbmSimplex3D(p + float3(0.0, eps, 0.0) - offset3);
    float Fz_ny = nmc_fbmSimplex3D(p - float3(0.0, eps, 0.0) + offset3);

    // Compute partial derivatives
    float dFx_dy = (Fx_py - Fx_ny) / (2.0 * eps);
    float dFx_dz = (Fx_pz - Fx_nz) / (2.0 * eps);
    float dFy_dx = (Fy_px - Fy_nx) / (2.0 * eps);
    float dFy_dz = (Fy_pz - Fy_nz) / (2.0 * eps);
    float dFz_dx = (Fz_px - Fz_nx) / (2.0 * eps);
    float dFz_dy = (Fz_py - Fz_ny) / (2.0 * eps);

    // curl = (dFz/dy - dFy/dz, dFx/dz - dFz/dx, dFy/dx - dFx/dy)
    return float3(
        dFz_dy - dFy_dz,
        dFx_dz - dFz_dx,
        dFy_dx - dFx_dy
    );
}

// =============================================================================
// nm_curl — core per-pixel evaluation.
// =============================================================================
float4 nm_curl(float2 globalCoord)
{
    float2 uv      = (globalCoord + tileOffset) / fullResolution;
    float  aspect  = fullResolution.x / fullResolution.y;

    // Center and scale coordinates
    float2 centered = (uv - 0.5) * float2(aspect, 1.0);
    float3 p        = float3(centered * (21.0 - scale), 0.5);

    // Compute 3D curl noise
    float3 curlV = nmc_curlNoise3D(p);

    // Smooth compression to [0, 1]
    float3 curlNorm = tanh(curlV * intensity) * 0.5 + 0.5;

    float3 color;

    [branch]
    if (OUTPUT_MODE == 0)
    {
        // flowX: curl.x component
        color = float3(curlNorm.x, curlNorm.x, curlNorm.x);
    }
    else if (OUTPUT_MODE == 1)
    {
        // flowY: curl.y component
        color = float3(curlNorm.y, curlNorm.y, curlNorm.y);
    }
    else if (OUTPUT_MODE == 2)
    {
        // flowZ: curl.z component
        color = float3(curlNorm.z, curlNorm.z, curlNorm.z);
    }
    else if (OUTPUT_MODE == 3)
    {
        // full: all three components as RGB
        color = curlNorm;
    }
    else
    {
        // magnitude: length of curl vector
        float3 curlCentered = curlNorm * 2.0 - 1.0; // back to [-1, 1]
        float  mag          = length(curlCentered);
        color = float3(mag, mag, mag);
    }

    [branch]
    if (RIDGES > 0)
    {
        color = 1.0 - abs(color * 2.0 - 1.0);
    }

    return float4(color, 1.0);
}

#endif // NM_CURL_INCLUDED
