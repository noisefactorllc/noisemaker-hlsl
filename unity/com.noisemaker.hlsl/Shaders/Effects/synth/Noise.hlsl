#ifndef NM_EFFECT_NOISE_INCLUDED
#define NM_EFFECT_NOISE_INCLUDED

// =============================================================================
// Noise.hlsl — synth/noise (VNoise) ported VERBATIM from
//   shaders/effects/synth/noise/wgsl/noise.wgsl  (WGSL is canonical).
//
// Value noise with multiple interpolation types. Single render pass.
//
// PORTING-GUIDE compliance:
//  - Helpers ported inline per-effect. Only pcg/prng/random/nm_mod/map/
//    periodicFunction come from NMCore.hlsl (they are bit-identical across all
//    reference copies). Everything else (blendBicubic, catmullRom*, simplex,
//    shape, offset, …) is this effect's own version, inline here.
//  - Full 32-bit float only. `nm_mod` not `fmod`. `asuint` for the float-bits
//    jitter reinterpret; `(uint)` for numeric truncation of lattice coords.
//  - NOISE_TYPE / LOOP_OFFSET are runtime int uniforms branched with [branch]
//    (the WGSL already keeps all variants and relies on const-folding). Defaults
//    NOISE_TYPE=10 (simplex), LOOP_OFFSET=300 (value-noise offset).
//  - select(b,a,cond) (WGSL) -> cond ? a : b (HLSL). atan2 arg order copied
//    literally. st divides by fullResolution.y (height).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (mirror definition.js globals[*].uniform) -----
// Bound by the runtime via MaterialPropertyBlock by these exact names.
float scaleX;       // globals.scaleX.uniform
float scaleY;       // globals.scaleY.uniform
float seed;         // globals.seed.uniform (stored float; reference uses i32(floor) where needed)
float loopScale;    // globals.loopScale.uniform
float speed;        // globals.speed.uniform
int   octaves;      // globals.octaves.uniform
int   ridges;       // globals.ridges.uniform   (boolean -> int, tested >0.5 below)
int   wrap;         // globals.wrap.uniform      (boolean -> int, tested >0.5 below)
int   colorMode;    // globals.colorMode.uniform

// Compile-time defines in the reference; modeled as runtime int uniforms here.
// Defaults match the GLSL/WGSL fallbacks (see PORTING-GUIDE §"Uniform model").
#ifndef NM_NOISE_TYPE_DEFAULT
#define NM_NOISE_TYPE_DEFAULT 10
#endif
#ifndef NM_LOOP_OFFSET_DEFAULT
#define NM_LOOP_OFFSET_DEFAULT 300
#endif
int NOISE_TYPE;     // was globals.type.define = "NOISE_TYPE"
int LOOP_OFFSET;    // was globals.loopOffset.define = "LOOP_OFFSET"

// PI / TAU exactly as in the WGSL source.
static const float PI  = 3.14159265359;
static const float TAU = 6.28318530718;

// -----------------------------------------------------------------------------
// Effect-local helpers (ported verbatim from noise.wgsl). `modulo`, `map`,
// `pcg`, `prng`, `random`, `periodicFunction` are bit-identical to NMCore's
// nm_* equivalents and are reused from there (the only sanctioned sharing).
// -----------------------------------------------------------------------------

// blendBicubic(p0,p1,p2,p3,t) — uniform cubic B-spline basis (/6).
float nmn_blendBicubic(float p0, float p1, float p2, float p3, float t)
{
    float t2 = t * t;
    float t3 = t2 * t;
    float b0 = (1.0 - t) * (1.0 - t) * (1.0 - t) / 6.0;
    float b1 = (3.0 * t3 - 6.0 * t2 + 4.0) / 6.0;
    float b2 = (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) / 6.0;
    float b3 = t3 / 6.0;
    return p0 * b0 + p1 * b1 + p2 * b2 + p3 * b3;
}

// catmullRom3 — NOTE the deliberately redundant `4.0*p2 - p0` and
// `-3.0*p2 + p0` terms that partially cancel; reproduced LITERALLY (H10).
float nmn_catmullRom3(float p0, float p1, float p2, float t)
{
    float t2 = t * t;
    float t3 = t2 * t;
    return p1 + 0.5 * t * (p2 - p0) +
           0.5 * t2 * (2.0*p0 - 5.0*p1 + 4.0*p2 - p0) +
           0.5 * t3 * (-p0 + 3.0*p1 - 3.0*p2 + p0);
}

// catmullRom4 — Horner form, verbatim.
float nmn_catmullRom4(float p0, float p1, float p2, float p3, float t)
{
    return p1 + 0.5 * t * (p2 - p0 + t * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 + t * (3.0 * (p1 - p2) + p3 - p0)));
}

// quadratic3 — quadratic B-spline (type 5).
float nmn_quadratic3(float p0, float p1, float p2, float t)
{
    float t2 = t * t;
    return p0 * 0.5 * (1.0 - t) * (1.0 - t) +
           p1 * 0.5 * (-2.0 * t2 + 2.0 * t + 1.0) +
           p2 * 0.5 * t2;
}

// blendLinearOrCosine: nType==1 -> linear lerp; else smoothstep (hermite).
float nmn_blendLinearOrCosine(float a, float b, float amount, int nType)
{
    if (nType == 1) { return lerp(a, b, amount); }
    return lerp(a, b, smoothstep(0.0, 1.0, amount));
}

// -----------------------------------------------------------------------------
// constantFromLatticeWithOffset — the lattice hash (heart of value noise).
// Reads the effect's `wrap` flag (tested >0.5, matching WGSL bool packing).
// `asuint(sFrac)` is the bit-reinterpret; `(uint)xi` is the int->uint two's-
// complement reinterpret; `(uint)p` (in nm_prng) is float->uint truncation.
// -----------------------------------------------------------------------------
float nmn_constantFromLatticeWithOffset(float2 lattice, float2 freq, float s, float blend, int2 offset)
{
    float2 baseFloor = floor(lattice);
    int2 base = (int2)baseFloor + offset;
    float2 fr = lattice - baseFloor;
    int seedInt = (int)floor(s);
    float sFrac = frac(s);
    float xCombined = fr.x + sFrac;
    int xi = base.x + (int)floor(xCombined);
    int yi = base.y;

    if (wrap > 0.5)
    {
        int freqX = (int)(freq.x + 0.5);
        int freqY = (int)(freq.y + 0.5);
        if (freqX > 0) { xi = nm_positiveModulo(xi, freqX); }
        if (freqY > 0) { yi = nm_positiveModulo(yi, freqY); }
    }

    uint xBits = (uint)xi;
    uint yBits = (uint)yi;
    uint seedBits = (uint)seedInt;
    uint fracBits = asuint(sFrac);

    uint3 jitter = uint3(
        (fracBits * 374761393u) ^ 0x9E3779B9u,
        (fracBits * 668265263u) ^ 0x7F4A7C15u,
        (fracBits * 2246822519u) ^ 0x94D049B4u
    );

    uint3 state = uint3(xBits, yBits, seedBits) ^ jitter;
    uint3 prngState = nm_pcg(state);
    float noiseValue = (float)prngState.x / 4294967295.0;
    return nm_periodicFunction(noiseValue - blend);
}

float nmn_constantFromLattice(float2 lattice, float2 freq, float s, float blend)
{
    return nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2(0, 0));
}

float nmn_constant(float2 st, float2 freq, float s, float blend)
{
    float2 lattice = st * freq;
    return nmn_constantFromLattice(lattice, freq, s, blend);
}

float nmn_constantOffset(float2 lattice, float2 freq, float s, float blend, int2 offset)
{
    return nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, offset);
}

float nmn_cubic3x3ValueNoise(float2 st, float2 freq, float s, float blend)
{
    float2 lattice = st * freq;
    float2 f = frac(lattice);
    float v00 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2(-1, -1));
    float v10 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2( 0, -1));
    float v20 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2( 1, -1));
    float v01 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2(-1,  0));
    float v11 = nmn_constantFromLattice(lattice, freq, s, blend);
    float v21 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2( 1,  0));
    float v02 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2(-1,  1));
    float v12 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2( 0,  1));
    float v22 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2( 1,  1));
    float y0 = nmn_quadratic3(v00, v10, v20, f.x);
    float y1 = nmn_quadratic3(v01, v11, v21, f.x);
    float y2 = nmn_quadratic3(v02, v12, v22, f.x);
    return nmn_quadratic3(y0, y1, y2, f.y);
}

float nmn_bicubicValue(float2 st, float2 freq, float s, float blend)
{
    float2 lattice = st * freq;
    float x0y0 = nmn_constantOffset(lattice, freq, s, blend, int2(-1, -1));
    float x0y1 = nmn_constantOffset(lattice, freq, s, blend, int2(-1, 0));
    float x0y2 = nmn_constantOffset(lattice, freq, s, blend, int2(-1, 1));
    float x0y3 = nmn_constantOffset(lattice, freq, s, blend, int2(-1, 2));
    float x1y0 = nmn_constantOffset(lattice, freq, s, blend, int2(0, -1));
    float x1y1 = nmn_constantFromLattice(lattice, freq, s, blend);
    float x1y2 = nmn_constantOffset(lattice, freq, s, blend, int2(0, 1));
    float x1y3 = nmn_constantOffset(lattice, freq, s, blend, int2(0, 2));
    float x2y0 = nmn_constantOffset(lattice, freq, s, blend, int2(1, -1));
    float x2y1 = nmn_constantOffset(lattice, freq, s, blend, int2(1, 0));
    float x2y2 = nmn_constantOffset(lattice, freq, s, blend, int2(1, 1));
    float x2y3 = nmn_constantOffset(lattice, freq, s, blend, int2(1, 2));
    float x3y0 = nmn_constantOffset(lattice, freq, s, blend, int2(2, -1));
    float x3y1 = nmn_constantOffset(lattice, freq, s, blend, int2(2, 0));
    float x3y2 = nmn_constantOffset(lattice, freq, s, blend, int2(2, 1));
    float x3y3 = nmn_constantOffset(lattice, freq, s, blend, int2(2, 2));
    float2 fr = frac(lattice);
    float y0 = nmn_blendBicubic(x0y0, x1y0, x2y0, x3y0, fr.x);
    float y1 = nmn_blendBicubic(x0y1, x1y1, x2y1, x3y1, fr.x);
    float y2 = nmn_blendBicubic(x0y2, x1y2, x2y2, x3y2, fr.x);
    float y3 = nmn_blendBicubic(x0y3, x1y3, x2y3, x3y3, fr.x);
    return nmn_blendBicubic(y0, y1, y2, y3, fr.y);
}

float nmn_catmullRom3x3ValueNoise(float2 st, float2 freq, float s, float blend)
{
    float2 lattice = st * freq;
    float2 f = frac(lattice);
    float v00 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2(-1, -1));
    float v10 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2( 0, -1));
    float v20 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2( 1, -1));
    float v01 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2(-1,  0));
    float v11 = nmn_constantFromLattice(lattice, freq, s, blend);
    float v21 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2( 1,  0));
    float v02 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2(-1,  1));
    float v12 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2( 0,  1));
    float v22 = nmn_constantFromLatticeWithOffset(lattice, freq, s, blend, int2( 1,  1));
    float y0 = nmn_catmullRom3(v00, v10, v20, f.x);
    float y1 = nmn_catmullRom3(v01, v11, v21, f.x);
    float y2 = nmn_catmullRom3(v02, v12, v22, f.x);
    return nmn_catmullRom3(y0, y1, y2, f.y);
}

float nmn_catmullRom4x4ValueNoise(float2 st, float2 freq, float s, float blend)
{
    float2 lattice = st * freq;
    float x0y0 = nmn_constantOffset(lattice, freq, s, blend, int2(-1, -1));
    float x0y1 = nmn_constantOffset(lattice, freq, s, blend, int2(-1, 0));
    float x0y2 = nmn_constantOffset(lattice, freq, s, blend, int2(-1, 1));
    float x0y3 = nmn_constantOffset(lattice, freq, s, blend, int2(-1, 2));
    float x1y0 = nmn_constantOffset(lattice, freq, s, blend, int2(0, -1));
    float x1y1 = nmn_constantFromLattice(lattice, freq, s, blend);
    float x1y2 = nmn_constantOffset(lattice, freq, s, blend, int2(0, 1));
    float x1y3 = nmn_constantOffset(lattice, freq, s, blend, int2(0, 2));
    float x2y0 = nmn_constantOffset(lattice, freq, s, blend, int2(1, -1));
    float x2y1 = nmn_constantOffset(lattice, freq, s, blend, int2(1, 0));
    float x2y2 = nmn_constantOffset(lattice, freq, s, blend, int2(1, 1));
    float x2y3 = nmn_constantOffset(lattice, freq, s, blend, int2(1, 2));
    float x3y0 = nmn_constantOffset(lattice, freq, s, blend, int2(2, -1));
    float x3y1 = nmn_constantOffset(lattice, freq, s, blend, int2(2, 0));
    float x3y2 = nmn_constantOffset(lattice, freq, s, blend, int2(2, 1));
    float x3y3 = nmn_constantOffset(lattice, freq, s, blend, int2(2, 2));
    float2 fr = frac(lattice);
    float y0 = nmn_catmullRom4(x0y0, x1y0, x2y0, x3y0, fr.x);
    float y1 = nmn_catmullRom4(x0y1, x1y1, x2y1, x3y1, fr.x);
    float y2 = nmn_catmullRom4(x0y2, x1y2, x2y2, x3y2, fr.x);
    float y3 = nmn_catmullRom4(x0y3, x1y3, x2y3, x3y3, fr.x);
    return nmn_catmullRom4(y0, y1, y2, y3, fr.y);
}

// Simplex (Ashima 2D) helpers — verbatim constants.
float3 nmn_mod289v3(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float2 nmn_mod289v2(float2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float3 nmn_permute(float3 x)  { return nmn_mod289v3(((x*34.0)+1.0)*x); }

float nmn_simplexValue(float2 st, float2 freq, float s, float blend)
{
    float4 C = float4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
    float2 uv = st * freq;
    uv.x += s;
    float2 i = floor(uv + dot(uv, C.yy));
    float2 x0 = uv - i + dot(i, C.xx);
    // WGSL: select(vec2(0,1), vec2(1,0), x0.x > x0.y) -> cond ? trueVal : falseVal
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12 = float4(x12.xy - i1, x12.zw);
    float2 ii = nmn_mod289v2(i);
    float3 p = nmn_permute(nmn_permute(ii.y + float3(0.0, i1.y, 1.0)) + ii.x + float3(0.0, i1.x, 1.0));
    float3 m = max(float3(0.5, 0.5, 0.5) - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), float3(0.0, 0.0, 0.0));
    m = m * m;
    m = m * m;
    float3 x = 2.0 * frac(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0*a0 + h*h);
    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.y = a0.y * x12.x + h.y * x12.y;
    g.z = a0.z * x12.z + h.z * x12.w;
    float v = 130.0 * dot(m, g);
    return nm_periodicFunction(nm_map(v, -1.0, 1.0, 0.0, 1.0) - blend);
}

float nmn_sineNoise(float2 st, float2 freq, float s, float blend)
{
    float2 stt = st * freq;
    stt.x += s;
    float a = blend;
    float b = blend;
    float c = 1.0 - blend;
    float3 r1 = nm_prng(float3(s, s, s)) * 0.75 + 0.125;
    float3 r2 = nm_prng(float3(s + 10.0, s + 10.0, s + 10.0)) * 0.75 + 0.125;
    float x = sin(r1.x * stt.y + sin(r1.y * stt.x + a) + sin(r1.z * stt.x + b) + c);
    float y = sin(r2.x * stt.x + sin(r2.y * stt.y + b) + sin(r2.z * stt.y + c) + a);
    return (x + y) * 0.5 + 0.5;
}

// value() dispatch by NOISE_TYPE (runtime branch; const-folds when uniform fixed).
float nmn_value(float2 st, float2 freq, float s, float blend)
{
    [branch] if (NOISE_TYPE == 3)  { return nmn_catmullRom3x3ValueNoise(st, freq, s, blend); }
    [branch] if (NOISE_TYPE == 4)  { return nmn_catmullRom4x4ValueNoise(st, freq, s, blend); }
    [branch] if (NOISE_TYPE == 5)  { return nmn_cubic3x3ValueNoise(st, freq, s, blend); }
    [branch] if (NOISE_TYPE == 6)  { return nmn_bicubicValue(st, freq, s, blend); }
    [branch] if (NOISE_TYPE == 10) { return nmn_simplexValue(st, freq, s, blend); }
    [branch] if (NOISE_TYPE == 11) { return nmn_sineNoise(st, freq, s, blend); }

    float2 lattice = st * freq;
    float x1y1 = nmn_constantFromLattice(lattice, freq, s, blend);
    [branch] if (NOISE_TYPE == 0) { return x1y1; }

    float x2y1 = nmn_constantOffset(lattice, freq, s, blend, int2(1, 0));
    float x1y2 = nmn_constantOffset(lattice, freq, s, blend, int2(0, 1));
    float x2y2 = nmn_constantOffset(lattice, freq, s, blend, int2(1, 1));
    float2 fr = frac(lattice);
    float aa = nmn_blendLinearOrCosine(x1y1, x2y1, fr.x, NOISE_TYPE);
    float bb = nmn_blendLinearOrCosine(x1y2, x2y2, fr.x, NOISE_TYPE);
    return nmn_blendLinearOrCosine(aa, bb, fr.y, NOISE_TYPE);
}

// ---- offset() shape helpers ----------------------------------------------
// These take `aspectRatio` (= fullResolution.x/fullResolution.y, the macro the
// GLSL uses; the WGSL `aspectRatio` private equals the same packed value) and
// `resolution`/PI/TAU. Passed explicitly so the function is self-contained.
float nmn_circles(float2 st, float freq, float aspect)
{
    float dist = length(st - float2(0.5 * aspect, 0.5));
    return dist * freq;
}

float nmn_rings(float2 st, float freq, float aspect)
{
    float dist = length(st - float2(0.5 * aspect, 0.5));
    return cos(dist * PI * freq);
}

float nmn_diamonds(float2 st, float freq, float2 pos, float aspect)
{
    // WGSL uses resolution.y here (NOT fullResolution.y) — preserve (spec H2).
    float2 stt = pos / resolution.y;
    stt -= float2(0.5 * aspect, 0.5);
    stt *= freq;
    return (cos(stt.x * PI) + cos(stt.y * PI));
}

// shape(): atan2(stt.x, stt.y) — copy arg order LITERALLY (spec H3).
float nmn_shape(float2 st, int sides, float blend, float aspect)
{
    float2 stt = st * 2.0 - float2(aspect, 1.0);
    float a = atan2(stt.x, stt.y) + PI;
    float r = TAU / (float)sides;
    return cos(floor(0.5 + a / r) * r - a) * length(stt) * blend;
}

// offset() dispatch by LOOP_OFFSET. `seed` (float) read from the global uniform.
float nmn_offset(float2 st, float2 freq, float2 pos, float aspect)
{
    [branch] if (LOOP_OFFSET == 10)  { return nmn_circles(st, freq.x, aspect); }
    [branch] if (LOOP_OFFSET == 20)  { return nmn_shape(st, 3, freq.x * 0.5, aspect); }
    [branch] if (LOOP_OFFSET == 30)  { return (abs(st.x - 0.5 * aspect) + abs(st.y - 0.5)) * freq.x * 0.5; }
    [branch] if (LOOP_OFFSET == 40)  { return nmn_shape(st, 4, freq.x * 0.5, aspect); }
    [branch] if (LOOP_OFFSET == 50)  { return nmn_shape(st, 5, freq.x * 0.5, aspect); }
    [branch] if (LOOP_OFFSET == 60)  { return nmn_shape(st, 6, freq.x * 0.5, aspect); }
    [branch] if (LOOP_OFFSET == 70)  { return nmn_shape(st, 7, freq.x * 0.5, aspect); }
    [branch] if (LOOP_OFFSET == 80)  { return nmn_shape(st, 8, freq.x * 0.5, aspect); }
    [branch] if (LOOP_OFFSET == 90)  { return nmn_shape(st, 9, freq.x * 0.5, aspect); }
    [branch] if (LOOP_OFFSET == 100) { return nmn_shape(st, 10, freq.x * 0.5, aspect); }
    [branch] if (LOOP_OFFSET == 110) { return nmn_shape(st, 11, freq.x * 0.5, aspect); }
    [branch] if (LOOP_OFFSET == 120) { return nmn_shape(st, 12, freq.x * 0.5, aspect); }
    [branch] if (LOOP_OFFSET == 200) { return st.x * freq.x * 0.5; }
    [branch] if (LOOP_OFFSET == 210) { return st.y * freq.x * 0.5; }
    [branch] if (LOOP_OFFSET == 300)
    {
        float2 stt = st - float2(aspect * 0.5, 0.5);
        return nmn_value(stt, freq, seed + 50.0, 0.0);
    }
    [branch] if (LOOP_OFFSET == 400) { return 1.0 - nmn_rings(st, freq.x, aspect); }
    [branch] if (LOOP_OFFSET == 410) { return 1.0 - nmn_diamonds(st, freq.x, pos, aspect); }
    return 0.0;
}

float3 nmn_generate_octave(float2 st, float2 freq, float s, float blend, float layer)
{
    float3 color = float3(0.0, 0.0, 0.0);
    color.r = nmn_value(st, freq, s, blend);
    color.g = nmn_value(st, freq, s + 10.0, blend);
    color.b = nmn_value(st, freq, s + 20.0, blend);
    return color;
}

float3 nmn_multires(float2 st_in, float2 freq, int oct, float s, float blend)
{
    float2 st = st_in;
    float3 color = float3(0.0, 0.0, 0.0);
    float multiplicand = 0.0;

    [loop] for (int i = 1; i <= oct; i++)
    {
        float multiplier = pow(2.0, (float)i);
        float2 baseFreq = freq * 0.5 * multiplier;
        multiplicand += 1.0 / multiplier;

        float3 layer = nmn_generate_octave(st, baseFreq, s + 10.0 * (float)i, blend, (float)i);

        color = color + layer / multiplier;
    }

    color = color / multiplicand;

    // Simplified colorization: mono (0) or rgb (1) only.
    if (colorMode == 0)
    {
        // mono - use blue channel
        float b = color.b;
        if (ridges > 0.5) { b = 1.0 - abs(b * 2.0 - 1.0); }
        return float3(b, b, b);
    }
    else
    {
        // rgb
        if (ridges > 0.5)
        {
            color.r = 1.0 - abs(color.r * 2.0 - 1.0);
            color.g = 1.0 - abs(color.g * 2.0 - 1.0);
            color.b = 1.0 - abs(color.b * 2.0 - 1.0);
        }
        return color;
    }
}

// -----------------------------------------------------------------------------
// nm_noise — the effect core. Mirrors noise.wgsl `main()` exactly.
//   fragCoord = position.xy (raw, pixel-centered top-left frag coord, NO tile
//               offset) — this is what WGSL passes as `pos` to offset().
//   tileOff   = per-tile pixel offset (0 when untiled).
//   fullRes   = full untiled size; st divides by fullRes.y (HEIGHT).
// st = (fragCoord + tileOffset) / fullResolution.y, matching the WGSL.
// Returns RGBA (alpha = 1).
// -----------------------------------------------------------------------------
float4 nm_noise(float2 fragCoord, float2 tileOff, float2 fullRes)
{
    float aspect = fullRes.x / fullRes.y;

    float4 color = float4(0.0, 0.0, 0.0, 1.0);
    float2 st = (fragCoord + tileOff) / fullRes.y;
    float2 centered = st - float2(aspect * 0.5, 0.5);

    float2 freq = float2(1.0, 1.0);
    float2 lf   = float2(1.0, 1.0);

    if (NOISE_TYPE == 11)
    {
        freq.x = nm_map(scaleX, 1.0, 100.0, 40.0, 1.0);
        freq.y = nm_map(scaleY, 1.0, 100.0, 40.0, 1.0);
        lf = float2(nm_map(loopScale, 1.0, 100.0, 10.0, 1.0), nm_map(loopScale, 1.0, 100.0, 10.0, 1.0));
    }
    else if (NOISE_TYPE == 10)
    {
        freq.x = nm_map(scaleX, 1.0, 100.0, 6.0, 0.5);
        freq.y = nm_map(scaleY, 1.0, 100.0, 6.0, 0.5);
        lf = float2(nm_map(loopScale, 1.0, 100.0, 6.0, 0.5), nm_map(loopScale, 1.0, 100.0, 6.0, 0.5));
    }
    else
    {
        freq.x = nm_map(scaleX, 1.0, 100.0, 20.0, 3.0);
        freq.y = nm_map(scaleY, 1.0, 100.0, 20.0, 3.0);
        lf = float2(nm_map(loopScale, 1.0, 100.0, 12.0, 3.0), nm_map(loopScale, 1.0, 100.0, 12.0, 3.0));
    }

    if (LOOP_OFFSET == 300)
    {
        float2 nominalFreq = float2(1.0, 1.0);
        if (NOISE_TYPE == 11)
        {
            float base = nm_map(75.0, 1.0, 100.0, 40.0, 1.0);
            nominalFreq = float2(base, base);
        }
        else if (NOISE_TYPE == 10)
        {
            float base = nm_map(75.0, 1.0, 100.0, 6.0, 0.5);
            nominalFreq = float2(base, base);
        }
        else
        {
            float base = nm_map(75.0, 1.0, 100.0, 20.0, 3.0);
            nominalFreq = float2(base, base);
        }
        lf *= freq / nominalFreq;
    }

    if (NOISE_TYPE != 4 && NOISE_TYPE != 10 && wrap > 0.5)
    {
        freq = floor(freq);
        if (LOOP_OFFSET == 300)
        {
            lf = floor(lf);
        }
    }

    float t = 1.0;
    if (speed < 0.0)
    {
        t = time + nmn_offset(st, lf, fragCoord, aspect);
    }
    else
    {
        t = time - nmn_offset(st, lf, fragCoord, aspect);
    }
    float blend = nm_periodicFunction(t) * abs(speed) * 0.01;

    color = float4(nmn_multires(centered, freq, octaves, seed, blend), 1.0);
    return color;
}

#endif // NM_EFFECT_NOISE_INCLUDED
