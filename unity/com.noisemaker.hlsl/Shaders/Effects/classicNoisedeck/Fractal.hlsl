#ifndef NM_FRACTAL_INCLUDED
#define NM_FRACTAL_INCLUDED

// =============================================================================
// Fractal.hlsl — classicNoisedeck/fractal, ported PIXEL-IDENTICALLY from
// the canonical WGSL source:
//   shaders/effects/classicNoisedeck/fractal/wgsl/fractal.wgsl
//
// Generator (no texture inputs). Single render pass.
//
// All helpers (modulo, map, rotate2D, hsv2rgb, linearToSrgb, oklab, pal,
// fx, fpx, divide, newton, julia, mandelbrot) are ported VERBATIM inline.
// None of them come from NMCore.
//
// NUMERIC HAZARDS:
//  * st = globalCoord / fullResolution.y  (divide by HEIGHT, not both axes)
//  * rotate2D uses aspect = fullResolution.x / fullResolution.y
//  * mat2x2 column-major: WGSL mat2x2<f32>(c,s,-s,c)*st = (c*x - s*y, s*x + c*y)
//    N.B. WGSL column order: mat2x2(c0_r0, c0_r1, c1_r0, c1_r1) =
//         col0=(c,s), col1=(-s,c) => M*v = (c*vx + (-s)*vy, s*vx + c*vy)
//    rotate2D in fractal.wgsl: mat2x2<f32>(c, s, -s, c) => col0=(c,s) col1=(-s,c)
//    => result.x = c*x + (-s)*y, result.y = s*x + c*y
//  * nm_mod (not fmod) for modulo(a,b)
//  * All Newton/julia/mandelbrot arg order copied literally.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
int    type;            // fractalType: 0=julia, 1=newton, 2=mandelbrot
int    symmetry;        // unused, kept for uniform completeness
float  zoomAmt;         // [0,130]   default 0
float  rotation;        // [-180,180] default 0
float  speed;           // [0,100]   default 30
float  offsetX;         // [-100,100] default 70
float  offsetY;         // [-100,100] default 50
float  centerX;         // [-100,100] default 0
float  centerY;         // [-100,100] default 0
int    mode;            // 0=iter, 1=z
int    iterations;      // [1,50]    default 50
int    colorMode;       // 0=mono, 4=palette, 6=hsv  default 4
int    paletteMode;     // 0  default 0
int    cyclePalette;    // -1/0/1   default 1
float  rotatePalette;   // [0,100]  default 0
float  repeatPalette;   // [1,10]   default 1
float3 paletteOffset;   // default (0.5,0.5,0.5)
float  hueRange;        // [1,100]  default 100
float3 paletteAmp;      // default (0.5,0.5,0.5)
float  levels;          // [0,32]   default 0
float3 paletteFreq;     // default (1,1,1)
float  bgAlpha;         // [0,100]  default 100
float3 palettePhase;    // default (0,0,0)
float  cutoff;          // [0,100]  default 0
float3 bgColor;         // default (0,0,0)

static const float NMF_PI  = 3.14159265359;
static const float NMF_TAU = 6.28318530718;

// ---- modulo: a - b * floor(a / b)  (matches WGSL modulo; same as nm_mod) ---
float nmf_modulo(float a, float b)
{
    return a - b * floor(a / b);
}

// ---- map: linear remap [inMin,inMax] -> [outMin,outMax] ---------------------
float nmf_map(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

// ---- rotate2D (fractal's own) -----------------------------------------------
// WGSL: st -= (0.5*aspect, 0.5); st = mat2x2(c,s,-s,c)*st; st += (0.5*aspect,0.5)
// mat2x2<f32>(c,s,-s,c) column-major: col0=(c,s), col1=(-s,c)
//   result = (c*x + (-s)*y,  s*x + c*y)
float2 nmf_rotate2D(float2 st0, float rot, float aspect)
{
    float2 st = st0;
    float r = nmf_map(rot, 0.0, 360.0, 0.0, 2.0);
    float angle = r * NMF_PI;
    st = st - float2(0.5 * aspect, 0.5);
    float s = sin(angle);
    float c = cos(angle);
    // GLSL golden: mat2(cos,-sin,sin,cos) * st. GLSL mat2 is COLUMN-MAJOR, so it
    // equals (c*st.x + s*st.y, -s*st.x + c*st.y) — opposite rotation direction from
    // the WGSL transcription (c*x-s*y, s*x+c*y). Only diverges for nonzero rotation.
    st = float2(c * st.x + s * st.y, -s * st.x + c * st.y);
    st = st + float2(0.5 * aspect, 0.5);
    return st;
}

// ---- hsv2rgb (fractal's own; uses nmf_modulo) --------------------------------
float3 nmf_hsv2rgb(float3 hsv)
{
    float h = frac(hsv.x);
    float sv = hsv.y;
    float v = hsv.z;
    float c = v * sv;
    float x = c * (1.0 - abs(nmf_modulo(h * 6.0, 2.0) - 1.0));
    float m = v - c;
    float3 rgb = float3(0.0, 0.0, 0.0);
    if      (h >= 0.0        && h < 1.0/6.0) { rgb = float3(c, x, 0.0); }
    else if (h >= 1.0/6.0    && h < 2.0/6.0) { rgb = float3(x, c, 0.0); }
    else if (h >= 2.0/6.0    && h < 3.0/6.0) { rgb = float3(0.0, c, x); }
    else if (h >= 3.0/6.0    && h < 4.0/6.0) { rgb = float3(0.0, x, c); }
    else if (h >= 4.0/6.0    && h < 5.0/6.0) { rgb = float3(x, 0.0, c); }
    else if (h >= 5.0/6.0    && h < 1.0)      { rgb = float3(c, 0.0, x); }
    return rgb + float3(m, m, m);
}

// ---- linearToSrgb -----------------------------------------------------------
float3 nmf_linearToSrgb(float3 lin)
{
    float3 srgb = float3(0.0, 0.0, 0.0);
    [unroll]
    for (int i = 0; i < 3; i = i + 1)
    {
        if (lin[i] <= 0.0031308)
            srgb[i] = lin[i] * 12.92;
        else
            srgb[i] = 1.055 * pow(lin[i], 1.0 / 2.4) - 0.055;
    }
    return srgb;
}

// ---- oklab matrices (Public Domain/MIT) -------------------------------------
static const float3x3 nmf_fwdA = float3x3(
    float3(1.0,  0.3963377774,  0.2158037573),
    float3(1.0, -0.1055613458, -0.0638541728),
    float3(1.0, -0.0894841775, -1.2914855480)
);
static const float3x3 nmf_fwdB = float3x3(
    float3( 4.0767245293, -3.3072168827,  0.2307590544),
    float3(-1.2681437731,  2.6093323231, -0.3411344290),
    float3(-0.0041119885, -0.7034763098,  1.7068625689)
);
static const float3x3 nmf_invB = float3x3(
    float3(0.4121656120, 0.5362752080, 0.0514575653),
    float3(0.2118591070, 0.6807189584, 0.1074065790),
    float3(0.0883097947, 0.2818474174, 0.6302613616)
);
static const float3x3 nmf_invA = float3x3(
    float3(0.2104542553,  0.7936177850, -0.0040720468),
    float3(1.9779984951, -2.4285922050,  0.4505937099),
    float3(0.0259040371,  0.7827717662, -0.8086757660)
);

// WGSL: invB * c  (vec3 = mat3x3 * vec3; WGSL mat3x3 is column-major)
// WGSL mat3x3<f32>(col0,col1,col2) where each col is float3
// invB in WGSL:
//   col0 = (0.4121656120, 0.2118591070, 0.0883097947)
//   col1 = (0.5362752080, 0.6807189584, 0.2818474174)
//   col2 = (0.0514575653, 0.1074065790, 0.6302613616)
// result.x = dot(c, row0 of row-form) = c.x*0.4121656120 + c.y*0.5362752080 + c.z*0.0514575653
// HLSL mul(M,v) where M[row][col]: nmf_invB is already row-major above -> mul works directly
float3 nmf_oklab_from_linear_srgb(float3 c)
{
    float3 lms = mul(nmf_invB, c);
    return mul(nmf_invA, (sign(lms) * pow(abs(lms), float3(0.3333333333333, 0.3333333333333, 0.3333333333333))));
}

float3 nmf_linear_srgb_from_oklab(float3 c)
{
    float3 lms = mul(nmf_fwdA, c);
    return mul(nmf_fwdB, (lms * lms * lms));
}

// ---- pal: cosine palette ----------------------------------------------------
float3 nmf_pal(float t0, float3 pOffset, float3 pAmp, float3 pFreq, float3 pPhase, int pMode)
{
    float3 color = pOffset + pAmp * cos(NMF_TAU * (pFreq * t0 + pPhase));
    float3 col = color;
    [branch]
    if (pMode == 1)
    {
        col = nmf_hsv2rgb(col);
    }
    else if (pMode == 2)
    {
        col.g = col.g * -0.509 + 0.276;
        col.b = col.b * -0.509 + 0.198;
        col = nmf_linear_srgb_from_oklab(col);
        col = nmf_linearToSrgb(col);
    }
    return col;
}

// ---- Newton fractal helpers -------------------------------------------------
float2 nmf_fx(float2 z)
{
    return float2(pow(z.x, 3.0) - 3.0 * z.x * pow(z.y, 2.0) - 1.0,
                  3.0 * pow(z.x, 2.0) * z.y - pow(z.y, 3.0));
}

float2 nmf_fpx(float2 z)
{
    return float2(3.0 * pow(z.x, 2.0) - 3.0 * pow(z.y, 2.0),
                  6.0 * z.x * z.y);
}

float2 nmf_divide(float2 z1, float2 z2)
{
    return float2(
        (z1.x * z2.x + z1.y * z2.y) / (pow(z2.x, 2.0) + pow(z2.y, 2.0)),
        (z1.y * z2.x - z1.x * z2.y) / (pow(z2.x, 2.0) + pow(z2.y, 2.0))
    );
}

// ---- newton -----------------------------------------------------------------
float nmf_newton(float2 st0, int maxIter, float offX_u, float offY_u, float spd,
                 float cX, float cY, float zAmt, float rot, float t, int md, float aspect)
{
    float2 st = nmf_rotate2D(st0, rot + 90.0, aspect);
    st = st - float2(0.5 * aspect, 0.5);
    st = st * nmf_map(zAmt, 0.0, 130.0, 1.0, 0.01);
    float s   = nmf_map(spd, 0.0, 100.0, 0.0, 1.0);
    float offX = nmf_map(offX_u, -100.0, 100.0, -0.25, 0.25);
    float offY = nmf_map(offY_u, -100.0, 100.0, -0.25, 0.25);
    st.x = st.x + cY * 0.01;
    st.y = st.y + cX * 0.01;
    float2 n = st;
    float iterCount = 0.0;
    float2 tst = float2(0.0, 0.0);
    for (int i = 0; i < maxIter; i = i + 1)
    {
        tst = nmf_divide(nmf_fx(n), nmf_fpx(n));
        tst = tst + float2(sin(t * NMF_TAU), cos(t * NMF_TAU)) * 0.1 * s;
        tst = tst + float2(offX, offY);
        if (length(tst) < 0.001) { break; }
        n = n - tst;
        iterCount = iterCount + 1.0;
    }
    if (md == 0)
    {
        if (maxIter == 0) { return 0.0; }
        return iterCount / (float)maxIter;
    }
    else
    {
        return length(n);
    }
}

// ---- julia ------------------------------------------------------------------
float nmf_julia(float2 st0, float zAmt, float spd, float offX_u, float offY_u,
                float rot, float cX, float cY, int maxIter, float cut, float t, int md, float aspect)
{
    float zoom   = nmf_map(zAmt, 0.0, 100.0, 2.0, 0.5);
    float speedy = nmf_map(spd, 0.0, 100.0, 0.0, 1.0);
    float s      = lerp(speedy * 0.05, speedy * 0.125, speedy);
    float _offX  = nmf_map(offX_u, -100.0, 100.0, -0.5, 0.5);
    float _offY  = nmf_map(offY_u, -100.0, 100.0, -1.0, 1.0);
    float2 c     = float2(sin(t * NMF_TAU) * s + _offX, cos(t * NMF_TAU) * s + _offY);
    float2 st    = nmf_rotate2D(st0, rot, aspect);
    st = (st - float2(0.5 * aspect, 0.5)) * zoom;
    float2 z = float2(
        st.x + nmf_map(cX, -100.0, 100.0, 1.0, -1.0),
        st.y + nmf_map(cY, -100.0, 100.0, 1.0, -1.0)
    );
    int iterCount = 0;
    int iterScaled = maxIter * 2;
    for (int i = 0; i < iterScaled; i = i + 1)
    {
        iterCount = i;
        float x = (z.x * z.x - z.y * z.y) + c.x;
        float y = (z.y * z.x + z.x * z.y) + c.y;
        if ((x * x + y * y) > 4.0) { break; }
        z.x = x;
        z.y = y;
    }
    if ((iterScaled - iterCount) < (int)cut)
    {
        return 1.0;
    }
    if (md == 0)
    {
        if (iterScaled == 0) { return 0.0; }
        return (float)iterCount / (float)iterScaled;
    }
    else
    {
        return length(z);
    }
}

// ---- mandelbrot -------------------------------------------------------------
float nmf_mandelbrot(float2 st0, float zAmt, float spd, float rot,
                     float cX, float cY, int iter, float t, int md, float aspect)
{
    float zoom   = nmf_map(zAmt, 0.0, 100.0, 2.0, 0.5);
    float speedy = nmf_map(spd, 0.0, 100.0, 0.0, 1.0);
    float s      = lerp(speedy * 0.05, speedy * 0.125, speedy);
    float2 st    = nmf_rotate2D(st0, rot, aspect);
    st.y = st.y * 2.0 - 1.0;
    st.x = st.x * 2.0 - aspect;
    float2 z = float2(0.0, 0.0);
    float2 mc = zoom * st - float2(cX + 50.0, cY) * 0.01;
    z = z + float2(sin(t * NMF_TAU), cos(t * NMF_TAU)) * s;
    float fi = 0.0;
    for (fi = 0.0; fi < (float)iter; fi = fi + 1.0)
    {
        // mat2x2<f32>(z.x, z.y, -z.y, z.x) * z
        // WGSL column-major: col0=(z.x,z.y), col1=(-z.y,z.x)
        // result = (z.x*z.x + (-z.y)*z.y, z.y*z.x + z.x*z.y)
        float2 mz;
        mz.x = z.x * z.x + (-z.y) * z.y;
        mz.y = z.y * z.x +   z.x  * z.y;
        z = mz + mc;
        if (dot(z, z) > 16.0) { break; }
    }
    if (fi == (float)iter) { return 1.0; }
    if (md == 0)
    {
        return fi / (float)iter;
    }
    else
    {
        return length(z) / (float)iter;
    }
}

// =============================================================================
// nm_fractal — core per-pixel evaluation. globalCoord = NM_GlobalCoord(i).
// =============================================================================
float4 nm_fractal(float2 globalCoord)
{
    float2 res        = resolution;
    float2 fullRes    = fullResolution;
    float2 tOff       = tileOffset;
    float  t          = time;
    float  aspect     = fullRes.x / fullRes.y;

    float2 st = globalCoord / fullRes.y;  // divide by HEIGHT only

    float4 color = float4(0.0, 0.0, 1.0, 1.0);
    float d = 0.0;

    [branch]
    if (type == 0)
    {
        d = nmf_julia(st, zoomAmt, speed, offsetX, offsetY, rotation,
                      centerX, centerY, iterations, cutoff, t, mode, aspect);
    }
    else if (type == 1)
    {
        d = nmf_newton(st, iterations, offsetX, offsetY, speed,
                       centerX, centerY, zoomAmt, rotation, t, mode, aspect);
    }
    else
    {
        d = nmf_mandelbrot(st, zoomAmt, speed, rotation,
                           centerX, centerY, iterations, t, mode, aspect);
    }

    if (d == 1.0)
    {
        color = float4(bgColor, bgAlpha * 0.01);
    }
    else
    {
        float dd = d;
        if      (cyclePalette == -1) { dd = dd - t; }
        else if (cyclePalette ==  1) { dd = dd + t; }
        dd = dd * repeatPalette + rotatePalette * 0.01;
        dd = frac(dd);
        if (levels > 0.0)
        {
            float lev = levels + 1.0;
            dd = floor(dd * lev) / lev;
        }
        [branch]
        if (colorMode == 0)
        {
            color = float4(float3(frac(dd), frac(dd), frac(dd)), color.a);
        }
        else if (colorMode == 4)
        {
            color = float4(nmf_pal(dd, paletteOffset, paletteAmp, paletteFreq, palettePhase, paletteMode), color.a);
        }
        else if (colorMode == 6)
        {
            float d2 = dd * (hueRange * 0.01);
            color = float4(nmf_hsv2rgb(float3(d2, 1.0, 1.0)), color.a);
        }
    }

    return color;
}

#endif // NM_FRACTAL_INCLUDED
