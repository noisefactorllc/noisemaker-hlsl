#ifndef NM_JULIA_INCLUDED
#define NM_JULIA_INCLUDED

// =============================================================================
// Julia.hlsl — synth/julia, ported PIXEL-IDENTICALLY from the canonical
// WGSL source:
//   shaders/effects/synth/julia/wgsl/julia.wgsl
//
// Julia set explorer with deep zoom (df64 double-float emulation).
// Single render pass; grayscale output [0,1], alpha = 1.0.
//
// All helpers are ported VERBATIM and INLINE from the WGSL per PORTING-GUIDE.
// No shared color/dist libs used — only NMFullscreen.hlsl (which includes NMCore).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
float  cReal;        // default -0.123
float  cImag;        // default 0.745
int    poi;          // default 10
int    outputMode;   // default 3
float  centerX;      // default 0.0
float  centerY;      // default 0.0
float  rotation;     // degrees, default 0
int    iterations;   // default 300
float  stripeFreq;   // default 5.0
int    trapShape;    // default 0
float  lightAngle;   // default 45.0
int    cPath;        // default 0
float  cSpeed;       // default 0.3
float  cRadius;      // default 0.7885
float  invert;       // boolean as float; default 0 (false)
float  zoomSpeed;    // default 0.0
float  zoomDepth;    // default 0.0

static const float NMJ_PI    = 3.14159265359;
static const float NMJ_TAU   = 6.28318530718;
static const float NMJ_BAILOUT = 256.0;
static const float NMJ_LOG2  = 0.6931471805599453;

// ============================================================================
// POI c-values (famous Julia sets) — verbatim from WGSL
// ============================================================================

float2 nmj_getPOI(int idx)
{
    if (idx == 1)  { return float2(-0.123,  0.745);  }   // Douady's rabbit
    if (idx == 2)  { return float2(-0.3905, 0.5868); }   // Siegel disk
    if (idx == 3)  { return float2( 0.0,    1.0);    }   // Dendrite
    if (idx == 4)  { return float2(-1.0,    0.0);    }   // Basilica
    if (idx == 5)  { return float2(-0.7455, 0.1130); }   // Spiral galaxy
    if (idx == 6)  { return float2(-0.0986, 0.6534); }   // Lightning
    if (idx == 7)  { return float2(-0.8,    0.156);  }   // Dragon curve
    if (idx == 8)  { return float2(-0.75,   0.0);    }   // San Marco
    if (idx == 9)  { return float2(-0.5792, 0.5385); }   // Starfish
    if (idx == 10) { return float2( 0.28,   0.008);  }   // Double spiral
    return float2(-0.123, 0.745);
}

// ============================================================================
// Animated c-paths — verbatim from WGSL
// ============================================================================

float2 nmj_getAnimatedC(int pathType, float t, float radius)
{
    float theta = t * NMJ_TAU;
    if (pathType == 1)
    {
        return float2(
            cos(theta) * 0.5 - cos(2.0 * theta) * 0.25,
            sin(theta) * 0.5 - sin(2.0 * theta) * 0.25
        );
    }
    if (pathType == 2)
    {
        return float2(cos(theta), sin(theta)) * radius;
    }
    if (pathType == 3)
    {
        return float2(-1.0 + cos(theta) * 0.25, sin(theta) * 0.25);
    }
    return float2(0.0, 0.0);
}

// ============================================================================
// Complex multiply — verbatim from WGSL
// ============================================================================

float2 nmj_cmul(float2 a, float2 b)
{
    return float2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
}

// ============================================================================
// Double-float emulation (df64) — verbatim from WGSL
// ============================================================================

float2 nmj_df64_from(float a)
{
    return float2(a, 0.0);
}

float2 nmj_df64_add(float2 a, float2 b)
{
    float s = a.x + b.x;
    float v = s - a.x;
    float e = (a.x - (s - v)) + (b.x - v);
    return float2(s, e + a.y + b.y);
}

float2 nmj_df64_sub(float2 a, float2 b)
{
    return nmj_df64_add(a, float2(-b.x, -b.y));
}

float2 nmj_df64_split(float a)
{
    float t = 4097.0 * a; // 2^12 + 1
    float hi = t - (t - a);
    return float2(hi, a - hi);
}

float2 nmj_df64_mul(float2 a, float2 b)
{
    float p = a.x * b.x;
    float2 as_ = nmj_df64_split(a.x);
    float2 bs  = nmj_df64_split(b.x);
    float e = ((as_.x * bs.x - p) + as_.x * bs.y + as_.y * bs.x) + as_.y * bs.y;
    e = e + a.x * b.y + a.y * b.x;
    return float2(p, e);
}

float2 nmj_df64_mul_f(float2 a, float b)
{
    float p = a.x * b;
    float2 as_ = nmj_df64_split(a.x);
    float2 bs  = nmj_df64_split(b);
    float e = ((as_.x * bs.x - p) + as_.x * bs.y + as_.y * bs.x) + as_.y * bs.y;
    e = e + a.y * b;
    return float2(p, e);
}

// ============================================================================
// Resolve c-value — verbatim from WGSL
// ============================================================================

float2 nmj_resolveC(int poi_v, int cPath_v, float t, float cSpeed_v, float cRadius_v, float cReal_v, float cImag_v)
{
    if (poi_v > 0) { return nmj_getPOI(poi_v); }
    if (cPath_v > 0) { return nmj_getAnimatedC(cPath_v, t * cSpeed_v, cRadius_v); }
    return float2(cReal_v, cImag_v);
}

// ============================================================================
// df64 coordinate transform — verbatim from WGSL
// transformCoords returns [reDF, imDF] via out params (WGSL returns array<vec2,2>)
// ============================================================================

void nmj_transformCoords(float2 fragCoord, float2 res,
                          float cx, float cy, float zm, float rot,
                          out float2 reDF, out float2 imDF)
{
    float2 uv = (fragCoord - 0.5 * res) / min(res.x, res.y);
    float angle = -rot * NMJ_TAU / 360.0;
    float cs = cos(angle);
    float sn = sin(angle);
    // GLSL golden: mat2(cs,-sn,sn,cs) * uv. GLSL mat2 is COLUMN-MAJOR, so it equals
    // (cs*uv.x + sn*uv.y, -sn*uv.x + cs*uv.y) — opposite rotation direction from the
    // WGSL transcription (cs*x-sn*y, sn*x+cs*y). Only diverges for nonzero rotation.
    uv = float2(cs * uv.x + sn * uv.y, -sn * uv.x + cs * uv.y);

    float scale = 2.5 / zm;
    reDF = nmj_df64_add(nmj_df64_mul_f(nmj_df64_from(uv.x), scale), nmj_df64_from(cx));
    imDF = nmj_df64_add(nmj_df64_mul_f(nmj_df64_from(uv.y), scale), nmj_df64_from(cy));
}

// ============================================================================
// JuliaResult struct (mirrors WGSL struct)
// ============================================================================

struct NMJuliaResult
{
    float iter;
    float zMag2;
    float dzMag2;
    float stripeSum;
    float stripeCount;
    float stripeLast;
    float trapMin;
};

// ============================================================================
// Unified Julia iteration — verbatim from WGSL
// ============================================================================

NMJuliaResult nmj_juliaIterate(float2 z0Re, float2 z0Im, float2 c,
                                int maxIter, float freq, int trap)
{
    float2 zRe = z0Re;
    float2 zIm = z0Im;
    float2 dz = float2(1.0, 0.0);
    float i = 0.0;
    float stripeSum = 0.0;
    float stripeLast = 0.0;
    float stripeCount = 0.0;
    float trapMin = 1e10;
    float bail2 = NMJ_BAILOUT * NMJ_BAILOUT;

    float2 zSlow = float2(z0Re.x, z0Im.x);
    int period = 0;

    [loop]
    for (int n = 0; n < 1000; n = n + 1)
    {
        if (n >= maxIter) { break; }

        // Derivative: dz = 2*z*dz (float32 using hi parts)
        float2 zF = float2(zRe.x, zIm.x);
        dz = 2.0 * nmj_cmul(zF, dz);

        // Iteration: z = z² + c in df64
        float2 zRe2  = nmj_df64_mul(zRe, zRe);
        float2 zIm2  = nmj_df64_mul(zIm, zIm);
        float2 zReIm = nmj_df64_mul(zRe, zIm);

        zRe = nmj_df64_add(nmj_df64_sub(zRe2, zIm2), nmj_df64_from(c.x));
        zIm = nmj_df64_add(nmj_df64_mul_f(zReIm, 2.0), nmj_df64_from(c.y));

        // Bailout check (float32 hi parts)
        float zMag2 = zRe.x * zRe.x + zIm.x * zIm.x;
        if (zMag2 > bail2) { break; }

        i = i + 1.0;

        // Stripe average accumulation (float32 from hi parts)
        float2 zHi = float2(zRe.x, zIm.x);
        if (freq > 0.0)
        {
            stripeLast = 0.5 * sin(freq * atan2(zHi.y, zHi.x)) + 0.5;
            stripeSum  = stripeSum + stripeLast;
            stripeCount = stripeCount + 1.0;
        }

        // Orbit trap accumulation
        float td;
        if (trap == 0)
        {
            td = length(zHi);
        }
        else if (trap == 1)
        {
            td = min(abs(zHi.x), abs(zHi.y));
        }
        else
        {
            td = abs(length(zHi) - 1.0);
        }
        trapMin = min(trapMin, td);

        // Period detection
        period = period + 1;
        if (period == 20)
        {
            period = 0;
            zSlow = zHi;
        }
        else if (distance(zHi, zSlow) < 1e-10)
        {
            i = (float)maxIter;
            break;
        }
    }

    NMJuliaResult r;
    r.iter        = i;
    r.zMag2       = zRe.x * zRe.x + zIm.x * zIm.x;
    r.dzMag2      = dot(dz, dz);
    r.stripeSum   = stripeSum;
    r.stripeCount = stripeCount;
    r.stripeLast  = stripeLast;
    r.trapMin     = trapMin;
    return r;
}

// ============================================================================
// Output extraction — verbatim from WGSL
// ============================================================================

float nmj_outputSmoothIteration(NMJuliaResult r, float maxIter)
{
    if (r.iter >= maxIter) { return 0.0; }
    float log_zn = log(r.zMag2) * 0.5;
    float nu = log(log_zn / NMJ_LOG2) / NMJ_LOG2;
    return clamp((r.iter + 1.0 - nu) / maxIter, 0.0, 1.0);
}

float nmj_outputDistanceEstimation(NMJuliaResult r, float maxIter)
{
    if (r.iter >= maxIter) { return 0.0; }
    float zMag  = sqrt(r.zMag2);
    float dzMag = sqrt(r.dzMag2);
    if (dzMag < 1e-10) { return 0.0; }
    float dist = 2.0 * zMag * log(zMag) / dzMag;
    return clamp(log(dist + 1.0) * 2.0, 0.0, 1.0);
}

float nmj_outputStripeAverage(NMJuliaResult r, float maxIter)
{
    if (r.iter >= maxIter) { return 0.0; }
    if (r.stripeCount < 1.0) { return 0.0; }
    float avg = r.stripeSum / r.stripeCount;
    float prevAvg = avg;
    if (r.stripeCount > 1.0) { prevAvg = (r.stripeSum - r.stripeLast) / (r.stripeCount - 1.0); }
    float log_zn = log(r.zMag2) * 0.5;
    float nu = log(log_zn / NMJ_LOG2) / NMJ_LOG2;
    float f = clamp(1.0 - nu + floor(nu), 0.0, 1.0);
    return clamp(lerp(prevAvg, avg, f), 0.0, 1.0);
}

float nmj_outputOrbitTrap(NMJuliaResult r, float maxIter)
{
    if (r.iter >= maxIter) { return 0.0; }
    return clamp(1.0 - r.trapMin, 0.0, 1.0);
}

// ============================================================================
// Normal map — runs iteration 3 times for finite differences (verbatim WGSL)
// ============================================================================

float nmj_iterateSmooth(float2 fragCoord, float2 c, int maxIter,
                         float2 res, float cx, float cy, float zm, float rot)
{
    float2 zRe, zIm;
    nmj_transformCoords(fragCoord, res, cx, cy, zm, rot, zRe, zIm);
    float i = 0.0;
    float bail2 = NMJ_BAILOUT * NMJ_BAILOUT;

    [loop]
    for (int n = 0; n < 1000; n = n + 1)
    {
        if (n >= maxIter) { break; }

        float2 zRe2  = nmj_df64_mul(zRe, zRe);
        float2 zIm2  = nmj_df64_mul(zIm, zIm);
        float2 zReIm = nmj_df64_mul(zRe, zIm);

        zRe = nmj_df64_add(nmj_df64_sub(zRe2, zIm2), nmj_df64_from(c.x));
        zIm = nmj_df64_add(nmj_df64_mul_f(zReIm, 2.0), nmj_df64_from(c.y));

        float zMag2 = zRe.x * zRe.x + zIm.x * zIm.x;
        if (zMag2 > bail2) { break; }
        i = i + 1.0;
    }

    if (i >= (float)maxIter) { return 0.0; }
    float zMag2_out = zRe.x * zRe.x + zIm.x * zIm.x;
    float log_zn = log(zMag2_out) * 0.5;
    float nu = log(log_zn / NMJ_LOG2) / NMJ_LOG2;
    return clamp((i + 1.0 - nu) / (float)maxIter, 0.0, 1.0);
}

float nmj_outputNormalMap(float2 fragCoord, float2 c, int maxIter, float angle,
                           float2 res, float cx, float cy, float zm, float rot)
{
    float d0 = nmj_iterateSmooth(fragCoord,                    c, maxIter, res, cx, cy, zm, rot);
    float d1 = nmj_iterateSmooth(fragCoord + float2(1.0, 0.0), c, maxIter, res, cx, cy, zm, rot);
    float d2 = nmj_iterateSmooth(fragCoord + float2(0.0, 1.0), c, maxIter, res, cx, cy, zm, rot);

    float3 normal = normalize(float3(d1 - d0, d2 - d0, 0.05));
    float rad = angle * NMJ_TAU / 360.0;
    float3 lightDir = normalize(float3(cos(rad), sin(rad), 0.7));
    return clamp(max(dot(normal, lightDir), 0.0), 0.0, 1.0);
}

// ============================================================================
// nm_julia — core per-pixel evaluation. `fragCoord` is the raw pixel position
// (NM_FragCoord), `tileOff` is tileOffset, `fullRes` is fullResolution.
// Mirrors WGSL main() exactly.
// ============================================================================

float4 nm_julia(float2 fragCoord, float2 tileOff, float2 fullRes, float timeVal)
{
    // Resolve c-value
    float2 c = nmj_resolveC(poi, cPath, timeVal, cSpeed, cRadius, cReal, cImag);

    // Zoom: sinusoidal when animated, static pow(10, depth) when not
    float effectiveZoom;
    if (zoomSpeed > 0.0)
    {
        float phase = 0.5 * (1.0 - cos(timeVal * zoomSpeed * NMJ_TAU));
        effectiveZoom = pow(10.0, zoomDepth * phase);
    }
    else
    {
        effectiveZoom = pow(10.0, zoomDepth);
    }

    // pos.xy + tileOffset — matches WGSL: pos.xy + tileOffset
    float2 coord = fragCoord + tileOff;

    float value;
    if (outputMode == 4)
    {
        // Normal map: 3x iteration, uses fullResolution
        value = nmj_outputNormalMap(coord, c, iterations, lightAngle,
                                    fullRes, centerX, centerY, effectiveZoom, rotation);
    }
    else
    {
        float2 reDF, imDF;
        nmj_transformCoords(coord, fullRes, centerX, centerY, effectiveZoom, rotation, reDF, imDF);
        NMJuliaResult r = nmj_juliaIterate(reDF, imDF, c, iterations, stripeFreq, trapShape);

        if (outputMode == 0)
        {
            value = nmj_outputSmoothIteration(r, (float)iterations);
        }
        else if (outputMode == 1)
        {
            value = nmj_outputDistanceEstimation(r, (float)iterations);
        }
        else if (outputMode == 2)
        {
            value = nmj_outputStripeAverage(r, (float)iterations);
        }
        else if (outputMode == 3)
        {
            value = nmj_outputOrbitTrap(r, (float)iterations);
        }
        else
        {
            value = nmj_outputSmoothIteration(r, (float)iterations);
        }
    }

    // Invert (boolean stored as float; WGSL tests > 0.5)
    if (invert > 0.5)
    {
        value = 1.0 - value;
    }

    return float4((float3)value, 1.0);
}

#endif // NM_JULIA_INCLUDED
