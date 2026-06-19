#ifndef NM_SPATTER_INCLUDED
#define NM_SPATTER_INCLUDED

// =============================================================================
// Spatter.hlsl — filter/spatter, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/spatter/wgsl/spatter.wgsl
//
// Multi-layer procedural paint spatter. Grid-based PCG hash noise with explicit
// interpolation (bicubic / bilinear / cosine), exp-distributed FBM (pow(x,4) at
// grid points), brightness/contrast thresholding, ridged-removal subtraction,
// density scale, and a sharp step at 0.5 (blend_layers feather=0.005). The mask
// multiplies the base color and is blended back by `alpha`.
//
// PORTING-GUIDE notes:
//  * Single render pass (definition.js passes[].length == 1, program "spatter").
//  * pcg3 == the shared NMCore nm_pcg(uint3) (PORTING-GUIDE golden rule 2: pcg is
//    the ONLY shared PRNG primitive). Everything else (pcg(uint), hashf, gridVal,
//    cubic, the *ExpGrid samplers and the *Fbm* helpers) is this effect's OWN copy
//    — ported VERBATIM inline here. Do NOT hoist or substitute generic versions.
//  * Sample UV (WGSL lines 181-182): uv = (position.xy + tileOffset) / fullResolution.
//    NB: WGSL computes `dims = textureDimensions(inputTex)` but does NOT use it for
//    the base sample — it samples at the fullResolution-based UV. We port the WGSL
//    LITERALLY: base sample uses NM_GlobalCoord(i) / fullResolution (the GLSL divides
//    by input dims instead; WGSL is canonical per golden rule 1). nUV reuses that
//    same global UV times (aspect, 1).
//  * Float->uint: `u32(seed)` and `u32(p.x + 32768)` are NUMERIC TRUNCATION casts
//    ((uint) in HLSL), NOT asuint bit-reinterprets (H-table). p+32768 keeps lattice
//    coords non-negative before the cast.
//  * PCG divisor is f32(0xffffffffu) = 4294967295.0, not 2^32 (H11). We keep the
//    literal `0xffffffffu` cast to float, matching the WGSL exactly.
//  * `select`-free, atan2-free; no reassociation of cubic()'s redundant terms.
//  * color: vec3 uniform (RGB, linear, non-sRGB). density/alpha: f32. seed: i32.
//  * Linear, clamp-to-edge, non-sRGB sampler (H7) — set on the SamplerState in
//    Spatter.shader / supplied by the Shader Graph node.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
// Bound by the runtime via MaterialPropertyBlock under these exact names.
float3 color;     // globals.color.uniform   "color",   default (0.875,0.125,0.125)
float  density;   // globals.density.uniform "density", default 0.5
float  alpha;     // globals.alpha.uniform   "alpha",   default 0.75
int    seed;      // globals.seed.uniform    "seed",    default 1

// -----------------------------------------------------------------------------
// pcg / hashf — per-effect 1-D wrappers around the shared pcg3 (nm_pcg).
// WGSL:
//   fn pcg(v_in: u32) -> u32 { return pcg3(vec3<u32>(v_in, 0u, 0u)).x; }
//   fn hashf(h: u32) -> f32 { return f32(pcg3(vec3<u32>(h,0u,0u)).x) / f32(0xffffffffu); }
// -----------------------------------------------------------------------------
uint pcg(uint v_in)
{
    return nm_pcg(uint3(v_in, 0u, 0u)).x;
}

float hashf(uint h)
{
    return float(nm_pcg(uint3(h, 0u, 0u)).x) / float(0xffffffffu);
}

// -----------------------------------------------------------------------------
// gridVal — hash float in [0,1] at an integer grid point. Per-effect copy.
// WGSL:
//   let h = pcg3(vec3<u32>(u32(p.x + 32768), u32(p.y + 32768), sd));
//   return f32(h.x) / f32(0xffffffffu);
// -----------------------------------------------------------------------------
float gridVal(int2 p, uint sd)
{
    uint3 h = nm_pcg(uint3((uint)(p.x + 32768), (uint)(p.y + 32768), sd));
    return float(h.x) / float(0xffffffffu);
}

// -----------------------------------------------------------------------------
// cubic — Catmull-Rom cubic interpolation. Redundant terms preserved literally.
// WGSL:
//   let t2 = t*t; let t3 = t2*t;
//   return 0.5 * ((2.0*b) + (-a+c)*t + (2.0*a - 5.0*b + 4.0*c - d)*t2 + (-a + 3.0*b - 3.0*c + d)*t3);
// -----------------------------------------------------------------------------
float cubic(float a, float b, float c, float d, float t)
{
    float t2 = t * t;
    float t3 = t2 * t;
    return 0.5 * ((2.0 * b) + (-a + c) * t + (2.0 * a - 5.0 * b + 4.0 * c - d) * t2 + (-a + 3.0 * b - 3.0 * c + d) * t3);
}

// -----------------------------------------------------------------------------
// bicubicExpGrid — 4x4 Catmull-Rom, pow(x,4) at grid points. Per-effect copy.
// -----------------------------------------------------------------------------
float bicubicExpGrid(float2 pos, uint sd)
{
    int2 ip = int2(floor(pos));
    float2 fp = frac(pos);

    float row0; float row1; float row2; float row3;

    // Row -1
    float g00 = pow(gridVal(int2(ip.x - 1, ip.y - 1), sd), 4.0);
    float g10 = pow(gridVal(int2(ip.x,     ip.y - 1), sd), 4.0);
    float g20 = pow(gridVal(int2(ip.x + 1, ip.y - 1), sd), 4.0);
    float g30 = pow(gridVal(int2(ip.x + 2, ip.y - 1), sd), 4.0);
    row0 = cubic(g00, g10, g20, g30, fp.x);

    // Row 0
    float g01 = pow(gridVal(int2(ip.x - 1, ip.y), sd), 4.0);
    float g11 = pow(gridVal(int2(ip.x,     ip.y), sd), 4.0);
    float g21 = pow(gridVal(int2(ip.x + 1, ip.y), sd), 4.0);
    float g31 = pow(gridVal(int2(ip.x + 2, ip.y), sd), 4.0);
    row1 = cubic(g01, g11, g21, g31, fp.x);

    // Row +1
    float g02 = pow(gridVal(int2(ip.x - 1, ip.y + 1), sd), 4.0);
    float g12 = pow(gridVal(int2(ip.x,     ip.y + 1), sd), 4.0);
    float g22 = pow(gridVal(int2(ip.x + 1, ip.y + 1), sd), 4.0);
    float g32 = pow(gridVal(int2(ip.x + 2, ip.y + 1), sd), 4.0);
    row2 = cubic(g02, g12, g22, g32, fp.x);

    // Row +2
    float g03 = pow(gridVal(int2(ip.x - 1, ip.y + 2), sd), 4.0);
    float g13 = pow(gridVal(int2(ip.x,     ip.y + 2), sd), 4.0);
    float g23 = pow(gridVal(int2(ip.x + 1, ip.y + 2), sd), 4.0);
    float g33 = pow(gridVal(int2(ip.x + 2, ip.y + 2), sd), 4.0);
    row3 = cubic(g03, g13, g23, g33, fp.x);

    return clamp(cubic(row0, row1, row2, row3, fp.y), 0.0, 1.0);
}

// -----------------------------------------------------------------------------
// bilinearExpGrid — 2x2 bilinear, pow(x,4) at grid points. Per-effect copy.
// -----------------------------------------------------------------------------
float bilinearExpGrid(float2 pos, uint sd)
{
    int2 ip = int2(floor(pos));
    float2 fp = frac(pos);

    float v00 = pow(gridVal(ip, sd), 4.0);
    float v10 = pow(gridVal(int2(ip.x + 1, ip.y), sd), 4.0);
    float v01 = pow(gridVal(int2(ip.x, ip.y + 1), sd), 4.0);
    float v11 = pow(gridVal(int2(ip.x + 1, ip.y + 1), sd), 4.0);

    float mx0 = lerp(v00, v10, fp.x);
    float mx1 = lerp(v01, v11, fp.x);
    return lerp(mx0, mx1, fp.y);
}

// -----------------------------------------------------------------------------
// cosineExpGrid — 2x2 cosine-smoothed, pow(x,4) at grid points. Per-effect copy.
// WGSL uses the full-precision PI literal 3.14159265358979.
// -----------------------------------------------------------------------------
float cosineExpGrid(float2 pos, uint sd)
{
    int2 ip = int2(floor(pos));
    float2 fp = frac(pos);

    float tx = (1.0 - cos(fp.x * 3.14159265358979)) * 0.5;
    float ty = (1.0 - cos(fp.y * 3.14159265358979)) * 0.5;

    float v00 = pow(gridVal(ip, sd), 4.0);
    float v10 = pow(gridVal(int2(ip.x + 1, ip.y), sd), 4.0);
    float v01 = pow(gridVal(int2(ip.x, ip.y + 1), sd), 4.0);
    float v11 = pow(gridVal(int2(ip.x + 1, ip.y + 1), sd), 4.0);

    float mx0 = lerp(v00, v10, tx);
    float mx1 = lerp(v01, v11, tx);
    return lerp(mx0, mx1, ty);
}

// -----------------------------------------------------------------------------
// FBM helpers — per-octave freq doubles, weight halves; each octave seed +10000.
// Weight sums: 0.984375 (6-oct), 0.9375 (4-oct), 0.875 (3-oct ridged).
// -----------------------------------------------------------------------------
float expFbm6Bicubic(float2 uv, float2 freq, uint sd)
{
    float a = 0.0;
    a = a + bicubicExpGrid(uv * freq,        sd          ) * 0.5;
    a = a + bicubicExpGrid(uv * freq * 2.0,  sd + 10000u ) * 0.25;
    a = a + bicubicExpGrid(uv * freq * 4.0,  sd + 20000u ) * 0.125;
    a = a + bicubicExpGrid(uv * freq * 8.0,  sd + 30000u ) * 0.0625;
    a = a + bicubicExpGrid(uv * freq * 16.0, sd + 40000u ) * 0.03125;
    a = a + bicubicExpGrid(uv * freq * 32.0, sd + 50000u ) * 0.015625;
    return a / 0.984375;
}

float expFbm4Bilinear(float2 uv, float2 freq, uint sd)
{
    float a = 0.0;
    a = a + bilinearExpGrid(uv * freq,        sd          ) * 0.5;
    a = a + bilinearExpGrid(uv * freq * 2.0,  sd + 10000u ) * 0.25;
    a = a + bilinearExpGrid(uv * freq * 4.0,  sd + 20000u ) * 0.125;
    a = a + bilinearExpGrid(uv * freq * 8.0,  sd + 30000u ) * 0.0625;
    return a / 0.9375;
}

float expRidgedFbm3Cosine(float2 uv, float2 freq, uint sd)
{
    float a = 0.0;
    float v;
    v = cosineExpGrid(uv * freq,        sd          );
    a = a + (1.0 - abs(2.0 * v - 1.0)) * 0.5;
    v = cosineExpGrid(uv * freq * 2.0,  sd + 10000u );
    a = a + (1.0 - abs(2.0 * v - 1.0)) * 0.25;
    v = cosineExpGrid(uv * freq * 4.0,  sd + 20000u );
    a = a + (1.0 - abs(2.0 * v - 1.0)) * 0.125;
    return a / 0.875;
}

// -----------------------------------------------------------------------------
// nm_spatter — core per-pixel evaluation. Takes the already-sampled base color
// and the noise UV (global UV, before aspect correction) and returns the final
// RGBA. Ported VERBATIM from spatter.wgsl main() (lines 184-231).
// -----------------------------------------------------------------------------
float4 nm_spatter(float4 base, float2 uv)
{
    // Aspect-corrected UV for noise sampling
    float aspect = fullResolution.x / fullResolution.y;
    float2 nUV = uv * float2(aspect, 1.0);

    uint s = (uint)seed * 17u;
    float3 user_color = color;

    // Seed-derived random frequencies (matching Python ranges)
    float smearFreq = lerp(3.0, 6.0, hashf(pcg(s + 10u)));
    float dotFreq   = lerp(32.0, 64.0, hashf(pcg(s + 50u)));
    float speckFreq = lerp(150.0, 200.0, hashf(pcg(s + 90u)));
    float ridgeFreq = lerp(2.0, 3.0, hashf(pcg(s + 130u)));

    // -- Layer 1: Large smear (6-oct bicubic exp FBM, domain warped) --
    float warpFreqX = lerp(2.0, 3.0, hashf(pcg(s + 160u)));
    float warpFreqY = lerp(1.0, 3.0, hashf(pcg(s + 170u)));
    float warpX = bilinearExpGrid(nUV * float2(warpFreqX, warpFreqY), s + 200u);
    float warpY = bilinearExpGrid(nUV * float2(warpFreqX, warpFreqY), s + 300u);
    float disp = 1.0 + hashf(pcg(s + 150u));
    float2 warpedUV = nUV + (float2(warpX, warpY) - 0.5) * disp * 0.12;
    float smear = expFbm6Bicubic(warpedUV, float2(smearFreq, smearFreq), s + 100u);

    // -- Layer 2: Medium dots (4-oct bilinear exp FBM + brightness/contrast) --
    float dots = expFbm4Bilinear(nUV, float2(dotFreq, dotFreq), s + 43u);
    dots = clamp(4.0 * dots - 1.6, 0.0, 1.0);

    // -- Layer 3: Fine specks (4-oct bilinear exp FBM + brightness/contrast) --
    float specks = expFbm4Bilinear(nUV, float2(speckFreq, speckFreq), s + 71u);
    specks = clamp(4.0 * specks - 2.0, 0.0, 1.0);

    // Combine: max of layers
    float combined = max(smear, max(dots, specks));

    // Subtract exp+ridged cosine noise for breaks
    float ridge = expRidgedFbm3Cosine(nUV, float2(ridgeFreq, ridgeFreq), s + 89u);
    combined = max(0.0, combined - ridge);

    // Density scales before threshold
    combined = combined * (0.5 + density * 2.0);

    // Sharp step at 0.5 (Python blend_layers with feather=0.005)
    float mask = step(0.5, combined);

    // Color blend
    float3 colored = base.rgb * user_color;
    float3 result = lerp(base.rgb, lerp(base.rgb, colored, mask), alpha);

    return float4(result, base.a);
}

#endif // NM_SPATTER_INCLUDED
