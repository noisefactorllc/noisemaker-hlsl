#ifndef NM_GRADIENT_INCLUDED
#define NM_GRADIENT_INCLUDED

// =============================================================================
// Gradient.hlsl — synth/gradient, ported PIXEL-IDENTICALLY from the canonical
// WGSL source:
//   shaders/effects/synth/gradient/wgsl/gradient.wgsl
//
// Multi-color gradient generator (conic, diamond, fourCorners, linear,
// noiseGradient, radial, spiral) with rotation, repeat and animation speed.
//
// Helpers (rotate2D, getColor, blendColors, pcg/prng, hash2D, valueNoise,
// fbmNoise) are ported VERBATIM and INLINE per PORTING-GUIDE. The gradient's
// rotate2D has its own aspect-correct convention; do NOT substitute a generic
// rotate2D. Only pcg/prng come conceptually from NMCore, but this WGSL inlines
// its OWN pcg/prng so we reproduce them here exactly (fold variant, /0xffffffff).
//
// NUMERIC HAZARDS handled:
//  * st = globalCoord / fullRes (DIVIDES BY THE FULL vec2, both axes — this
//    effect does NOT divide by .y only; see WGSL main()).  (matches WGSL)
//  * fullRes = select(resolution, fullResolution, fullResolution.x > 0.0):
//    HLSL ternary  (fullResolution.x > 0.0) ? fullResolution : resolution.
//  * mat2x2<f32>(c,-s,s,c) is COLUMN-MAJOR in WGSL -> M*v = (c*x + s*y,
//    -s*x + c*y). Written out by hand to avoid HLSL row-major mul() transpose.
//  * atan2(y, x) argument order copied literally from WGSL.
//  * prng fold variant; divisor 4294967295.0 (NOT 2^32).
//  * (uint3)p is float->uint TRUNCATION (not asuint).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
// Bound by the runtime via MaterialPropertyBlock.
float  rotation;        // degrees, [-180,180]            (global "rotation")
int    gradientType;    // enum 0..6                      (global "type")
int    repeat;          // [1,4]                          (global "repeat")
int    colorCount;      // [2,4]                          (global "colorCount")
int    speed;           // [-5,5]                         (global "speed")
int    seed;            // [0,100]                        (global "seed")
float3 color1;          // default (1,0,0)
float3 color2;          // default (1,1,0)
float3 color3;          // default (0,1,0)
float3 color4;          // default (0,0,1)

// Local PI/TAU literals exactly as the WGSL declares them.
static const float NMG_PI  = 3.14159265359;
static const float NMG_TAU = 6.28318530718;

// ---- rotate2D (gradient's own aspect-correct variant) -----------------------
// WGSL:
//   let fullRes = select(resolution, fullResolution, fullResolution.x > 0.0);
//   let aspectRatio = fullRes.x / fullRes.y;
//   coord.x *= aspectRatio; coord -= (aspect*0.5, 0.5);
//   coord = mat2x2(c,-s,s,c) * coord;   // column-major
//   coord += (aspect*0.5, 0.5); coord.x /= aspectRatio;
float2 nmg_rotate2D(float2 st, float angle)
{
    float2 fullRes = (fullResolution.x > 0.0) ? fullResolution : resolution;
    float aspect = fullRes.x / fullRes.y;
    float2 coord = st;
    coord.x = coord.x * aspect;
    coord = coord - float2(aspect * 0.5, 0.5);
    float c = cos(angle);
    float s = sin(angle);
    // mat2x2<f32>(c,-s,s,c) * coord  (column-major) = (c*x + s*y, -s*x + c*y)
    coord = float2(c * coord.x + s * coord.y, -s * coord.x + c * coord.y);
    coord = coord + float2(aspect * 0.5, 0.5);
    coord.x = coord.x / aspect;
    return coord;
}

// ---- getColor ---------------------------------------------------------------
float3 nmg_getColor(int idx)
{
    switch (idx)
    {
        case 0:  return color1;
        case 1:  return color2;
        case 2:  return color3;
        default: return color4;
    }
}

// ---- blendColors: cycle through colorCount colors by 0-1 param t ------------
float3 nmg_blendColors(float t_in)
{
    float t = frac(t_in);
    float segment = t * (float)colorCount;
    int idx = (int)floor(segment);
    float localT = frac(segment);
    int next = idx + 1;
    if (next >= colorCount) { next = 0; }
    return lerp(nmg_getColor(idx), nmg_getColor(next), localT);
}

// ---- pcg PRNG (verbatim; this WGSL inlines its own copy) --------------------
uint3 nmg_pcg(uint3 seed_in)
{
    uint3 v = seed_in * 1664525u + 1013904223u;
    v.x = v.x + v.y * v.z;
    v.y = v.y + v.z * v.x;
    v.z = v.z + v.x * v.y;
    v = v ^ (v >> 16u);
    v.x = v.x + v.y * v.z;
    v.y = v.y + v.z * v.x;
    v.z = v.z + v.x * v.y;
    return v;
}

// ---- prng (fold variant A; divisor 4294967295.0 = float(0xffffffffu)) -------
// (uint3)p is float->uint truncation toward zero (NOT asuint).
float3 nmg_prng(float3 p0)
{
    float3 p = p0;
    p.x = (p.x >= 0.0) ? p.x * 2.0 : -p.x * 2.0 + 1.0;
    p.y = (p.y >= 0.0) ? p.y * 2.0 : -p.y * 2.0 + 1.0;
    p.z = (p.z >= 0.0) ? p.z * 2.0 : -p.z * 2.0 + 1.0;
    uint3 u = nmg_pcg((uint3)p);
    return float3(u) / 4294967295.0;
}

// ---- hash2D: prng(vec3(p, f32(seed))).x -------------------------------------
float nmg_hash2D(float2 p)
{
    return nmg_prng(float3(p, (float)seed)).x;
}

// ---- valueNoise (2D bilerp of hashed lattice with smoothstep weights) -------
float nmg_valueNoise(float2 p)
{
    float2 i = floor(p);
    float2 f = frac(p);
    float2 u = f * f * (3.0 - 2.0 * f);

    float a = nmg_hash2D(i);
    float b = nmg_hash2D(i + float2(1.0, 0.0));
    float c = nmg_hash2D(i + float2(0.0, 1.0));
    float d = nmg_hash2D(i + float2(1.0, 1.0));

    return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
}

// ---- fbmNoise: 4-octave fbm, amp 0.5 halved each octave, freq doubled -------
float nmg_fbmNoise(float2 p)
{
    float sum = 0.0;
    float amp = 0.5;
    float freq = 1.0;
    float maxVal = 0.0;
    [loop]
    for (int i = 0; i < 4; i = i + 1)
    {
        sum = sum + nmg_valueNoise(p * freq) * amp;
        maxVal = maxVal + amp;
        freq = freq * 2.0;
        amp = amp * 0.5;
    }
    return sum / maxVal;
}

// =============================================================================
// nm_gradient — core per-pixel evaluation. `globalCoord` is the fragment's
// pixel coordinate plus tileOffset (i.e. NM_GlobalCoord(i)). Returns RGBA.
// Mirrors WGSL main() exactly. (`time`/`fullResolution`/`resolution` are the
// engine-provided NMFullscreen aliases; the Shader Graph wrapper overrides them
// via its own locals — see Gradient.hlsl wrapper in ShaderGraph/.)
// =============================================================================
float4 nm_gradient(float2 globalCoord, float2 res, float2 fullRes_in, float timeVal)
{
    // WGSL: fullRes = select(resolution, fullResolution, fullResolution.x > 0.0)
    float2 fullRes = (fullRes_in.x > 0.0) ? fullRes_in : res;
    float2 st = globalCoord / fullRes;           // DIVIDES BY FULL vec2 (both axes)
    float aspectR = fullRes.x / fullRes.y;

    // rotation degrees -> radians (negated, as in WGSL)
    float angle = -rotation * NMG_PI / 180.0;

    // rotation for linear / fourCorners gradients
    float2 rotatedSt = nmg_rotate2D(st, angle);

    // centered coords for radial / conic
    float2 centered = st - 0.5;
    centered.x = centered.x * aspectR;

    // rotated centered for conic   (mat2x2(c,-s,s,c) * centered, column-major)
    float c = cos(angle);
    float s = sin(angle);
    float2 rotatedCentered = float2(c * centered.x + s * centered.y,
                                    -s * centered.x + c * centered.y);

    float3 color;
    float t;
    float timeOffset = timeVal * (float)speed;

    switch (gradientType)
    {
        case 0:
        {
            // Conic / angular gradient
            float a = atan2(rotatedCentered.y, rotatedCentered.x);
            t = (a + NMG_PI) / NMG_TAU;
            t = frac(t * (float)repeat + timeOffset);
            color = nmg_blendColors(t);
            break;
        }
        case 1:
        {
            // Diamond gradient - L1 distance with rotation
            t = abs(rotatedCentered.x) + abs(rotatedCentered.y);
            t = frac(t * (float)repeat + timeOffset);
            color = nmg_blendColors(t);
            break;
        }
        case 2:
        {
            // Four corners - bilinear interpolation
            float2 cornerSt = nmg_rotate2D(st, angle);
            float3 cTL = color1;
            float3 cTR = color1;
            float3 cBL = color2;
            float3 cBR = color2;
            if (colorCount >= 3)
            {
                cTR = color2;
                cBL = color3;
                cBR = color3;
            }
            if (colorCount >= 4)
            {
                cBR = color4;
            }
            float3 top = lerp(cTL, cTR, cornerSt.x);
            float3 bottom = lerp(cBL, cBR, cornerSt.x);
            color = lerp(bottom, top, cornerSt.y);
            break;
        }
        case 3:
        {
            // Linear gradient along rotated y-axis
            t = rotatedSt.y;
            t = frac(t * (float)repeat + timeOffset);
            color = nmg_blendColors(t);
            break;
        }
        case 4:
        {
            // Noise gradient with rotation
            float2 noiseSt = rotatedCentered * 4.0;
            t = nmg_fbmNoise(noiseSt);
            t = frac(t * (float)repeat + timeOffset);
            color = nmg_blendColors(t);
            break;
        }
        case 5:
        {
            // Radial gradient from center
            float2 rotatedPoint = float2(c * centered.x + s * centered.y,
                                         -s * centered.x + c * centered.y);
            float dist = length(rotatedPoint) * 2.0;
            t = dist;
            t = frac(t * (float)repeat + timeOffset);
            color = nmg_blendColors(t);
            break;
        }
        case 6:
        {
            // Spiral gradient - angle + distance
            float a = atan2(rotatedCentered.y, rotatedCentered.x);
            float dist = length(centered);
            t = frac(a / NMG_TAU + dist * 2.0);
            t = frac(t * (float)repeat + timeOffset);
            color = nmg_blendColors(t);
            break;
        }
        default:
        {
            color = color1;
            break;
        }
    }

    return float4(color, 1.0);
}

#endif // NM_GRADIENT_INCLUDED
