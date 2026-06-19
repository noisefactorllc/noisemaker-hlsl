#ifndef NM_NOISE3D_INCLUDED
#define NM_NOISE3D_INCLUDED

// =============================================================================
// Noise3d.hlsl — classicNoisedeck/noise3d, ported PIXEL-IDENTICALLY from the
// canonical WGSL source:
//   shaders/effects/classicNoisedeck/noise3d/wgsl/noise3d.wgsl
//
// Generator (no texture inputs). Single render pass. Ray-marches 3D noise
// volumes (simplex / cellular / voronoi / sine / spheres / cubes / wavy planes)
// and colorizes by mode (grayscale / hsv / surface normal / depth) with fog.
//
// Helpers (pcg/prng/random, map_value, smootherstep, smoothabs, voronoi3d,
// cellular, snoise, sine3D, spheres, cubes, hsv2rgb) are ported VERBATIM and
// INLINE per PORTING-GUIDE. This effect inlines its OWN pcg/prng (sign-fold
// variant, /0xffffffff) — reproduced here exactly. hsv2rgb is this effect's own
// branchy variant; do NOT substitute a generic one.
//
// NUMERIC HAZARDS handled:
//  * st = (globalCoord - 0.5*fullResolution) / fullResolution.y  (DIVIDE BY .y)
//  * NOISE_TYPE is a compile-time define in the reference; here it is an int
//    uniform branched at runtime ([branch]) — semantically identical to the
//    WGSL path which keeps all variants.
//  * WGSL select(a,b,c) == HLSL (c ? b : a) — reversed arg order. Reproduced
//    via plain HLSL ternaries with the WGSL truth value preserved.
//  * (uint3)q is float->uint TRUNCATION toward zero (not asuint).
//  * prng divisor 4294967295.0 (= float(0xffffffffu)), NOT 2^32.
//  * snoise(p * scale + f32(seed)) adds a SCALAR to a float3 (broadcast).
//  * `noiseScale` in the WGSL binds the definition.js global `scale` -> the
//    HLSL uniform is named `scale` (matches definition.js globals[*].uniform).
//  * speed is an int uniform (definition.js); cast to float as the WGSL does.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
// Bound by the runtime via MaterialPropertyBlock.
int   NOISE_TYPE;   // global "type".define = "NOISE_TYPE" (enum; default 12)
int   ridges;       // global "ridges" (bool as int; default 0)
int   seed;         // global "seed"   (default 1)
int   speed;        // global "speed"  (default 1)
float scale;        // global "scale"  (WGSL `noiseScale`; default 25)
float offsetX;      // global "offsetX" (default 0)
float offsetY;      // global "offsetY" (default 0)
int   colorMode;    // global "colorMode" (default 6 = hsv)
float hueRotation;  // global "hueRotation" (default 0)
float hueRange;     // global "hueRange" (default 10)

// Local PI/TAU literals exactly as the WGSL declares them.
static const float NM3_PI  = 3.14159265359;
static const float NM3_TAU = 6.28318530718;

// ===== PCG PRNG (verbatim; this WGSL inlines its own copy) ===================
// https://github.com/riccardoscalco/glsl-pcg-prng - MIT License
uint3 nm3_pcg(uint3 v_in)
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

// (uint3)q is float->uint TRUNCATION toward zero (NOT asuint).
float3 nm3_prng(float3 p)
{
    float3 q = p;
    q.x = (q.x < 0.0) ? -q.x * 2.0 + 1.0 : q.x * 2.0;
    q.y = (q.y < 0.0) ? -q.y * 2.0 + 1.0 : q.y * 2.0;
    q.z = (q.z < 0.0) ? -q.z * 2.0 + 1.0 : q.z * 2.0;
    return float3(nm3_pcg((uint3)q)) / 4294967295.0;
}

float nm3_random(float2 st)
{
    return nm3_prng(float3(st, 0.0)).x;
}

// ===== Utility functions =====================================================
float nm3_map_value(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

float nm3_smootherstep(float x)
{
    return x * x * x * (x * (x * 6.0 - 15.0) + 10.0);
}

float nm3_smoothabs(float v, float m)
{
    return sqrt(v * v + m);
}

// ===== 3D Voronoi ============================================================
// https://github.com/MaxBittker/glsl-voronoi-noise - MIT License
// mat2x2<f32>(0.12121212, 0.13131313, -0.13131313, 0.12121212) is COLUMN-MAJOR
// in WGSL. M*v = (col0*v.x + col1*v.y) = (0.12121212*x - 0.13131313*y,
//                                         0.13131313*x + 0.12121212*y).
static const float2 NM3_myt_c0 = float2(0.12121212, 0.13131313);
static const float2 NM3_myt_c1 = float2(-0.13131313, 0.12121212);
static const float2 NM3_mys = float2(1e4, 1e6);

float2 nm3_rhash(float2 uv_in)
{
    // uv = myt * uv_in  (column-major matrix-vector product)
    float2 uv = NM3_myt_c0 * uv_in.x + NM3_myt_c1 * uv_in.y;
    uv = uv * NM3_mys;
    return frac(frac(uv / NM3_mys) * uv);
}

float3 nm3_voronoi3d(float3 x)
{
    float3 p = floor(x);
    float3 f = frac(x);

    float id = 0.0;
    float2 res = float2(100.0, 100.0);

    for (int k = -1; k <= 1; k = k + 1) {
        for (int j = -1; j <= 1; j = j + 1) {
            for (int i = -1; i <= 1; i = i + 1) {
                float3 b = float3((float)i, (float)j, (float)k);
                float3 r = b - f + nm3_prng(p + b);
                float d = dot(r, r);

                float cond = max(sign(res.x - d), 0.0);
                float nCond = 1.0 - cond;

                float cond2 = nCond * max(sign(res.y - d), 0.0);
                float nCond2 = 1.0 - cond2;

                id = (dot(p + b, float3(1.0, 57.0, 113.0)) * cond) + (id * nCond);
                res = float2(d, res.x) * cond + res * nCond;

                res.y = cond2 * d + nCond2 * res.y;
            }
        }
    }

    return float3(sqrt(res), abs(id));
}

// ===== 3D Cellular Noise =====================================================
// Stefan Gustavson - MIT License
float3 nm3_mod289_3(float3 x)
{
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

float3 nm3_mod7(float3 x)
{
    return x - floor(x * (1.0 / 7.0)) * 7.0;
}

float3 nm3_permute_3(float3 x)
{
    return nm3_mod289_3((34.0 * x + 10.0) * x);
}

float2 nm3_cellular(float3 P)
{
    const float K = 0.142857142857;
    const float Ko = 0.428571428571;
    const float K2 = 0.020408163265306;
    const float Kz = 0.166666666667;
    const float Kzo = 0.416666666667;
    const float jitter = 1.0;

    float3 Pi = nm3_mod289_3(floor(P));
    float3 Pf = frac(P) - 0.5;

    float3 Pfx = Pf.x + float3(1.0, 0.0, -1.0);
    float3 Pfy = Pf.y + float3(1.0, 0.0, -1.0);
    float3 Pfz = Pf.z + float3(1.0, 0.0, -1.0);

    float3 p = nm3_permute_3(Pi.x + float3(-1.0, 0.0, 1.0));
    float3 p1 = nm3_permute_3(p + Pi.y - 1.0);
    float3 p2 = nm3_permute_3(p + Pi.y);
    float3 p3 = nm3_permute_3(p + Pi.y + 1.0);

    float3 p11 = nm3_permute_3(p1 + Pi.z - 1.0);
    float3 p12 = nm3_permute_3(p1 + Pi.z);
    float3 p13 = nm3_permute_3(p1 + Pi.z + 1.0);

    float3 p21 = nm3_permute_3(p2 + Pi.z - 1.0);
    float3 p22 = nm3_permute_3(p2 + Pi.z);
    float3 p23 = nm3_permute_3(p2 + Pi.z + 1.0);

    float3 p31 = nm3_permute_3(p3 + Pi.z - 1.0);
    float3 p32 = nm3_permute_3(p3 + Pi.z);
    float3 p33 = nm3_permute_3(p3 + Pi.z + 1.0);

    float3 ox11 = frac(p11 * K) - Ko;
    float3 oy11 = nm3_mod7(floor(p11 * K)) * K - Ko;
    float3 oz11 = floor(p11 * K2) * Kz - Kzo;

    float3 ox12 = frac(p12 * K) - Ko;
    float3 oy12 = nm3_mod7(floor(p12 * K)) * K - Ko;
    float3 oz12 = floor(p12 * K2) * Kz - Kzo;

    float3 ox13 = frac(p13 * K) - Ko;
    float3 oy13 = nm3_mod7(floor(p13 * K)) * K - Ko;
    float3 oz13 = floor(p13 * K2) * Kz - Kzo;

    float3 ox21 = frac(p21 * K) - Ko;
    float3 oy21 = nm3_mod7(floor(p21 * K)) * K - Ko;
    float3 oz21 = floor(p21 * K2) * Kz - Kzo;

    float3 ox22 = frac(p22 * K) - Ko;
    float3 oy22 = nm3_mod7(floor(p22 * K)) * K - Ko;
    float3 oz22 = floor(p22 * K2) * Kz - Kzo;

    float3 ox23 = frac(p23 * K) - Ko;
    float3 oy23 = nm3_mod7(floor(p23 * K)) * K - Ko;
    float3 oz23 = floor(p23 * K2) * Kz - Kzo;

    float3 ox31 = frac(p31 * K) - Ko;
    float3 oy31 = nm3_mod7(floor(p31 * K)) * K - Ko;
    float3 oz31 = floor(p31 * K2) * Kz - Kzo;

    float3 ox32 = frac(p32 * K) - Ko;
    float3 oy32 = nm3_mod7(floor(p32 * K)) * K - Ko;
    float3 oz32 = floor(p32 * K2) * Kz - Kzo;

    float3 ox33 = frac(p33 * K) - Ko;
    float3 oy33 = nm3_mod7(floor(p33 * K)) * K - Ko;
    float3 oz33 = floor(p33 * K2) * Kz - Kzo;

    float3 dx11 = Pfx + jitter * ox11;
    float3 dy11 = Pfy.x + jitter * oy11;
    float3 dz11 = Pfz.x + jitter * oz11;

    float3 dx12 = Pfx + jitter * ox12;
    float3 dy12 = Pfy.x + jitter * oy12;
    float3 dz12 = Pfz.y + jitter * oz12;

    float3 dx13 = Pfx + jitter * ox13;
    float3 dy13 = Pfy.x + jitter * oy13;
    float3 dz13 = Pfz.z + jitter * oz13;

    float3 dx21 = Pfx + jitter * ox21;
    float3 dy21 = Pfy.y + jitter * oy21;
    float3 dz21 = Pfz.x + jitter * oz21;

    float3 dx22 = Pfx + jitter * ox22;
    float3 dy22 = Pfy.y + jitter * oy22;
    float3 dz22 = Pfz.y + jitter * oz22;

    float3 dx23 = Pfx + jitter * ox23;
    float3 dy23 = Pfy.y + jitter * oy23;
    float3 dz23 = Pfz.z + jitter * oz23;

    float3 dx31 = Pfx + jitter * ox31;
    float3 dy31 = Pfy.z + jitter * oy31;
    float3 dz31 = Pfz.x + jitter * oz31;

    float3 dx32 = Pfx + jitter * ox32;
    float3 dy32 = Pfy.z + jitter * oy32;
    float3 dz32 = Pfz.y + jitter * oz32;

    float3 dx33 = Pfx + jitter * ox33;
    float3 dy33 = Pfy.z + jitter * oy33;
    float3 dz33 = Pfz.z + jitter * oz33;

    float3 d11 = dx11 * dx11 + dy11 * dy11 + dz11 * dz11;
    float3 d12 = dx12 * dx12 + dy12 * dy12 + dz12 * dz12;
    float3 d13 = dx13 * dx13 + dy13 * dy13 + dz13 * dz13;
    float3 d21 = dx21 * dx21 + dy21 * dy21 + dz21 * dz21;
    float3 d22 = dx22 * dx22 + dy22 * dy22 + dz22 * dz22;
    float3 d23 = dx23 * dx23 + dy23 * dy23 + dz23 * dz23;
    float3 d31 = dx31 * dx31 + dy31 * dy31 + dz31 * dz31;
    float3 d32 = dx32 * dx32 + dy32 * dy32 + dz32 * dz32;
    float3 d33 = dx33 * dx33 + dy33 * dy33 + dz33 * dz33;

    // Full F1+F2 sort
    float3 d1a = min(d11, d12);
    d12 = max(d11, d12);
    d11 = min(d1a, d13);
    d13 = max(d1a, d13);
    d12 = min(d12, d13);

    float3 d2a = min(d21, d22);
    d22 = max(d21, d22);
    d21 = min(d2a, d23);
    d23 = max(d2a, d23);
    d22 = min(d22, d23);

    float3 d3a = min(d31, d32);
    d32 = max(d31, d32);
    d31 = min(d3a, d33);
    d33 = max(d3a, d33);
    d32 = min(d32, d33);

    float3 da = min(d11, d21);
    d21 = max(d11, d21);
    d11 = min(da, d31);
    d31 = max(da, d31);

    // select(d11.x, d11.y, d11.x > d11.y) -> WGSL: cond ? d11.y : d11.x
    d11 = float3(
        (d11.x > d11.y) ? d11.y : d11.x,
        (d11.x > d11.y) ? d11.x : d11.y,
        d11.z
    );
    d11 = float3(
        (d11.x > d11.z) ? d11.z : d11.x,
        d11.y,
        (d11.x > d11.z) ? d11.x : d11.z
    );

    d12 = min(d12, d21);
    d12 = min(d12, d22);
    d12 = min(d12, d31);
    d12 = min(d12, d32);
    d11 = float3(d11.x, min(d11.yz, d12.xy));
    d11.y = min(d11.y, d12.z);
    d11.y = min(d11.y, d11.z);

    return sqrt(d11.xy);
}

// ===== 3D Simplex Noise ======================================================
// Ashima Arts - MIT License
float4 nm3_mod289_4(float4 x)
{
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

float4 nm3_permute_4(float4 x)
{
    return nm3_mod289_4(((x * 34.0) + 10.0) * x);
}

float4 nm3_taylorInvSqrt(float4 r)
{
    return 1.79284291400159 - 0.85373472095314 * r;
}

float nm3_snoise(float3 v)
{
    float2 C = float2(1.0 / 6.0, 1.0 / 3.0);
    float4 D = float4(0.0, 0.5, 1.0, 2.0);

    float3 i = floor(v + dot(v, C.yyy));
    float3 x0 = v - i + dot(i, C.xxx);

    float3 g = step(x0.yzx, x0.xyz);
    float3 l = 1.0 - g;
    float3 i1 = min(g.xyz, l.zxy);
    float3 i2 = max(g.xyz, l.zxy);

    float3 x1 = x0 - i1 + C.xxx;
    float3 x2 = x0 - i2 + C.yyy;
    float3 x3 = x0 - D.yyy;

    i = nm3_mod289_3(i);
    float4 p = nm3_permute_4(
        nm3_permute_4(
            nm3_permute_4(i.z + float4(0.0, i1.z, i2.z, 1.0))
            + i.y + float4(0.0, i1.y, i2.y, 1.0)
        )
        + i.x + float4(0.0, i1.x, i2.x, 1.0)
    );

    float n_ = 0.142857142857;
    float3 ns = n_ * D.wyz - D.xzx;

    float4 j = p - 49.0 * floor(p * ns.z * ns.z);

    float4 x_ = floor(j * ns.z);
    float4 y_ = floor(j - 7.0 * x_);

    float4 x = x_ * ns.x + ns.yyyy;
    float4 y = y_ * ns.x + ns.yyyy;
    float4 h = 1.0 - abs(x) - abs(y);

    float4 b0 = float4(x.xy, y.xy);
    float4 bHigh = float4(x.zw, y.zw);

    float4 s0 = floor(b0) * 2.0 + 1.0;
    float4 sHigh = floor(bHigh) * 2.0 + 1.0;
    float4 sh = -step(h, float4(0.0, 0.0, 0.0, 0.0));

    float4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
    float4 aHigh = bHigh.xzyw + sHigh.xzyw * sh.zzww;

    float3 p0 = float3(a0.xy, h.x);
    float3 p1 = float3(a0.zw, h.y);
    float3 p2 = float3(aHigh.xy, h.z);
    float3 p3 = float3(aHigh.zw, h.w);

    float4 norm = nm3_taylorInvSqrt(float4(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3)));
    p0 = p0 * norm.x;
    p1 = p1 * norm.y;
    p2 = p2 * norm.z;
    p3 = p3 * norm.w;

    float4 m = max(float4(0.5, 0.5, 0.5, 0.5) - float4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), float4(0.0, 0.0, 0.0, 0.0));
    m = m * m;
    return 105.0 * dot(m * m, float4(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3)));
}

// ===== Additional noise types ================================================
float nm3_sine3D(float3 p)
{
    float3 r0 = nm3_prng(float3((float)seed, (float)seed, (float)seed)) * NM3_TAU;
    float a = r0.x;
    float b = r0.y;
    float c = r0.z;

    float3 r1 = nm3_prng(float3((float)seed, (float)seed, (float)seed)) + 1.0;
    float3 r2 = nm3_prng(float3((float)seed + 10.0, (float)seed + 10.0, (float)seed + 10.0)) + 1.0;
    float3 r3 = nm3_prng(float3((float)seed + 20.0, (float)seed + 20.0, (float)seed + 20.0)) + 1.0;
    float xv = sin(r1.x * p.z + sin(r1.y * p.x + a) + sin(r1.z * p.y + b) + c);
    float yv = sin(r2.x * p.x + sin(r2.y * p.y + b) + sin(r2.z * p.z + c) + a);
    float zv = sin(r3.x * p.y + sin(r3.y * p.z + c) + sin(r3.z * p.x + a) + b);

    return (xv + yv + zv) * 0.33 + 0.33;
}

float nm3_spheres(float3 p)
{
    float3 q = p;
    float3 pr = p - round(p);
    float3 ip = floor(q);
    float3 fp = frac(pr);
    float3 r1 = nm3_prng(ip + (float)seed) * 0.5 + 0.25;
    return length(fp - 0.5) - nm3_map_value(scale, 1.0, 100.0, 0.025, 0.55) * r1.x;
}

float nm3_cubes(float3 p_in)
{
    float3 p = p_in;
    float s = 4.0;
    p.x = p.x - s * 0.5;
    p = p - s * round(p / s);
    float3 b = float3(nm3_map_value(scale, 1.0, 100.0, 0.1, 0.95),
                      nm3_map_value(scale, 1.0, 100.0, 0.1, 0.95),
                      nm3_map_value(scale, 1.0, 100.0, 0.1, 0.95));
    float3 q = abs(p) - b;
    return length(max(q, float3(0.0, 0.0, 0.0))) + min(max(q.x, max(q.y, q.z)), 0.0);
}

// ===== Distance function (SDF) ===============================================
// NOISE_TYPE is a runtime int uniform here (reference uses a compile-time
// define purely to dodge an ANGLE->D3D inlining stall; not correctness). All
// variants are kept and selected with [branch].
float nm3_getDist(float3 p)
{
    float d;

    [branch]
    if (NOISE_TYPE == 12) {
        // simplex
        float sc = nm3_map_value(scale, 1.0, 100.0, 0.25, 0.025);
        d = nm3_snoise(p * sc + (float)seed) * 0.5 + 0.5;
        d = nm3_smootherstep(d);
    } else if (NOISE_TYPE == 20) {
        // cell
        float sc = nm3_map_value(scale, 1.0, 100.0, 0.1, 0.35);
        d = nm3_cellular(p * 0.1 + (float)seed).x;
        d = smoothstep(sc, 0.5, d);
    } else if (NOISE_TYPE == 21) {
        // cell v2
        d = nm3_voronoi3d(p * 0.1 + (float)seed).x;
        float sc = nm3_map_value(scale, 1.0, 100.0, 0.1, 0.35);
        d = smoothstep(sc, 0.5, d);
    } else if (NOISE_TYPE == 30) {
        // sine
        float sc = nm3_map_value(scale, 1.0, 100.0, 1.0, 0.1);
        d = nm3_sine3D(p * sc);
    } else if (NOISE_TYPE == 40) {
        d = nm3_spheres(p);
    } else if (NOISE_TYPE == 50) {
        d = nm3_cubes(p);
    } else if (NOISE_TYPE == 60) {
        // wavy planes both
        float sc = nm3_map_value(scale, 1.0, 100.0, 0.25, 0.025);
        d = -abs(p.y) + 4.0 + nm3_snoise(p * sc + (float)seed) * 0.75;
    } else if (NOISE_TYPE == 61) {
        // wavy plane lower
        float sc = nm3_map_value(scale, 1.0, 100.0, 0.25, 0.025);
        d = p.y + 4.0 + nm3_snoise(p * sc + (float)seed) * 0.75;
    } else if (NOISE_TYPE == 62) {
        // wavy plane upper
        float sc = nm3_map_value(scale, 1.0, 100.0, 0.25, 0.025);
        d = -p.y + 2.0 + nm3_snoise(p * sc + (float)seed) * 0.75;
    } else {
        // default to simplex
        float sc = nm3_map_value(scale, 1.0, 100.0, 0.25, 0.025);
        d = nm3_snoise(p * sc + (float)seed) * 0.5 + 0.5;
        d = nm3_smootherstep(d);
    }

    if (ridges != 0 && NOISE_TYPE == 12) {
        d = 1.0 - nm3_smoothabs(d * 2.0 - 1.0, 0.05);
    }

    return d;
}

// ===== Surface normal ========================================================
float3 nm3_getNormal(float3 p)
{
    float epsilon = 0.01;

    float d = nm3_getDist(p);
    float dx = nm3_getDist(p + float3(epsilon, 0.0, 0.0)) - d;
    float dy = nm3_getDist(p + float3(0.0, epsilon, 0.0)) - d;
    float dz = nm3_getDist(p + float3(0.0, 0.0, epsilon)) - d;

    return normalize(float3(dx, dy, dz));
}

// ===== Ray marching ==========================================================
float nm3_rayMarch(float3 rayOrigin, float3 rayDirection)
{
    const int maxSteps = 100;
    const float maxDist = 100.0;
    const float minDist = 0.01;
    float d = 0.0;

    [loop]
    for (int i = 0; i < maxSteps; i = i + 1) {
        float3 p = rayOrigin + rayDirection * d;
        float dist = nm3_getDist(p);
        d = d + dist;
        if (d > maxDist || dist < minDist) {
            break;
        }
    }
    return d;
}

// ===== Color conversion ======================================================
float3 nm3_hsv2rgb(float3 hsv)
{
    float h = frac(hsv.x);
    float s = hsv.y;
    float v = hsv.z;

    float c = v * s;
    float h6 = h * 6.0;
    float xv = c * (1.0 - abs((h6 - 2.0 * floor(h6 / 2.0)) - 1.0));
    float m = v - c;

    float3 rgb;

    if (h6 < 1.0) {
        rgb = float3(c, xv, 0.0);
    } else if (h6 < 2.0) {
        rgb = float3(xv, c, 0.0);
    } else if (h6 < 3.0) {
        rgb = float3(0.0, c, xv);
    } else if (h6 < 4.0) {
        rgb = float3(0.0, xv, c);
    } else if (h6 < 5.0) {
        rgb = float3(xv, 0.0, c);
    } else {
        rgb = float3(c, 0.0, xv);
    }

    return rgb + float3(m, m, m);
}

// =============================================================================
// nm_noise3d — core per-pixel evaluation. `globalCoord` is the fragment's pixel
// coordinate plus tileOffset (i.e. NM_GlobalCoord(i)). Mirrors WGSL main():
//   st = ((pos.xy + tileOffset) - 0.5*fullResolution) / fullResolution.y
// Returns RGBA.
// =============================================================================
float4 nm_noise3d(float2 globalCoord, float2 fullRes, float timeVal)
{
    float4 color = float4(0.0, 0.0, 0.0, 1.0);
    float2 st = (globalCoord - 0.5 * fullRes) / fullRes.y;

    // Ray marching - calculate distance to scene objects
    float3 rayOrigin = float3(offsetX * 0.1, offsetY * 0.1, -8.0 + timeVal * NM3_TAU * (float)speed);
    float3 rayDirection = normalize(float3(st, 1.0));
    float d = nm3_rayMarch(rayOrigin, rayDirection);

    // Calculate the lighting
    float3 p = rayOrigin + rayDirection * d;
    float3 lightPosition = rayOrigin + float3(-5.0, 5.0, -10.0);
    float3 lightVector = normalize(lightPosition - p);
    float3 normal = nm3_getNormal(p);
    float diffuse = clamp(dot(normal, lightVector), 0.0, 1.0);

    // Colorize based on mode
    if (colorMode == 0) {
        // grayscale
        color = float4(float3(diffuse, diffuse, diffuse), 1.0);
    } else if (colorMode == 6) {
        // hsv
        color = float4(nm3_hsv2rgb(float3(diffuse * (hueRange * 0.01) + (hueRotation / 360.0), 0.75, 0.75)), 1.0);
    } else if (colorMode == 7) {
        // surface normal
        color = float4(normal, 1.0);
    } else if (colorMode == 8) {
        // depth
        color = float4(float3(clamp(d, 0.0, 1.0), clamp(d, 0.0, 1.0), clamp(d, 0.0, 1.0)), 1.0);
    } else {
        // default to grayscale
        color = float4(float3(diffuse, diffuse, diffuse), 1.0);
    }

    // Apply fog
    float fogDist = clamp(d / 50.0, 0.0, 1.0);
    color = float4(lerp(color.rgb, float3(0.0, 0.0, 0.0), fogDist), 1.0);

    return color;
}

#endif // NM_NOISE3D_INCLUDED
