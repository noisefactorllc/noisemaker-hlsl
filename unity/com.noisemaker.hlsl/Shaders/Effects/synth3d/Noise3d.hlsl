#ifndef NM_EFFECT_NOISE3D_INCLUDED
#define NM_EFFECT_NOISE3D_INCLUDED

// =============================================================================
// Noise3d.hlsl — synth3d/noise3d (func: "noise3d")
//
// 3D simplex/gradient noise VOLUME generator. Single fullscreen pass with MRT
// (drawBuffers:2). Ported PIXEL-IDENTICALLY from the canonical WGSL source
// (top-left origin, no per-effect Y flip):
//   wgsl/precompute.wgsl   progName "precompute"   (frag_precompute)
//
// 3D / RENDER TIER MODEL (reference 04 §8 + reference 10 §3):
//  * This is a VOLUME-WRITE pass. The render target is a 2D ATLAS RenderTexture
//    sized volumeSize x volumeSize^2 (default 64 x 4096 == 64 slices of 64x64),
//    rgba16f. The fragment maps atlas pixel (x,y) -> voxel (x, y%volSize,
//    y/volSize) and writes the noise density there. A downstream render3d /
//    renderLit3d pass RAYMARCHS this atlas into a 2D image (separate effect).
//  * MRT: location 0 = volumeCache (color: rgb=density, a=1), location 1 =
//    geoBuffer (geoOut: xyz = surface normal encoded *0.5+0.5, w = density).
//    The runtime binds these as MRT0/MRT1 (definition.js outputs color/geoOut).
//
// VIEWPORT: the pass renders at the ATLAS dimensions (volumeSize x
// volumeSize^2), NOT the screen resolution. The runtime sets the viewport from
// pass.viewport (see noise3d.json). NM_FragCoord(i) therefore yields atlas
// pixel coords; _NM_Resolution must be set to the atlas size for this pass so
// uv*resolution recovers the integer voxel addressing. // TODO(verify) the C#
// runtime binds _NM_Resolution = viewport size (atlas dims), not screen size,
// for volume-write passes.
//
// COMPILE-TIME DEFINES -> RUNTIME UNIFORMS: the WGSL bakes OCTAVES / COLOR_MODE
// / RIDGES as injected consts for the Dawn optimizer (perf only, NOT
// correctness). Per PORTING-GUIDE we declare them as plain int uniforms and
// branch at runtime; values are identical. Defaults: OCTAVES=1, COLOR_MODE=0
// (mono), RIDGES=0 (false).
//
// PORTING-GUIDE / parity notes:
//  * fragCoord = position.xy (@builtin(position), top-left, +0.5 centered) ->
//    NM_FragCoord(i). pixelCoord = int2(fragCoord) (truncation, matching
//    WGSL vec2<i32>(position.xy)). Atlas addressing y%volSize, y/volSize uses
//    int % and / (trunc toward zero) — matches WGSL i32 % and /.
//  * hash4: vec4<u32>(vec4<i32>(ps*1000.0)+65536) is float->int TRUNCATION then
//    int->uint REINTERPRET: (uint4)((int4)(ps*1000.0)+65536). >> vec4<u32>(16u)
//    -> >> 16u (logical). Divisor 4294967295.0. Reproduced verbatim.
//  * grad4 offsets 127.1 / 269.5 / 419.2 and normalize() copied literally.
//  * wrapW uses WGSL `w % W_PERIOD` (float modulo) -> nm_mod(w, W_PERIOD)
//    (a - b*floor(a/b)); NEVER fmod (H6).
//  * noise4D: 16-corner quadrilinear with quintic weights; all dot/mix terms
//    copied literally (do not reassociate — H10).
//  * fbm4D: octave loop bound by runtime OCTAVES (was compile-time); clamp,
//    ridges branch, sum/maxVal accumulation verbatim.
//  * mix->lerp, fract->frac, full 32-bit float (H5). normalize(-gradient +
//    float3(1e-6,1e-6,1e-6)) copied literally.
//  * Helpers are ported verbatim, inline. NONE come from NMCore except nm_mod.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- MRT output struct (matches WGSL FragmentOutput) ------------------------
struct Noise3dFragmentOutput
{
    float4 fragColor : SV_Target0;   // -> volumeCache (color)
    float4 geoOut    : SV_Target1;   // -> geoBuffer  (geoOut)
};

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
// WGSL bindings: time(0), scale(1), seed(2), volumeSize(3), speed(4).
// `time` is the engine global (NMFullscreen alias). The runtime sets the rest.
float scale;        // globals.scale       default 3
int   seed;         // globals.seed        default 0
int   volumeSize;   // globals.volumeSize  default 64 (atlas slice edge)
float speed;        // globals.speed       default 1  (int param, bound as float == WGSL f32)

// Compile-time defines in the reference, runtime uniforms here (perf-only bake):
int OCTAVES;        // globals.octaves     default 1   (1..6)
int COLOR_MODE;     // globals.colorMode   default 0   (0 mono, 1 rgb)
int RIDGES;         // globals.ridges      default 0   (boolean 1/0, tested != 0)

// =============================================================================
// Verbatim helpers (ported inline from precompute.wgsl)
// =============================================================================
static const float TAU = 6.283185307179586;
static const float W_PERIOD = 4.0;  // Period length in w-axis lattice units for seamless time loop

// Improved hash using multiple rounds of mixing (4D version)
float n3d_hash4(float4 p)
{
    float4 ps = p + (float)seed * 0.1;
    uint4 q = (uint4)((int4)(ps * 1000.0) + 65536);
    q = q * 1664525u + 1013904223u;
    q.x = q.x + q.y * q.z;
    q.y = q.y + q.z * q.w;
    q.z = q.z + q.w * q.x;
    q.w = q.w + q.x * q.y;
    q = q ^ (q >> 16u);
    q.x = q.x + q.y * q.z;
    q.y = q.y + q.z * q.w;
    q.z = q.z + q.w * q.x;
    q.w = q.w + q.x * q.y;
    return (float)(q.x ^ q.y ^ q.z ^ q.w) / 4294967295.0;
}

// Gradient from hash - returns normalized 4D vector
float4 n3d_grad4(float4 p)
{
    float h1 = n3d_hash4(p);
    float h2 = n3d_hash4(p + 127.1);
    float h3 = n3d_hash4(p + 269.5);
    float h4 = n3d_hash4(p + 419.2);
    float4 g = float4(
        h1 * 2.0 - 1.0,
        h2 * 2.0 - 1.0,
        h3 * 2.0 - 1.0,
        h4 * 2.0 - 1.0
    );
    return normalize(g);
}

// Quintic interpolation for smooth transitions
float n3d_quintic(float t)
{
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

// Wrap w index for periodicity at lattice level
float n3d_wrapW(float w)
{
    return nm_mod(w, W_PERIOD);
}

// 4D gradient noise - Perlin-style with quintic interpolation
// w-axis is periodic with period W_PERIOD for seamless time looping
float n3d_noise4D(float4 p)
{
    float4 i = floor(p);
    float4 f = frac(p);

    float4 u = float4(n3d_quintic(f.x), n3d_quintic(f.y), n3d_quintic(f.z), n3d_quintic(f.w));

    // Wrap w indices for periodicity
    float iw0 = n3d_wrapW(i.w);
    float iw1 = n3d_wrapW(i.w + 1.0);

    // 16 corners of 4D hypercube with wrapped w
    // w=0 corners
    float n0000 = dot(n3d_grad4(float4(i.xyz, iw0) + float4(0.0, 0.0, 0.0, 0.0)), f - float4(0.0, 0.0, 0.0, 0.0));
    float n1000 = dot(n3d_grad4(float4(i.xyz, iw0) + float4(1.0, 0.0, 0.0, 0.0)), f - float4(1.0, 0.0, 0.0, 0.0));
    float n0100 = dot(n3d_grad4(float4(i.xyz, iw0) + float4(0.0, 1.0, 0.0, 0.0)), f - float4(0.0, 1.0, 0.0, 0.0));
    float n1100 = dot(n3d_grad4(float4(i.xyz, iw0) + float4(1.0, 1.0, 0.0, 0.0)), f - float4(1.0, 1.0, 0.0, 0.0));
    float n0010 = dot(n3d_grad4(float4(i.xyz, iw0) + float4(0.0, 0.0, 1.0, 0.0)), f - float4(0.0, 0.0, 1.0, 0.0));
    float n1010 = dot(n3d_grad4(float4(i.xyz, iw0) + float4(1.0, 0.0, 1.0, 0.0)), f - float4(1.0, 0.0, 1.0, 0.0));
    float n0110 = dot(n3d_grad4(float4(i.xyz, iw0) + float4(0.0, 1.0, 1.0, 0.0)), f - float4(0.0, 1.0, 1.0, 0.0));
    float n1110 = dot(n3d_grad4(float4(i.xyz, iw0) + float4(1.0, 1.0, 1.0, 0.0)), f - float4(1.0, 1.0, 1.0, 0.0));
    // w=1 corners
    float n0001 = dot(n3d_grad4(float4(i.xyz, iw1) + float4(0.0, 0.0, 0.0, 0.0)), f - float4(0.0, 0.0, 0.0, 1.0));
    float n1001 = dot(n3d_grad4(float4(i.xyz, iw1) + float4(1.0, 0.0, 0.0, 0.0)), f - float4(1.0, 0.0, 0.0, 1.0));
    float n0101 = dot(n3d_grad4(float4(i.xyz, iw1) + float4(0.0, 1.0, 0.0, 0.0)), f - float4(0.0, 1.0, 0.0, 1.0));
    float n1101 = dot(n3d_grad4(float4(i.xyz, iw1) + float4(1.0, 1.0, 0.0, 0.0)), f - float4(1.0, 1.0, 0.0, 1.0));
    float n0011 = dot(n3d_grad4(float4(i.xyz, iw1) + float4(0.0, 0.0, 1.0, 0.0)), f - float4(0.0, 0.0, 1.0, 1.0));
    float n1011 = dot(n3d_grad4(float4(i.xyz, iw1) + float4(1.0, 0.0, 1.0, 0.0)), f - float4(1.0, 0.0, 1.0, 1.0));
    float n0111 = dot(n3d_grad4(float4(i.xyz, iw1) + float4(0.0, 1.0, 1.0, 0.0)), f - float4(0.0, 1.0, 1.0, 1.0));
    float n1111 = dot(n3d_grad4(float4(i.xyz, iw1) + float4(1.0, 1.0, 1.0, 0.0)), f - float4(1.0, 1.0, 1.0, 1.0));

    // Quadrilinear interpolation
    // First along x
    float nx000 = lerp(n0000, n1000, u.x);
    float nx100 = lerp(n0100, n1100, u.x);
    float nx010 = lerp(n0010, n1010, u.x);
    float nx110 = lerp(n0110, n1110, u.x);
    float nx001 = lerp(n0001, n1001, u.x);
    float nx101 = lerp(n0101, n1101, u.x);
    float nx011 = lerp(n0011, n1011, u.x);
    float nx111 = lerp(n0111, n1111, u.x);

    // Then along y
    float nxy00 = lerp(nx000, nx100, u.y);
    float nxy10 = lerp(nx010, nx110, u.y);
    float nxy01 = lerp(nx001, nx101, u.y);
    float nxy11 = lerp(nx011, nx111, u.y);

    // Then along z
    float nxyz0 = lerp(nxy00, nxy10, u.z);
    float nxyz1 = lerp(nxy01, nxy11, u.z);

    // Finally along w
    return lerp(nxyz0, nxyz1, u.w);
}

// FBM using 4D noise with periodic w for time. OCTAVES/RIDGES are runtime
// uniforms here (were compile-time consts in the reference, perf only).
float n3d_fbm4D(float4 p)
{
    float amplitude = 0.5;
    float frequency = 1.0;
    float sum = 0.0;
    float maxVal = 0.0;

    [loop]
    for (int i = 0; i < OCTAVES; i = i + 1)
    {
        float4 pos = float4(p.xyz * frequency, p.w);
        float n = n3d_noise4D(pos);
        n = clamp(n * 1.5, -1.0, 1.0);
        if (RIDGES != 0)
        {
            n = 1.0 - abs(n);
        }
        else
        {
            n = (n + 1.0) * 0.5;
        }
        sum = sum + n * amplitude;
        maxVal = maxVal + amplitude;
        frequency = frequency * 2.0;
        amplitude = amplitude * 0.5;
    }
    return sum / maxVal;
}

// =============================================================================
// PASS: precompute — volume-write (MRT) — (frag_precompute)
// =============================================================================
Noise3dFragmentOutput frag_precompute(NMVaryings i)
{
    Noise3dFragmentOutput o;

    // Use uniform for volume size
    int volSize = volumeSize;
    float volSizeF = (float)volSize;

    // Atlas is volSize x (volSize * volSize)
    // Pixel (x, y) maps to 3D coordinate (x, y % volSize, y / volSize)
    int2 pixelCoord = (int2)NM_FragCoord(i);

    int x = pixelCoord.x;
    int y = pixelCoord.y % volSize;
    int z = pixelCoord.y / volSize;

    // Bounds check
    if (x >= volSize || y >= volSize || z >= volSize)
    {
        o.fragColor = float4(0.0, 0.0, 0.0, 0.0);
        o.geoOut    = float4(0.5, 0.5, 0.5, 0.0);  // neutral normal, zero density
        return o;
    }

    // Convert to normalized 3D coordinates in [-1, 1] world space (bounding box)
    float3 p = float3((float)x, (float)y, (float)z) / (volSizeF - 1.0) * 2.0 - 1.0;

    // Scale for noise density
    float3 scaledP = p * scale;

    // Linear time traversal with periodic w-axis
    // time goes 0->1, map to 0->W_PERIOD for one complete loop
    // speed multiplies time to control animation speed
    float w = time * speed * W_PERIOD;

    // Compute 4D FBM noise at this point with time as w
    float4 p4d = float4(scaledP, w);
    float noiseVal = n3d_fbm4D(p4d);

    // Compute analytical gradient using finite differences in noise space
    float eps = 0.01 / scale;
    float nx = n3d_fbm4D(float4(scaledP + float3(eps, 0.0, 0.0), w));
    float ny = n3d_fbm4D(float4(scaledP + float3(0.0, eps, 0.0), w));
    float nz = n3d_fbm4D(float4(scaledP + float3(0.0, 0.0, eps), w));

    // Gradient points from low to high density
    float3 gradient = float3(nx - noiseVal, ny - noiseVal, nz - noiseVal) / eps;

    // Normal points outward (from high to low density), encode in [0,1] range
    float3 normal = normalize(-gradient + float3(1e-6, 1e-6, 1e-6));

    // Output volume data based on colorMode (runtime uniform here).
    float4 fragColor;
    if (COLOR_MODE == 0)
    {
        fragColor = float4(noiseVal, noiseVal, noiseVal, 1.0);
    }
    else
    {
        // For RGB color mode, compute 3 different noise channels with offsets
        float g = n3d_fbm4D(float4(scaledP, w) + float4(0.0, 0.0, 0.0, 1.33));
        float b = n3d_fbm4D(float4(scaledP, w) + float4(0.0, 0.0, 0.0, 2.67));
        fragColor = float4(noiseVal, g, b, 1.0);
    }

    // Output analytical geometry: normal.xyz encoded [0,1], density in w
    float4 geoOut = float4(normal * 0.5 + 0.5, noiseVal);

    o.fragColor = fragColor;
    o.geoOut    = geoOut;
    return o;
}

#endif // NM_EFFECT_NOISE3D_INCLUDED
