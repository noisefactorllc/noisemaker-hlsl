#ifndef NM_MOODSCAPE_INCLUDED
#define NM_MOODSCAPE_INCLUDED

// =============================================================================
// Moodscape.hlsl — classicNoisedeck/moodscape, ported PIXEL-IDENTICALLY from
// the canonical WGSL source:
//   shaders/effects/classicNoisedeck/moodscape/wgsl/moodscape.wgsl
//
// Refracted value noise with multiple color modes. Single render pass,
// generator (no texture inputs).
//
// Helpers are ported VERBATIM and INLINE per PORTING-GUIDE.
//  * This effect's `periodicFunction` uses sin():
//      map(sin(p*TAU), -1, 1, 0, 1)
//    which DIFFERS from NMCore's nm_periodicFunction (cos). Ported inline.
//  * `modulo`, `map`, `pcg`, `prng`, `positiveModulo` are bit-identical to
//    NMCore's nm_* equivalents — the only sanctioned sharing — so they are
//    reused from NMCore (nm_mod / nm_map / nm_pcg / nm_prng /
//    nm_positiveModulo).
//  * hsv2rgb / rgb2hsv / linearToSrgb / oklab matrices are this effect's OWN
//    versions; copied inline.
//
// NUMERIC HAZARDS handled:
//  * st = (globalCoord) / fullResolution.y  (DIVIDES BY HEIGHT only), then
//    st -= (fullRes.x/fullRes.y*0.5, 0.5).  (matches WGSL main())
//  * NOISE_TYPE / COLOR_MODE were compile-time defines; here they are runtime
//    int uniforms branched with [branch] (PORTING-GUIDE §uniform model). The
//    WGSL path itself keeps all variants and const-folds.
//  * randomFromLatticeWithOffset: bitcast<u32>(xi)/(yi)/(seed) -> asuint(...)
//    (bit reinterpret); bitcast<u32>(seedFrac) -> asuint(seedFrac). i32(...) of
//    a float is (int) truncation. positiveModulo on ints.
//  * prng fold variant; divisor 4294967295.0 (NOT 2^32); (uint3)q TRUNCATION.
//  * select(b,a,cond) in WGSL == cond ? a : b in HLSL — reversed args.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- NOISE_TYPE / COLOR_MODE compile-time-define-promoted int uniforms ------
#ifndef NM_MS_NOISE_TYPE_DEFAULT
#define NM_MS_NOISE_TYPE_DEFAULT 10
#endif
#ifndef NM_MS_COLOR_MODE_DEFAULT
#define NM_MS_COLOR_MODE_DEFAULT 2
#endif
int NOISE_TYPE;     // was globals.interp.define     = "NOISE_TYPE"
int COLOR_MODE;     // was globals.colorMode.define   = "COLOR_MODE"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
float noiseScale;   // global "noiseScale"
float speed;        // global "speed"
float refractAmt;   // global "refractAmt"
int   ridges;       // global "ridges"   (boolean as 0/1; WGSL tests > 0)
int   wrap;         // global "wrap"      (boolean as 0/1; WGSL tests > 0)
int   seed;         // global "seed"      (i32 in WGSL)
float hueRotation;  // global "hueRotation"
float hueRange;     // global "hueRange"
float intensity;    // global "intensity"

// PI / TAU exactly as in the WGSL source.
static const float PI  = 3.14159265359;
static const float TAU = 6.28318530718;

// modulo / map are bit-identical to NMCore nm_mod / nm_map (shared).

// ---- periodicFunction (THIS effect's sin variant; NOT NMCore cos) -----------
float nmms_periodicFunction(float p)
{
    return nm_map(sin(p * TAU), -1.0, 1.0, 0.0, 1.0);
}

// ---- brightnessContrast -----------------------------------------------------
float3 nmms_brightnessContrast(float3 color)
{
    float bright = nm_map(intensity, -100.0, 100.0, -0.4, 0.4);
    float cont = 1.0;
    if (intensity < 0.0)
    {
        cont = nm_map(intensity, -100.0, 0.0, 0.5, 1.0);
    }
    else
    {
        cont = nm_map(intensity, 0.0, 100.0, 1.0, 1.5);
    }

    return (color - 0.5) * cont + 0.5 + bright;
}

// ---- hsv2rgb (this effect's own version) ------------------------------------
float3 nmms_hsv2rgb(float3 hsv)
{
    float h = frac(hsv.x);
    float s = hsv.y;
    float v = hsv.z;

    float c = v * s;
    float x = c * (1.0 - abs(nm_mod(h * 6.0, 2.0) - 1.0));
    float m = v - c;

    float3 rgb;

    if (0.0 <= h && h < 1.0 / 6.0)
    {
        rgb = float3(c, x, 0.0);
    }
    else if (1.0 / 6.0 <= h && h < 2.0 / 6.0)
    {
        rgb = float3(x, c, 0.0);
    }
    else if (2.0 / 6.0 <= h && h < 3.0 / 6.0)
    {
        rgb = float3(0.0, c, x);
    }
    else if (3.0 / 6.0 <= h && h < 4.0 / 6.0)
    {
        rgb = float3(0.0, x, c);
    }
    else if (4.0 / 6.0 <= h && h < 5.0 / 6.0)
    {
        rgb = float3(x, 0.0, c);
    }
    else if (5.0 / 6.0 <= h && h < 1.0)
    {
        rgb = float3(c, 0.0, x);
    }
    else
    {
        rgb = float3(0.0, 0.0, 0.0);
    }

    return rgb + float3(m, m, m);
}

// ---- rgb2hsv (this effect's own version) ------------------------------------
float3 nmms_rgb2hsv(float3 rgb)
{
    float r = rgb.r;
    float g = rgb.g;
    float b = rgb.b;

    float maxc = max(r, max(g, b));
    float minc = min(r, min(g, b));
    float delta = maxc - minc;

    float h = 0.0;
    if (delta != 0.0)
    {
        if (maxc == r)
        {
            h = nm_mod((g - b) / delta, 6.0) / 6.0;
        }
        else if (maxc == g)
        {
            h = ((b - r) / delta + 2.0) / 6.0;
        }
        else if (maxc == b)
        {
            h = ((r - g) / delta + 4.0) / 6.0;
        }
    }

    // WGSL: select(delta/maxc, 0.0, maxc == 0.0) == (maxc==0.0) ? 0.0 : delta/maxc
    float s = (maxc == 0.0) ? 0.0 : (delta / maxc);
    float v = maxc;

    return float3(h, s, v);
}

// ---- linearToSrgb (this effect's own version) -------------------------------
float3 nmms_linearToSrgb(float3 linearC)
{
    float3 srgb;
    [unroll]
    for (int i = 0; i < 3; i = i + 1)
    {
        if (linearC[i] <= 0.0031308)
        {
            srgb[i] = linearC[i] * 12.92;
        }
        else
        {
            srgb[i] = 1.055 * pow(linearC[i], 1.0 / 2.4) - 0.055;
        }
    }
    return srgb;
}

// ---- oklab forward matrices (column-major in WGSL) --------------------------
// WGSL mat3x3 columns are the constructor args; M * c (column vector) =
// sum_j column_j * c[j]. Written out by hand to avoid HLSL row-major transpose.
//   fwdA columns: (1,1,1), (0.3963..,-0.1055..,-0.0894..), (0.2158..,-0.0638..,-1.2914..)
//   fwdB columns: (4.0767..,-1.2681..,-0.0041..), (-3.3072..,2.6093..,-0.7034..), (0.2307..,-0.3411..,1.7068..)
float3 nmms_linear_srgb_from_oklab(float3 c)
{
    // lms = fwdA * c
    float3 colA = float3(1.0, 1.0, 1.0);
    float3 colB = float3(0.3963377774, -0.1055613458, -0.0894841775);
    float3 colC = float3(0.2158037573, -0.0638541728, -1.2914855480);
    float3 lms = colA * c.x + colB * c.y + colC * c.z;

    float3 cube = lms * lms * lms;

    // fwdB * cube
    float3 dA = float3(4.0767245293, -1.2681437731, -0.0041119885);
    float3 dB = float3(-3.3072168827, 2.6093323231, -0.7034763098);
    float3 dC = float3(0.2307590544, -0.3411344290, 1.7068625689);
    return dA * cube.x + dB * cube.y + dC * cube.z;
}

// ---- prng (this WGSL's own copy; bit-identical to NMCore nm_prng) -----------
// q.x = select(-q.x*2+1, q.x*2, q.x >= 0) == (q.x >= 0) ? q.x*2 : -q.x*2+1
float3 nmms_prng(float3 p)
{
    float3 q = p;
    q.x = (q.x >= 0.0) ? q.x * 2.0 : -q.x * 2.0 + 1.0;
    q.y = (q.y >= 0.0) ? q.y * 2.0 : -q.y * 2.0 + 1.0;
    q.z = (q.z >= 0.0) ? q.z * 2.0 : -q.z * 2.0 + 1.0;
    return float3(nm_pcg((uint3)q)) / 4294967295.0;
}

// ---- Simplex 2D (this effect's own helpers) ---------------------------------
float3 nmms_mod289_3(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float2 nmms_mod289_2(float2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float3 nmms_permute(float3 x)  { return nmms_mod289_3(((x * 34.0) + 1.0) * x); }

float nmms_simplexValue(float2 st, float xFreq, float yFreq, float s, float blend)
{
    const float4 C = float4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);

    float2 uv = float2(st.x * xFreq, st.y * yFreq);
    uv.x += s;

    float2 i = floor(uv + dot(uv, C.yy));
    float2 x0 = uv - i + dot(i, C.xx);

    // select(vec2(0,1), vec2(1,0), x0.x > x0.y) == (x0.x > x0.y) ? (1,0) : (0,1)
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float2 x1 = x0 - i1 + float2(C.x, C.x);
    float2 x2 = x0 - float2(1.0, 1.0) + float2(2.0 * C.x, 2.0 * C.x);
    float2 x12xz = float2(x1.x, x2.x);
    float2 x12yw = float2(x1.y, x2.y);

    i = nmms_mod289_2(i);
    float3 p = nmms_permute(nmms_permute(i.y + float3(0.0, i1.y, 1.0))
                            + i.x + float3(0.0, i1.x, 1.0));

    float3 m = max(float3(0.5, 0.5, 0.5) - float3(dot(x0, x0), dot(x1, x1), dot(x2, x2)), float3(0.0, 0.0, 0.0));
    m = m * m;
    m = m * m;

    float3 x = 2.0 * frac(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;

    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);

    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    float2 gyz = a0.yz * x12xz + h.yz * x12yw;
    g.y = gyz.x;
    g.z = gyz.y;

    float v = 130.0 * dot(m, g);

    return nmms_periodicFunction(nm_map(v, -1.0, 1.0, 0.0, 1.0) - blend);
}

float nmms_sineNoise(float2 st, float xFreq, float yFreq, float s, float blend)
{
    float2 uv = float2(st.x * xFreq, st.y * yFreq);
    uv.x += s;

    float a = blend;
    float b = blend;
    float c = 1.0 - blend;

    float3 r1 = nmms_prng(float3(s, 0.0, 0.0)) * 0.75 + 0.125;
    float3 r2 = nmms_prng(float3(s + 10.0, 0.0, 0.0)) * 0.75 + 0.125;
    float x = sin(r1.x * uv.y + sin(r1.y * uv.x + a) + sin(r1.z * uv.x + b) + c);
    float y = sin(r2.x * uv.x + sin(r2.y * uv.y + b) + sin(r2.z * uv.y + c) + a);

    return (x + y) * 0.5 + 0.5;
}

// ---- Value noise: randomFromLatticeWithOffset -------------------------------
// positiveModulo is bit-identical to NMCore nm_positiveModulo (shared).
float3 nmms_randomFromLatticeWithOffset(float2 st, float xFreq, float yFreq, float s, int2 offset)
{
    float2 lattice = float2(st.x * xFreq, st.y * yFreq);
    float2 baseFloor = floor(lattice);
    int2 base = int2((int)baseFloor.x, (int)baseFloor.y) + offset;
    float2 fracL = lattice - baseFloor;

    int seedInt = (int)floor(s);
    float seedFrac = frac(s);

    int xi = base.x + seedInt + (int)floor(fracL.x + seedFrac);
    int yi = base.y;

    if (wrap > 0)
    {
        int freqXInt = (int)(xFreq + 0.5);
        int freqYInt = (int)(yFreq + 0.5);

        if (freqXInt > 0)
        {
            xi = nm_positiveModulo(xi, freqXInt);
        }
        if (freqYInt > 0)
        {
            yi = nm_positiveModulo(yi, freqYInt);
        }
    }

    uint xBits = asuint(xi);
    uint yBits = asuint(yi);
    uint seedBits = asuint(seed);
    uint fracBits = asuint(seedFrac);

    uint3 jitter = uint3(
        (fracBits * 374761393u) ^ 0x9E3779B9u,
        (fracBits * 668265263u) ^ 0x7F4A7C15u,
        (fracBits * 2246822519u) ^ 0x94D049B4u
    );

    uint3 state = uint3(xBits, yBits, seedBits) ^ jitter;
    uint3 prngState = nm_pcg(state);
    float denom = 4294967295.0;
    return float3(
        (float)prngState.x / denom,
        (float)prngState.y / denom,
        (float)prngState.z / denom
    );
}

float nmms_constant(float2 st, float xFreq, float yFreq, float s)
{
    float3 rand = nmms_randomFromLatticeWithOffset(st, xFreq, yFreq, s, int2(0, 0));
    float scaledTime = nmms_periodicFunction(rand.x - time) * nm_map(abs(speed), 0.0, 100.0, 0.0, 0.25);
    return nmms_periodicFunction(rand.y - scaledTime);
}

float nmms_constantOffset(float2 st, float xFreq, float yFreq, float s, int2 offset)
{
    float3 rand = nmms_randomFromLatticeWithOffset(st, xFreq, yFreq, s, offset);
    float scaledTime = nmms_periodicFunction(rand.x - time) * nm_map(abs(speed), 0.0, 100.0, 0.0, 0.25);
    return nmms_periodicFunction(rand.y - scaledTime);
}

float nmms_quadratic3(float p0, float p1, float p2, float t)
{
    float t2 = t * t;
    return p0 * 0.5 * (1.0 - t) * (1.0 - t) +
           p1 * 0.5 * (-2.0 * t2 + 2.0 * t + 1.0) +
           p2 * 0.5 * t2;
}

// catmullRom3 — deliberately redundant `4.0*p2 - p0` / `-3.0*p2 + p0` terms;
// reproduced LITERALLY (PORTING-GUIDE H10). Do NOT simplify.
float nmms_catmullRom3(float p0, float p1, float p2, float t)
{
    float t2 = t * t;
    float t3 = t2 * t;

    return p1 + 0.5 * t * (p2 - p0) +
           0.5 * t2 * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p0) +
           0.5 * t3 * (-p0 + 3.0 * p1 - 3.0 * p2 + p0);
}

float nmms_quadratic3x3Value(float2 st, float xFreq, float yFreq, float s)
{
    float2 lattice = float2(st.x * xFreq, st.y * yFreq);
    float2 f = frac(lattice);

    float v00 = nmms_constantOffset(st, xFreq, yFreq, s, int2(-1, -1));
    float v10 = nmms_constantOffset(st, xFreq, yFreq, s, int2(0, -1));
    float v20 = nmms_constantOffset(st, xFreq, yFreq, s, int2(1, -1));

    float v01 = nmms_constantOffset(st, xFreq, yFreq, s, int2(-1, 0));
    float v11 = nmms_constantOffset(st, xFreq, yFreq, s, int2(0, 0));
    float v21 = nmms_constantOffset(st, xFreq, yFreq, s, int2(1, 0));

    float v02 = nmms_constantOffset(st, xFreq, yFreq, s, int2(-1, 1));
    float v12 = nmms_constantOffset(st, xFreq, yFreq, s, int2(0, 1));
    float v22 = nmms_constantOffset(st, xFreq, yFreq, s, int2(1, 1));

    float y0 = nmms_quadratic3(v00, v10, v20, f.x);
    float y1 = nmms_quadratic3(v01, v11, v21, f.x);
    float y2 = nmms_quadratic3(v02, v12, v22, f.x);

    return nmms_quadratic3(y0, y1, y2, f.y);
}

float nmms_catmullRom3x3Value(float2 st, float xFreq, float yFreq, float s)
{
    float2 lattice = float2(st.x * xFreq, st.y * yFreq);
    float2 f = frac(lattice);

    float v00 = nmms_constantOffset(st, xFreq, yFreq, s, int2(-1, -1));
    float v10 = nmms_constantOffset(st, xFreq, yFreq, s, int2(0, -1));
    float v20 = nmms_constantOffset(st, xFreq, yFreq, s, int2(1, -1));

    float v01 = nmms_constantOffset(st, xFreq, yFreq, s, int2(-1, 0));
    float v11 = nmms_constantOffset(st, xFreq, yFreq, s, int2(0, 0));
    float v21 = nmms_constantOffset(st, xFreq, yFreq, s, int2(1, 0));

    float v02 = nmms_constantOffset(st, xFreq, yFreq, s, int2(-1, 1));
    float v12 = nmms_constantOffset(st, xFreq, yFreq, s, int2(0, 1));
    float v22 = nmms_constantOffset(st, xFreq, yFreq, s, int2(1, 1));

    float y0 = nmms_catmullRom3(v00, v10, v20, f.x);
    float y1 = nmms_catmullRom3(v01, v11, v21, f.x);
    float y2 = nmms_catmullRom3(v02, v12, v22, f.x);

    return nmms_catmullRom3(y0, y1, y2, f.y);
}

float nmms_blendBicubic(float p0, float p1, float p2, float p3, float t)
{
    float t2 = t * t;
    float t3 = t2 * t;

    float b0 = (1.0 - t) * (1.0 - t) * (1.0 - t) / 6.0;
    float b1 = (3.0 * t3 - 6.0 * t2 + 4.0) / 6.0;
    float b2 = (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) / 6.0;
    float b3 = t3 / 6.0;

    return p0 * b0 + p1 * b1 + p2 * b2 + p3 * b3;
}

// catmullRom4 — nested redundant form; reproduced LITERALLY.
float nmms_catmullRom4(float p0, float p1, float p2, float p3, float t)
{
    return p1 + 0.5 * t * (p2 - p0 + t * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 +
           t * (3.0 * (p1 - p2) + p3 - p0)));
}

float nmms_blendLinearOrCosine(float a, float b, float amount, int nType)
{
    if (nType == 1)
    {
        return lerp(a, b, amount);
    }
    return lerp(a, b, smoothstep(0.0, 1.0, amount));
}

float nmms_bicubicValue(float2 st, float xFreq, float yFreq, float s)
{
    float x0y0 = nmms_constantOffset(st, xFreq, yFreq, s, int2(-1, -1));
    float x0y1 = nmms_constantOffset(st, xFreq, yFreq, s, int2(-1, 0));
    float x0y2 = nmms_constantOffset(st, xFreq, yFreq, s, int2(-1, 1));
    float x0y3 = nmms_constantOffset(st, xFreq, yFreq, s, int2(-1, 2));

    float x1y0 = nmms_constantOffset(st, xFreq, yFreq, s, int2(0, -1));
    float x1y1 = nmms_constantOffset(st, xFreq, yFreq, s, int2(0, 0));
    float x1y2 = nmms_constantOffset(st, xFreq, yFreq, s, int2(0, 1));
    float x1y3 = nmms_constantOffset(st, xFreq, yFreq, s, int2(0, 2));

    float x2y0 = nmms_constantOffset(st, xFreq, yFreq, s, int2(1, -1));
    float x2y1 = nmms_constantOffset(st, xFreq, yFreq, s, int2(1, 0));
    float x2y2 = nmms_constantOffset(st, xFreq, yFreq, s, int2(1, 1));
    float x2y3 = nmms_constantOffset(st, xFreq, yFreq, s, int2(1, 2));

    float x3y0 = nmms_constantOffset(st, xFreq, yFreq, s, int2(2, -1));
    float x3y1 = nmms_constantOffset(st, xFreq, yFreq, s, int2(2, 0));
    float x3y2 = nmms_constantOffset(st, xFreq, yFreq, s, int2(2, 1));
    float x3y3 = nmms_constantOffset(st, xFreq, yFreq, s, int2(2, 2));

    float2 uv = float2(st.x * xFreq, st.y * yFreq);

    float y0 = nmms_blendBicubic(x0y0, x1y0, x2y0, x3y0, frac(uv.x));
    float y1 = nmms_blendBicubic(x0y1, x1y1, x2y1, x3y1, frac(uv.x));
    float y2 = nmms_blendBicubic(x0y2, x1y2, x2y2, x3y2, frac(uv.x));
    float y3 = nmms_blendBicubic(x0y3, x1y3, x2y3, x3y3, frac(uv.x));

    return clamp(nmms_blendBicubic(y0, y1, y2, y3, frac(uv.y)), 0.0, 1.0);
}

float nmms_catmullRom4x4Value(float2 st, float xFreq, float yFreq, float s)
{
    float x0y0 = nmms_constantOffset(st, xFreq, yFreq, s, int2(-1, -1));
    float x0y1 = nmms_constantOffset(st, xFreq, yFreq, s, int2(-1, 0));
    float x0y2 = nmms_constantOffset(st, xFreq, yFreq, s, int2(-1, 1));
    float x0y3 = nmms_constantOffset(st, xFreq, yFreq, s, int2(-1, 2));

    float x1y0 = nmms_constantOffset(st, xFreq, yFreq, s, int2(0, -1));
    float x1y1 = nmms_constantOffset(st, xFreq, yFreq, s, int2(0, 0));
    float x1y2 = nmms_constantOffset(st, xFreq, yFreq, s, int2(0, 1));
    float x1y3 = nmms_constantOffset(st, xFreq, yFreq, s, int2(0, 2));

    float x2y0 = nmms_constantOffset(st, xFreq, yFreq, s, int2(1, -1));
    float x2y1 = nmms_constantOffset(st, xFreq, yFreq, s, int2(1, 0));
    float x2y2 = nmms_constantOffset(st, xFreq, yFreq, s, int2(1, 1));
    float x2y3 = nmms_constantOffset(st, xFreq, yFreq, s, int2(1, 2));

    float x3y0 = nmms_constantOffset(st, xFreq, yFreq, s, int2(2, -1));
    float x3y1 = nmms_constantOffset(st, xFreq, yFreq, s, int2(2, 0));
    float x3y2 = nmms_constantOffset(st, xFreq, yFreq, s, int2(2, 1));
    float x3y3 = nmms_constantOffset(st, xFreq, yFreq, s, int2(2, 2));

    float2 uv = float2(st.x * xFreq, st.y * yFreq);

    float y0 = nmms_catmullRom4(x0y0, x1y0, x2y0, x3y0, frac(uv.x));
    float y1 = nmms_catmullRom4(x0y1, x1y1, x2y1, x3y1, frac(uv.x));
    float y2 = nmms_catmullRom4(x0y2, x1y2, x2y2, x3y2, frac(uv.x));
    float y3 = nmms_catmullRom4(x0y3, x1y3, x2y3, x3y3, frac(uv.x));

    return clamp(nmms_catmullRom4(y0, y1, y2, y3, frac(uv.y)), 0.0, 1.0);
}

// value() dispatch by NOISE_TYPE (runtime branch; const-folds when uniform fixed).
float nmms_value(float2 st, float xFreq, float yFreq, float s)
{
    [branch] if (NOISE_TYPE == 0)
    {
        return nmms_constant(st, xFreq, yFreq, s);
    }

    [branch] if (NOISE_TYPE == 3)
    {
        return nmms_catmullRom3x3Value(st, xFreq, yFreq, s);
    }

    [branch] if (NOISE_TYPE == 4)
    {
        return nmms_catmullRom4x4Value(st, xFreq, yFreq, s);
    }

    [branch] if (NOISE_TYPE == 5)
    {
        return nmms_quadratic3x3Value(st, xFreq, yFreq, s);
    }

    [branch] if (NOISE_TYPE == 6)
    {
        return nmms_bicubicValue(st, xFreq, yFreq, s);
    }

    [branch] if (NOISE_TYPE == 10)
    {
        float simplexLoopSample = nmms_simplexValue(st, xFreq, yFreq, s + 50.0, time) * speed * 0.0025;
        return nmms_simplexValue(st, xFreq, yFreq, s, simplexLoopSample);
    }

    [branch] if (NOISE_TYPE == 11)
    {
        float sineLoopSample = nmms_sineNoise(st, xFreq, yFreq, s + 50.0, time) * speed * 0.0025;
        return nmms_sineNoise(st, xFreq, yFreq, s, sineLoopSample);
    }

    // 1 = linear, 2 = hermite
    float x1y1 = nmms_constantOffset(st, xFreq, yFreq, s, int2(0, 0));
    float x1y2 = nmms_constantOffset(st, xFreq, yFreq, s, int2(0, 1));
    float x2y1 = nmms_constantOffset(st, xFreq, yFreq, s, int2(1, 0));
    float x2y2 = nmms_constantOffset(st, xFreq, yFreq, s, int2(1, 1));

    float2 uv = float2(st.x * xFreq, st.y * yFreq);

    float a = nmms_blendLinearOrCosine(x1y1, x2y1, frac(uv.x), NOISE_TYPE);
    float b = nmms_blendLinearOrCosine(x1y2, x2y2, frac(uv.x), NOISE_TYPE);

    return clamp(nmms_blendLinearOrCosine(a, b, frac(uv.y), NOISE_TYPE), 0.0, 1.0);
}

// =============================================================================
// nm_moodscape — core per-pixel evaluation. `globalCoord` is the fragment pixel
// coord plus tileOffset (NM_GlobalCoord(i)). Mirrors WGSL main() exactly.
// res/fullRes/timeVal are passed in so the Shader Graph wrapper can override.
// =============================================================================
float4 nm_moodscape(float2 globalCoord, float2 res, float2 fullRes, float timeVal)
{
    float4 color = float4(0.0, 0.0, 1.0, 1.0);

    // st = (pos.xy + tileOffset) / fullResolution.y  (DIVIDES BY HEIGHT only)
    float2 st = globalCoord / fullRes.y;
    st -= float2(fullRes.x / fullRes.y * 0.5, 0.5);

    float xFreq = 1.0;
    float yFreq = 1.0;
    if (NOISE_TYPE != 4 && NOISE_TYPE != 10 && wrap > 0)
    {
        xFreq = floor(nm_map(noiseScale, 1.0, 100.0, 3.0, 2.0));
        yFreq = xFreq;
    }
    else
    {
        if (NOISE_TYPE == 10)
        {
            xFreq = nm_map(noiseScale, 1.0, 100.0, 1.0, 0.25);
            yFreq = xFreq * 1.5;
        }
        else
        {
            xFreq = nm_map(noiseScale, 1.0, 100.0, 1.5, 1.0);
            yFreq = xFreq * 1.5;
        }
    }

    float s = floor((float)seed);

    // Refract values
    float xRef = nmms_value(st, xFreq, yFreq, 20.0 + s);
    float yRef = nmms_value(st, xFreq, yFreq, 10.0 + s);

    float refAmt = nm_map(refractAmt, 0.0, 100.0, 0.0, 2.5);
    float2 uv = float2(st.x + xRef * refAmt, st.y + yRef * refAmt);

    float valueR = nmms_value(uv, xFreq, yFreq, s);
    float valueG = nmms_value(uv, xFreq, yFreq, 10.0 + s);
    float valueB = nmms_value(uv, xFreq, yFreq, 20.0 + s);

    float4 grayscaleColor = float4(float3(valueR, valueR, valueR), 1.0);
    float4 rgbColor = float4(valueR, valueG, valueB, 1.0);

    // select(rgbColor, grayscaleColor, COLOR_MODE == 0) == (COLOR_MODE==0) ? gray : rgb
    color = (COLOR_MODE == 0) ? grayscaleColor : rgbColor;

    if (COLOR_MODE == 0)
    {
        // grayscale
        if (ridges > 0)
        {
            color = 1.0 - abs(color * 2.0 - 1.0);
        }
    }
    else if (COLOR_MODE == 1)
    {
        // rgb
        if (ridges > 0)
        {
            color = 1.0 - abs(color * 2.0 - 1.0);
        }
        color = float4(nmms_rgb2hsv(color.rgb), color.a);
        color.r += 1.0 - (hueRotation / 360.0);
        color.r = frac(color.r);
        color = float4(nmms_hsv2rgb(color.rgb), color.a);
    }
    else if (COLOR_MODE == 2)
    {
        // hsv
        color.r = color.r * hueRange * 0.01;
        color.r += 1.0 - (hueRotation / 360.0);
        if (ridges > 0)
        {
            color.b = 1.0 - abs(color.b * 2.0 - 1.0);
        }
        color = float4(nmms_hsv2rgb(color.rgb), color.a);
    }
    else
    {
        // oklab (COLOR_MODE == 3)
        color.g = color.g * -.509 + .276;
        color.b = color.b * -.509 + .198;

        color = float4(nmms_linear_srgb_from_oklab(color.rgb), color.a);
        color = float4(nmms_linearToSrgb(color.rgb), color.a);
        color = float4(nmms_rgb2hsv(color.rgb), color.a);
        color.r += 1.0 - (hueRotation / 360.0);
        color.r = frac(color.r);
        if (ridges > 0)
        {
            color.b = 1.0 - abs(color.b * 2.0 - 1.0);
        }
        color = float4(nmms_hsv2rgb(color.rgb), color.a);
    }

    color = float4(nmms_brightnessContrast(color.rgb), color.a);
    color.a = 1.0;

    return color;
}

#endif // NM_MOODSCAPE_INCLUDED
