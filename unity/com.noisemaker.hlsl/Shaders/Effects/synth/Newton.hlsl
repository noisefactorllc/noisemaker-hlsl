#ifndef NM_NEWTON_INCLUDED
#define NM_NEWTON_INCLUDED

// =============================================================================
// Newton.hlsl — synth/newton, ported PIXEL-IDENTICALLY from the canonical
// WGSL source:
//   shaders/effects/synth/newton/wgsl/newton.wgsl
//
// Newton fractal explorer: Newton-Raphson root finding for z^n - 1 with
// df64 emulated double-precision, animation, points of interest, three output
// modes.
//
// All df64 helpers and Df64Complex struct are ported VERBATIM and INLINE per
// PORTING-GUIDE. No shared helpers are used (this effect has no hsv/pcg/etc).
//
// NUMERIC HAZARDS handled:
//  * nm_mod is NOT used here — this effect has no modulo on floats.
//  * df64 arithmetic: all verbatim from WGSL (Dekker/Knuth error-free).
//  * `frRes = (fullResolution.x > 0.0) ? fullResolution : resolution`
//    mirrors WGSL `select(resolution, fullResolution, fullResolution.x > 0.0)`.
//    NOTE: WGSL select(false_val, true_val, cond) — reversed from ternary!
//  * transformCoords_df64: coord transform matches WGSL exactly including
//    the rotation matrix applied as written.
//  * All loop bounds are verbatim (500, 8, 7 inner power loop).
//  * toleranceU used in convergence test and smooth-iter formula verbatim.
//  * smoothIter formula: iter - log2(log(convergeDist) / log(toleranceU)).
//  * POI constants copied character-for-character from WGSL.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
float  degree;         // [3,8]          default 3
float  relaxation;     // [0.5,2.0]      default 1.0
float  iterations;     // [10,500]       default 100   (passed as float, converted to int)
float  tolerance;      // [0.0001,0.01]  default 0.001
int    poi;            // choices 0..6   default 5
float  centerHiX;      // default 0.0
float  centerHiY;      // default 0.0
float  centerLoX;      // default 0.0
float  centerLoY;      // default 0.0
float  zoomSpeed;      // [0,5]          default 0.0
float  zoomDepth;      // [0,14]         default 0.0
float  degreeSpeed;    // [0,1]          default 0.0
float  degreeRange;    // [0,3]          default 0.0
float  relaxSpeed;     // [0,1]          default 0.0
float  relaxRange;     // [0,0.5]        default 0.0
float  rotation;       // [-180,180]     default 0.0
int    outputMode;     // choices 0..2   default 2
float  invert;         // boolean 0/1    default 0

// Local constants exactly as WGSL declares them.
static const float NMN_PI  = 3.14159265359;
static const float NMN_TAU = 6.28318530718;
static const float NMN_PHI = 1.6180339887;

// ============================================================================
// df64 emulated double-precision (verbatim from WGSL)
// ============================================================================

float2 df64_quick_two_sum(float a, float b)
{
    float s = a + b;
    float e = b - (s - a);
    return float2(s, e);
}

float2 df64_two_sum(float a, float b)
{
    float s = a + b;
    float v = s - a;
    float e = (a - (s - v)) + (b - v);
    return float2(s, e);
}

float2 df64_two_prod(float a, float b)
{
    float p = a * b;
    float ca = 4097.0 * a;
    float ah = ca - (ca - a);
    float al = a - ah;
    float cb = 4097.0 * b;
    float bh = cb - (cb - b);
    float bl = b - bh;
    float e = ((ah * bh - p) + ah * bl + al * bh) + al * bl;
    return float2(p, e);
}

float2 df64_add(float2 a, float2 b)
{
    float2 s = df64_two_sum(a.x, b.x);
    s.y = s.y + a.y + b.y;
    return df64_quick_two_sum(s.x, s.y);
}

float2 df64_sub(float2 a, float2 b)
{
    return df64_add(a, float2(-b.x, -b.y));
}

float2 df64_mul(float2 a, float2 b)
{
    float2 p = df64_two_prod(a.x, b.x);
    p.y = p.y + a.x * b.y + a.y * b.x;
    return df64_quick_two_sum(p.x, p.y);
}

float2 df64_mul_f(float2 a, float b)
{
    float2 p = df64_two_prod(a.x, b);
    p.y = p.y + a.y * b;
    return df64_quick_two_sum(p.x, p.y);
}

float2 df64_from(float a)
{
    return float2(a, 0.0);
}

float df64_to_float(float2 a)
{
    return a.x + a.y;
}

// ============================================================================
// df64 complex struct + multiply (verbatim from WGSL)
// ============================================================================

struct Df64Complex
{
    float2 re;
    float2 im;
};

Df64Complex df64_cmul(Df64Complex a, Df64Complex b)
{
    float2 rr = df64_sub(df64_mul(a.re, b.re), df64_mul(a.im, b.im));
    float2 ri = df64_add(df64_mul(a.re, b.im), df64_mul(a.im, b.re));
    Df64Complex result;
    result.re = rr;
    result.im = ri;
    return result;
}

// ============================================================================
// df64 coordinate transform (verbatim from WGSL)
// ============================================================================

struct CoordResult
{
    float2 re;
    float2 im;
};

CoordResult transformCoords_df64(float2 fragCoord, float2 cX_df, float2 cY_df,
                                  float2 res, float z_zoom, float rot)
{
    float2 uv = (fragCoord - 0.5 * res) / min(res.x, res.y);
    float angle = -rot * NMN_TAU / 360.0;
    float c = cos(angle);
    float s = sin(angle);
    uv = float2(c * uv.x + s * uv.y, -s * uv.x + c * uv.y);
    float scale = 2.5 / z_zoom;
    float2 uv_re_df = df64_mul_f(df64_from(uv.x), scale);
    float2 uv_im_df = df64_mul_f(df64_from(uv.y), scale);
    float2 re = df64_add(uv_re_df, cX_df);
    float2 im = df64_add(uv_im_df, cY_df);
    CoordResult cr;
    cr.re = re;
    cr.im = im;
    return cr;
}

// ============================================================================
// Points of interest (verbatim from WGSL — constants copied character-for-character)
// ============================================================================

struct POIData
{
    float4 center;
    float  deg;
    float  maxZoom;
};

POIData getPOI(int idx)
{
    POIData d;
    // center = float4(hiX, hiY, loX, loY), deg, maxZoom
    if (idx == 1) { d.center = float4(0.0, 0.0, 0.0, 0.0);                                                               d.deg = 3.0; d.maxZoom = 7.0;  return d; } // triplePoint3
    if (idx == 2) { d.center = float4(0.25, 0.4330126941204071, 0.0, 7.7718e-9);                                          d.deg = 3.0; d.maxZoom = 14.0; return d; } // spiralJunction3
    if (idx == 3) { d.center = float4(0.0, 0.0, 0.0, 0.0);                                                               d.deg = 5.0; d.maxZoom = 7.0;  return d; } // starCenter5
    if (idx == 4) { d.center = float4(0.6545084714889526, 0.4755282700061798, 2.5699e-8, -1.1859e-8);                     d.deg = 5.0; d.maxZoom = 14.0; return d; } // pentaSpiral5
    if (idx == 5) { d.center = float4(0.0, 0.0, 0.0, 0.0);                                                               d.deg = 6.0; d.maxZoom = 7.0;  return d; } // hexWeb6
    if (idx == 6) { d.center = float4(0.0, 0.0, 0.0, 0.0);                                                               d.deg = 8.0; d.maxZoom = 7.0;  return d; } // octoFlower8
    d.center = float4(0.0, 0.0, 0.0, 0.0); d.deg = 3.0; d.maxZoom = 7.0; return d; // manual / fallback
}

// =============================================================================
// nm_newton — core per-pixel evaluation. `globalCoord` is the fragment's
// pixel coordinate plus tileOffset (NM_GlobalCoord(i)). Returns RGBA.
// Mirrors WGSL main() exactly.
// =============================================================================
float4 nm_newton(float2 globalCoord, float2 res, float2 fullRes_in)
{
    // WGSL: frRes = select(resolution, fullResolution, fullResolution.x > 0.0)
    // WGSL select(false_val, true_val, cond) => ternary cond ? true_val : false_val
    float2 frRes = (fullRes_in.x > 0.0) ? fullRes_in : res;

    int maxIter  = (int)iterations;
    int poiIdx   = poi;
    int outMode  = outputMode;
    bool doInvert = invert > 0.5;

    // --- Effective parameters with animation ---

    float effDegree = degree;
    if (degreeSpeed > 0.0 && degreeRange > 0.0)
    {
        effDegree = effDegree + degreeRange * sin(time * degreeSpeed * NMN_TAU);
        effDegree = clamp(effDegree, 3.0, 8.0);
    }

    float effRelax = relaxation;
    if (relaxSpeed > 0.0 && relaxRange > 0.0)
    {
        effRelax = effRelax + relaxRange * sin(time * relaxSpeed * NMN_TAU * NMN_PHI);
        effRelax = clamp(effRelax, 0.5, 2.0);
    }

    // --- Center and zoom ---

    float2 cHi = float2(centerHiX, centerHiY);
    float2 cLo = float2(centerLoX, centerLoY);
    float effZoomDepth = zoomDepth;

    if (poiIdx > 0)
    {
        POIData p = getPOI(poiIdx);
        cHi = p.center.xy + cHi;
        cLo = p.center.zw + cLo;
        effDegree = p.deg;
        effZoomDepth = min(zoomDepth, p.maxZoom);
    }

    // Sinusoidal zoom: time 0 = zoomed out, time 0.5/speed = max depth, time 1/speed = zoomed out
    float zoom;
    if (zoomSpeed > 0.0)
    {
        float zoomPhase = 0.5 * (1.0 - cos(time * zoomSpeed * NMN_TAU));
        zoom = pow(10.0, effZoomDepth * zoomPhase);
    }
    else
    {
        zoom = pow(10.0, effZoomDepth);
    }

    // --- df64 coordinate transform ---

    CoordResult coords = transformCoords_df64(
        globalCoord,
        float2(cHi.x, cLo.x), float2(cHi.y, cLo.y),
        frRes, zoom, rotation);

    // --- Compute roots of z^n - 1 ---

    int intDeg   = (int)floor(effDegree);
    int numRoots = intDeg;
    float2 roots[8];
    [loop]
    for (int k = 0; k < 8; k = k + 1)
    {
        if (k >= numRoots) break;
        float angle = NMN_TAU * (float)k / (float)intDeg;
        roots[k] = float2(cos(angle), sin(angle));
    }

    // --- df64 Newton iteration ---

    float iter = 0.0;
    int   convergedRoot = -1;
    float convergeDist  = 1.0;
    float bailout = 1e10 * effRelax;

    float2 zr_df = coords.re;
    float2 zi_df = coords.im;

    [loop]
    for (int n = 0; n < 500; n = n + 1)
    {
        if (n >= maxIter) break;

        // Compute z^(intDeg-1) via repeated df64 complex multiplication
        Df64Complex pw;
        pw.re = df64_from(1.0);
        pw.im = df64_from(0.0);
        [loop]
        for (int j = 0; j < 7; j = j + 1)
        {
            if (j >= intDeg - 1) break;
            Df64Complex zc;
            zc.re = zr_df;
            zc.im = zi_df;
            pw = df64_cmul(pw, zc);
        }

        // z^intDeg = z^(intDeg-1) * z
        Df64Complex zc2;
        zc2.re = zr_df;
        zc2.im = zi_df;
        Df64Complex zn = df64_cmul(pw, zc2);

        // f(z) = z^n - 1
        float2 fzr = df64_sub(zn.re, df64_from(1.0));
        float2 fzi = zn.im;

        // f'(z) = n * z^(n-1)
        float2 fpzr = df64_mul_f(pw.re, (float)intDeg);
        float2 fpzi = df64_mul_f(pw.im, (float)intDeg);

        // Degenerate derivative guard
        float fpzr_f = df64_to_float(fpzr);
        float fpzi_f = df64_to_float(fpzi);
        if (fpzr_f * fpzr_f + fpzi_f * fpzi_f < 1e-20) break;

        // delta = f(z) / f'(z) via df64 complex division
        float denom     = fpzr_f * fpzr_f + fpzi_f * fpzi_f;
        float inv_denom = 1.0 / denom;
        float2 nr = df64_add(df64_mul(fzr, fpzr), df64_mul(fzi, fpzi));
        float2 ni = df64_sub(df64_mul(fzi, fpzr), df64_mul(fzr, fpzi));
        float2 dr = df64_mul_f(nr, inv_denom);
        float2 di = df64_mul_f(ni, inv_denom);

        // z = z - relaxation * delta
        zr_df = df64_sub(zr_df, df64_mul_f(dr, effRelax));
        zi_df = df64_sub(zi_df, df64_mul_f(di, effRelax));

        // Divergence check
        float zx = df64_to_float(zr_df);
        float zy = df64_to_float(zi_df);
        if (zx * zx + zy * zy > bailout) break;

        // Convergence check
        [loop]
        for (int ck = 0; ck < 8; ck = ck + 1)
        {
            if (ck >= numRoots) break;
            float dx = zx - roots[ck].x;
            float dy = zy - roots[ck].y;
            float d  = sqrt(dx * dx + dy * dy);
            if (d < tolerance)
            {
                convergedRoot = ck;
                convergeDist  = d;
                break;
            }
        }
        if (convergedRoot >= 0) break;

        iter = iter + 1.0;
    }

    // --- Smooth iteration count ---

    float smoothIter = iter;
    if (convergedRoot >= 0 && convergeDist > 0.0 && convergeDist < tolerance)
    {
        smoothIter = iter - log2(log(convergeDist) / log(tolerance));
    }

    // --- Output mapping ---

    float value     = 0.0;
    float maxIterF  = (float)maxIter;
    float numRootsF = (float)numRoots;

    if (outMode == 0)
    {
        value = smoothIter / maxIterF;
    }
    else if (outMode == 1)
    {
        if (convergedRoot >= 0)
        {
            value = (float)convergedRoot / numRootsF;
        }
    }
    else
    {
        if (convergedRoot >= 0)
        {
            value = ((float)convergedRoot + smoothIter / maxIterF) / numRootsF;
        }
    }

    if (doInvert) { value = 1.0 - value; }

    return float4(value, value, value, 1.0); // TODO(verify): float3(value) splat -> explicit
}

#endif // NM_NEWTON_INCLUDED
