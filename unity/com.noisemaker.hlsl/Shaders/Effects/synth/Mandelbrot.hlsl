#ifndef NM_MANDELBROT_INCLUDED
#define NM_MANDELBROT_INCLUDED

// =============================================================================
// Mandelbrot.hlsl — synth/mandelbrot, ported PIXEL-IDENTICALLY from the
// canonical WGSL source:
//   shaders/effects/synth/mandelbrot/wgsl/mandelbrot.wgsl
//
// df64 deep-zoom Mandelbrot explorer. 5 output modes:
//   0 smoothIteration, 1 distance, 2 stripeAverage, 3 orbitTrap, 4 normalMap
// 9 POIs with df64-precision coordinates. Single render pass.
//
// All helpers (df64_*, getPOI, transformCoords_df64, mandelbrot_df64, output*)
// are ported VERBATIM and INLINE per PORTING-GUIDE. No shared color/distance
// library substitutions.
//
// NUMERIC HAZARDS:
//  * Loop runs up to MAX_ITER=2048; inner n<maxIter break for parametric cap.
//  * WGSL select(b,a,cond) == HLSL cond ? a : b (reversed arg order).
//  * atan2(post_zy, post_zx) — literal WGSL arg order.
//  * rot = select(rotation, 0.0, poi > 0) -> (poi > 0) ? 0.0 : rotation.
//  * maxDepth = select(14.0, getPoiMaxZoom(poi), poi > 0)
//              -> (poi > 0) ? getPoiMaxZoom(poi) : 14.0.
//  * Full 32-bit float; never half/min16float.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
int   poi;           // 0=manual, 1..8=POI presets     (global "poi")
int   outputMode;    // 0..4                            (global "outputMode")
int   iterations;    // [50,2000]                       (global "iterations")
float centerHiX;     // center x high word              (global "centerX" -> uniform "centerHiX")
float centerHiY;     // center y high word              (global "centerY" -> uniform "centerHiY")
float centerLoX;     // center x low word               (uniform "centerLoX")
float centerLoY;     // center y low word               (uniform "centerLoY")
float zoomSpeed;     // [0,5]                           (global "zoomSpeed")
float zoomDepth;     // [0,14]                          (global "zoomDepth")
float invert;        // boolean 0/1                     (global "invert")
float stripeFreq;    // [0.5,20]                        (global "stripeFreq")
int   trapShape;     // 0=point,1=cross,2=circle        (global "trapShape")
float lightAngle;    // [0,360]                         (global "lightAngle")
float rotation;      // [-180,180] degrees              (global "rotation")

// Constants verbatim from WGSL
static const float NMM_PI      = 3.14159265359;
static const float NMM_TAU     = 6.28318530718;
static const float NMM_BAILOUT = 256.0;
static const float NMM_LOG2    = 0.6931471805599453;
static const int   NMM_MAX_ITER = 2048;

// ============================================================================
// df64 arithmetic — ported verbatim from WGSL
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

// Dekker's split method for error-free product
float2 df64_two_prod(float a, float b)
{
    float p  = a * b;
    float ca = 4097.0 * a;
    float ah = ca - (ca - a);
    float al = a - ah;
    float cb = 4097.0 * b;
    float bh = cb - (cb - b);
    float bl = b - bh;
    float e  = ((ah * bh - p) + ah * bl + al * bh) + al * bl;
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
// Points of Interest — verbatim from WGSL
// ============================================================================

// Two df64 values (re, im) packed as .xy and .zw respectively
// Using float4 as a PoiCoords struct surrogate: .xy = cX, .zw = cY
float4 getPOI_coords(int index, float cHiX, float cLoX, float cHiY, float cLoY)
{
    if (index == 1) // seahorseValley
        return float4(-0.7445398569107056,  -3.4452027897e-9,
                       0.12172377109527588,   2.7991489404e-9);
    else if (index == 2) // elephantValley
        return float4( 0.29833000898361206, -8.9836120765e-9,
                       0.0011099999537691474, 4.6230852696e-11);
    else if (index == 3) // scepterValley
        return float4(-1.7548776865005493,   2.0253856592e-8,
                       0.0,                  0.0);
    else if (index == 4) // miniBrot
        return float4(-1.7400623559951782,  -2.6584161761e-8,
                       0.028175339102745056,  6.7646594229e-10);
    else if (index == 5) // feigenbaum
        return float4(-1.4011552333831787,   4.4291128098e-8,
                       0.0,                  0.0);
    else if (index == 6) // birdOfParadise
        return float4( 0.37500011920928955,  8.5257595428e-10,
                      -0.21663938462734222,  -3.8103704636e-9);
    else if (index == 7) // spiralGalaxy
        return float4(-0.7445389032363892,  -1.6763610833e-8,
                       0.12172418087720871,  -8.7720870845e-10);
    else if (index == 8) // doubleSpiral
        return float4(-1.2553445100784302,  -1.4721569741e-8,
                      -0.3822004497051239,   -1.3294876089e-8);
    // index == 0: manual
    return float4(cHiX, cLoX, cHiY, cLoY);
}

float getPoiMaxZoom(int index)
{
    if (index == 2 || index == 7) return 7.0;
    if (index == 8) return 10.0;
    return 14.0;
}

// ============================================================================
// Coordinate transform — verbatim from WGSL
// ============================================================================

// Returns float4: .xy = re (df64), .zw = im (df64)
float4 transformCoords_df64(float2 fragCoord, float2 res,
                             float2 cX_df, float2 cY_df,
                             float z, float rot)
{
    float2 uv = (fragCoord - 0.5 * res) / min(res.x, res.y);
    float angle = -rot * NMM_TAU / 360.0;
    float c = cos(angle);
    float s = sin(angle);
    // Match GLSL mat2(c,-s,s,c) column-major rotation (same as WGSL)
    uv = float2(c * uv.x + s * uv.y, -s * uv.x + c * uv.y);

    float scale = 2.5 / z;
    float2 re = df64_add(df64_from(uv.x * scale), cX_df);
    float2 im = df64_add(df64_from(uv.y * scale), cY_df);
    return float4(re, im);  // .xy=re, .zw=im
}

// ============================================================================
// Early-out tests — verbatim from WGSL
// ============================================================================

bool inCardioid(float x, float y)
{
    float y2 = y * y;
    float q  = (x - 0.25) * (x - 0.25) + y2;
    return q * (q + (x - 0.25)) <= 0.25 * y2;
}

bool inPeriod2Bulb(float x, float y)
{
    float xp1 = x + 1.0;
    return xp1 * xp1 + y * y <= 0.0625;
}

// ============================================================================
// Orbit trap — verbatim from WGSL
// ============================================================================

float trapDistance(float2 z, int shape)
{
    if (shape == 0)
        return length(z);
    else if (shape == 1)
        return min(abs(z.x), abs(z.y));
    else
        return abs(length(z) - 1.0);
}

// ============================================================================
// IterResult struct
// ============================================================================

struct IterResult {
    float smoothIter;
    float rawIter;
    float2 z_final;
    float2 dz_final;
    float  stripeAcc;
    float  trapMin;
};

// ============================================================================
// df64 iteration — verbatim from WGSL
// ============================================================================

IterResult mandelbrot_df64(float2 c_re, float2 c_im, int maxIter,
                            float sFreq, int tShape)
{
    float cx = df64_to_float(c_re);
    float cy = df64_to_float(c_im);

    IterResult interior;
    interior.smoothIter = (float)maxIter;
    interior.rawIter    = (float)maxIter;
    interior.z_final    = float2(0.0, 0.0);
    interior.dz_final   = float2(0.0, 0.0);
    interior.stripeAcc  = 0.0;
    interior.trapMin    = 1e20;

    if (inCardioid(cx, cy) || inPeriod2Bulb(cx, cy))
        return interior;

    float2 zr = float2(0.0, 0.0);
    float2 zi = float2(0.0, 0.0);
    float2 dz = float2(1.0, 0.0);
    float  stripe = 0.0;
    float  trap   = 1e20;
    float  iter_i = 0.0;

    [loop]
    for (int n = 0; n < NMM_MAX_ITER; n = n + 1)
    {
        if (n >= maxIter) break;

        float zx = df64_to_float(zr);
        float zy = df64_to_float(zi);

        dz = float2(
            2.0 * (zx * dz.x - zy * dz.y) + 1.0,
            2.0 * (zx * dz.y + zy * dz.x)
        );

        float2 zr2    = df64_mul(zr, zr);
        float2 zi2    = df64_mul(zi, zi);
        float2 zri    = df64_mul(zr, zi);
        float2 new_zr = df64_add(df64_sub(zr2, zi2), c_re);
        float2 new_zi = df64_add(df64_mul_f(zri, 2.0), c_im);
        zr = new_zr;
        zi = new_zi;

        float post_zx   = df64_to_float(zr);
        float post_zy   = df64_to_float(zi);
        float post_mag2 = post_zx * post_zx + post_zy * post_zy;

        if (sFreq > 0.0)
            stripe = stripe + sin(sFreq * atan2(post_zy, post_zx));

        trap = min(trap, trapDistance(float2(post_zx, post_zy), tShape));

        if (post_mag2 > NMM_BAILOUT * NMM_BAILOUT) break;
        iter_i = iter_i + 1.0;
    }

    float fx      = df64_to_float(zr);
    float fy      = df64_to_float(zi);
    float2 z_fin  = float2(fx, fy);

    float smoothI = iter_i;
    float mag2    = dot(z_fin, z_fin);
    if (iter_i < (float)maxIter && mag2 > 1.0)
    {
        float log_zn = log(mag2) * 0.5;
        float nu     = log(log_zn / NMM_LOG2) / NMM_LOG2;
        smoothI = iter_i + 1.0 - nu;
    }

    IterResult r;
    r.smoothIter = smoothI;
    r.rawIter    = iter_i;
    r.z_final    = z_fin;
    r.dz_final   = dz;
    r.stripeAcc  = stripe;
    r.trapMin    = trap;
    return r;
}

// ============================================================================
// Output algorithms — verbatim from WGSL
// ============================================================================

float outputSmoothIteration(float smoothI, float rawI, int maxIter)
{
    if (rawI >= (float)maxIter) return 0.0;
    return smoothI / (float)maxIter;
}

float outputDistance(float2 z, float2 dz, float rawI, int maxIter)
{
    if (rawI >= (float)maxIter) return 0.0;
    float mag  = length(z);
    float dmag = length(dz);
    if (dmag == 0.0) return 0.0;
    float dist = 2.0 * mag * log(mag) / dmag;
    return clamp(sqrt(dist * (float)maxIter) * 0.5, 0.0, 1.0);
}

float outputStripeAverage(float smoothI, float rawI, float stripeAcc, int maxIter)
{
    if (rawI >= (float)maxIter) return 0.0;
    float count = max(rawI, 1.0);
    float avg   = stripeAcc / count;
    float f     = smoothI - floor(smoothI);
    return clamp(0.5 + 0.5 * avg * (1.0 - f), 0.0, 1.0);
}

float outputOrbitTrap(float trapMin, float rawI, int maxIter)
{
    if (rawI >= (float)maxIter) return 0.0;
    return clamp(1.0 - trapMin * 0.5, 0.0, 1.0);
}

// ============================================================================
// Normal map helpers — verbatim from WGSL
// ============================================================================

float computeDistAt_df64(float2 fragCoord, float2 res,
                          float2 cX_df, float2 cY_df, float z_zoom, float rot,
                          int maxIter, float sFreq, int tShape)
{
    float4 coords = transformCoords_df64(fragCoord, res, cX_df, cY_df, z_zoom, rot);
    IterResult r  = mandelbrot_df64(coords.xy, coords.zw, maxIter, sFreq, tShape);
    return outputDistance(r.z_final, r.dz_final, r.rawIter, maxIter);
}

float outputNormalMap(float2 fragCoord, float2 res,
                      float2 cX_df, float2 cY_df,
                      float z_zoom, float rot, int maxIter, float angle,
                      float sFreq, int tShape)
{
    float eps = 1.0 / min(res.x, res.y);
    float h0  = computeDistAt_df64(fragCoord,                  res, cX_df, cY_df, z_zoom, rot, maxIter, sFreq, tShape);
    float hx  = computeDistAt_df64(fragCoord + float2(1.0, 0.0), res, cX_df, cY_df, z_zoom, rot, maxIter, sFreq, tShape);
    float hy  = computeDistAt_df64(fragCoord + float2(0.0, 1.0), res, cX_df, cY_df, z_zoom, rot, maxIter, sFreq, tShape);

    float3 normal   = normalize(float3(h0 - hx, h0 - hy, eps));
    float  rad      = angle * NMM_TAU / 360.0;
    float3 lightDir = normalize(float3(cos(rad), sin(rad), 0.7));
    return clamp(dot(normal, lightDir), 0.0, 1.0);
}

// ============================================================================
// nm_mandelbrot — core per-pixel evaluation, mirrors WGSL main() exactly.
// Caller passes fragCoord = NM_GlobalCoord(i) and res = fullResolution. The GLSL
// source divides globalCoord by fullResolution; the WGSL collapses tiling so its
// pos.xy/resolution are the global coord/full size. Function is coord-agnostic.
// ============================================================================
float4 nm_mandelbrot(float2 fragCoord, float2 res)
{
    int maxIter = min(iterations, NMM_MAX_ITER);

    // Clamp zoom depth to POI coordinate precision
    // WGSL: select(14.0, getPoiMaxZoom(poi), poi > 0)  -> (poi>0) ? getPoiMaxZoom : 14.0
    float maxDepth = (poi > 0) ? getPoiMaxZoom(poi) : 14.0;
    float effDepth = min(zoomDepth, maxDepth);

    float effZoom;
    if (zoomSpeed > 0.0)
    {
        // Sinusoidal zoom
        float zoomPhase = 0.5 * (1.0 - cos(time * zoomSpeed * NMM_TAU));
        effZoom = pow(10.0, effDepth * zoomPhase);
    }
    else
    {
        effZoom = pow(10.0, effDepth);
    }

    // WGSL: select(rotation, 0.0, poi > 0) -> (poi>0) ? 0.0 : rotation
    float rot = (poi > 0) ? 0.0 : rotation;

    // Resolve POI
    float4 poiXY = getPOI_coords(poi, centerHiX, centerLoX, centerHiY, centerLoY);
    float2 cX_df = poiXY.xy;
    float2 cY_df = poiXY.zw;

    float value;

    if (outputMode == 4)
    {
        value = outputNormalMap(fragCoord, res, cX_df, cY_df,
                                effZoom, rot, maxIter, lightAngle,
                                stripeFreq, trapShape);
    }
    else
    {
        float4 coords = transformCoords_df64(fragCoord, res, cX_df, cY_df, effZoom, rot);
        IterResult r  = mandelbrot_df64(coords.xy, coords.zw, maxIter, stripeFreq, trapShape);

        if (outputMode == 0)
            value = outputSmoothIteration(r.smoothIter, r.rawIter, maxIter);
        else if (outputMode == 1)
            value = outputDistance(r.z_final, r.dz_final, r.rawIter, maxIter);
        else if (outputMode == 2)
            value = outputStripeAverage(r.smoothIter, r.rawIter, r.stripeAcc, maxIter);
        else if (outputMode == 3)
            value = outputOrbitTrap(r.trapMin, r.rawIter, maxIter);
        else
            value = outputSmoothIteration(r.smoothIter, r.rawIter, maxIter);
    }

    if (invert > 0.5)
        value = 1.0 - value;

    return float4(value, value, value, 1.0);
}

#endif // NM_MANDELBROT_INCLUDED
