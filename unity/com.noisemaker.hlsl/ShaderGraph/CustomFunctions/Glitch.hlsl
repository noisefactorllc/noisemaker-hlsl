#ifndef NM_SG_GLITCH_INCLUDED
#define NM_SG_GLITCH_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for classicNoisedeck/glitch.
//
// Single-pass filter -> a single Custom Function node samples InputTex.
// Each global param from definition.js maps to a named input:
//   glitchiness  -> Glitchiness  (float)  [0,100]   default 0
//   aberration   -> Aberration   (float)  [0,100]   default 0
//   xChonk       -> XChonk       (float, int sem) [1,100] default 1
//   yChonk       -> YChonk       (float, int sem) [1,100] default 1
//   seed         -> Seed         (float, int sem) [1,100] default 1
//   scanlinesAmt -> ScanlinesAmt (float, int sem) [0,100] default 0
//   snowAmt      -> SnowAmt      (float)  [0,100]   default 0
//   vignetteAmt  -> VignetteAmt  (float)  [-100,100] default 0
//   distortion   -> Distortion   (float)  [-100,100] default 0
//   aspectLens   -> AspectLens   (float, bool 0/1)  default 0
// Engine globals (Resolution, Time, AspectRatio) are passed as node inputs.
//
// UV/FragCoord: the runtime path computes uv = fragCoord/resolution, samples
// inputTex in 0..1 space, and uses raw fragCoord for snow. In the node, UV is the
// input texture's own 0..1 UV; FragCoord = UV * Resolution. The WGSL samples
// inputTex directly in 0..1 lensed-coord space (no division by texture dims).
//
// Self-contained (does NOT include NMFullscreen.hlsl / NMCore.hlsl). Helpers/core
// are mirrored VERBATIM from Shaders/Effects/classicNoisedeck/Glitch.hlsl,
// name-prefixed `nmsg_` to avoid symbol clashes with the runtime include.
// =============================================================================

#define NMSG_G_PI  3.14159265359
#define NMSG_G_TAU 6.28318530718

// PCG-3D (riccardoscalco, MIT) — identical in all references.
uint3 nmsg_glitch_pcg(uint3 v)
{
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return v;
}

// This effect's PRNG: plain (uint3)p TRUNCATION, NO sign-fold.
float3 nmsg_glitch_prng(float3 p)
{
    return float3(nmsg_glitch_pcg((uint3)p)) / 4294967295.0;
}

float nmsg_glitch_map(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

// SIN-based periodicFunction (this effect's own).
float nmsg_glitch_periodicFunction(float p)
{
    return nmsg_glitch_map(sin(p * NMSG_G_TAU), -1.0, 1.0, 0.0, 1.0);
}

float nmsg_glitch_f(float2 st, int seedv)
{
    return nmsg_glitch_prng(float3(floor(st), (float)seedv)).x;
}

float nmsg_glitch_bicubic(float2 p, int seedv)
{
    float x = p.x;
    float y = p.y;
    float x1 = floor(x);
    float y1 = floor(y);
    float x2 = x1 + 1.0;
    float y2 = y1 + 1.0;
    float f11 = nmsg_glitch_f(float2(x1, y1), seedv);
    float f12 = nmsg_glitch_f(float2(x1, y2), seedv);
    float f21 = nmsg_glitch_f(float2(x2, y1), seedv);
    float f22 = nmsg_glitch_f(float2(x2, y2), seedv);
    float f11x = (nmsg_glitch_f(float2(x1 + 1.0, y1), seedv) - nmsg_glitch_f(float2(x1 - 1.0, y1), seedv)) / 2.0;
    float f12x = (nmsg_glitch_f(float2(x1 + 1.0, y2), seedv) - nmsg_glitch_f(float2(x1 - 1.0, y2), seedv)) / 2.0;
    float f21x = (nmsg_glitch_f(float2(x2 + 1.0, y1), seedv) - nmsg_glitch_f(float2(x2 - 1.0, y1), seedv)) / 2.0;
    float f22x = (nmsg_glitch_f(float2(x2 + 1.0, y2), seedv) - nmsg_glitch_f(float2(x2 - 1.0, y2), seedv)) / 2.0;
    float f11y = (nmsg_glitch_f(float2(x1, y1 + 1.0), seedv) - nmsg_glitch_f(float2(x1, y1 - 1.0), seedv)) / 2.0;
    float f12y = (nmsg_glitch_f(float2(x1, y2 + 1.0), seedv) - nmsg_glitch_f(float2(x1, y2 - 1.0), seedv)) / 2.0;
    float f21y = (nmsg_glitch_f(float2(x2, y1 + 1.0), seedv) - nmsg_glitch_f(float2(x2, y1 - 1.0), seedv)) / 2.0;
    float f22y = (nmsg_glitch_f(float2(x2, y2 + 1.0), seedv) - nmsg_glitch_f(float2(x2, y2 - 1.0), seedv)) / 2.0;
    float f11xy = (nmsg_glitch_f(float2(x1 + 1.0, y1 + 1.0), seedv) - nmsg_glitch_f(float2(x1 + 1.0, y1 - 1.0), seedv) - nmsg_glitch_f(float2(x1 - 1.0, y1 + 1.0), seedv) + nmsg_glitch_f(float2(x1 - 1.0, y1 - 1.0), seedv)) / 4.0;
    float f12xy = (nmsg_glitch_f(float2(x1 + 1.0, y2 + 1.0), seedv) - nmsg_glitch_f(float2(x1 + 1.0, y2 - 1.0), seedv) - nmsg_glitch_f(float2(x1 - 1.0, y2 + 1.0), seedv) + nmsg_glitch_f(float2(x1 - 1.0, y2 - 1.0), seedv)) / 4.0;
    float f21xy = (nmsg_glitch_f(float2(x2 + 1.0, y1 + 1.0), seedv) - nmsg_glitch_f(float2(x2 + 1.0, y1 - 1.0), seedv) - nmsg_glitch_f(float2(x2 - 1.0, y1 + 1.0), seedv) + nmsg_glitch_f(float2(x2 - 1.0, y1 - 1.0), seedv)) / 4.0;
    float f22xy = (nmsg_glitch_f(float2(x2 + 1.0, y2 + 1.0), seedv) - nmsg_glitch_f(float2(x2 + 1.0, y2 - 1.0), seedv) - nmsg_glitch_f(float2(x2 - 1.0, y2 + 1.0), seedv) + nmsg_glitch_f(float2(x2 - 1.0, y2 - 1.0), seedv)) / 4.0;

    float4x4 Q = float4x4(
        f11,  f12,  f11y,  f12y,
        f21,  f22,  f21y,  f22y,
        f11x, f12x, f11xy, f12xy,
        f21x, f22x, f21xy, f22xy
    );
    float4x4 S = float4x4(
        1.0, 0.0, -3.0,  2.0,
        0.0, 0.0,  3.0, -2.0,
        0.0, 1.0, -2.0,  1.0,
        0.0, 0.0, -1.0,  1.0
    );
    float4x4 T = float4x4(
        1.0,  0.0, 0.0,  0.0,
        0.0,  0.0, 1.0,  0.0,
        -3.0, 3.0, -2.0, -1.0,
        2.0, -2.0, 1.0,  1.0
    );
    float4x4 A = mul(mul(T, Q), S);

    float t = frac(p.x);
    float uu = frac(p.y);
    float4 tv = float4(1.0, t, t * t, t * t * t);
    float4 uv = float4(1.0, uu, uu * uu, uu * uu * uu);
    return dot(mul(tv, A), uv);
}

float4 nmsg_glitch_scanlines(float4 color, float2 st, float2 res, float scanlinesAmtv, float timev, int seedv)
{
    float centerDistance = length(float2(0.5, 0.5) - st) * NMSG_G_PI * 0.5;
    float noise = nmsg_glitch_periodicFunction(nmsg_glitch_bicubic(st * 4.0, seedv) - timev) * nmsg_glitch_map(scanlinesAmtv, 0.0, 100.0, 0.0, 0.5);
    float hatch = (sin(lerp(st.y, st.y + noise, pow(centerDistance, 8.0)) * res.y * 1.5) + 1.0) * 0.5;
    float4 result = color;
    result = float4(lerp(color.rgb, color.rgb * hatch, nmsg_glitch_map(scanlinesAmtv, 0.0, 100.0, 0.0, 0.5)), color.a);
    return result;
}

float4 nmsg_glitch_snow(float4 color, float2 fragCoord, float snowAmtv, float timev)
{
    float amt = snowAmtv / 100.0;
    float noise = nmsg_glitch_prng(float3(fragCoord, timev * 1000.0)).x;

    float maskNoise = nmsg_glitch_prng(float3(fragCoord + 10.0, timev * 1000.0)).x;
    float maskNoiseSparse = clamp(maskNoise - 0.93875, 0.0, 0.06125) * 16.0;

    float mask;
    if (amt < 0.5)
    {
        mask = lerp(0.0, maskNoiseSparse, amt * 2.0);
    }
    else
    {
        mask = lerp(maskNoiseSparse, maskNoise * maskNoise, nmsg_glitch_map(amt, 0.5, 1.0, 0.0, 1.0));
        if (amt > 0.75)
        {
            mask = lerp(mask, 1.0, nmsg_glitch_map(amt, 0.75, 1.0, 0.0, 1.0));
        }
    }

    return float4(lerp(color.rgb, float3(noise, noise, noise), mask), color.a);
}

// Shader Graph Custom Function entry. InputTex/SS/UV supply the source surface;
// Resolution + Time + AspectRatio are engine globals passed as node inputs.
// TODO(verify): SS must be a clamp, non-sRGB (linear) sampler so it matches the
// runtime bilinear/clamp/linear path (H7).
void NM_Glitch_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float2            Resolution,
    float             Time,
    float             AspectRatio,
    float             Glitchiness,
    float             Aberration,
    float             XChonk,
    float             YChonk,
    float             Seed,
    float             ScanlinesAmt,
    float             SnowAmt,
    float             VignetteAmt,
    float             Distortion,
    float             AspectLens,
    out float4        Out)
{
    float2 fragCoord = UV * Resolution;

    // ---- glitch() ----
    float2 st = UV;
    float2 freq = float2(1.0, 1.0);
    freq.x = freq.x * nmsg_glitch_map(XChonk, 1.0, 100.0, 50.0, 1.0);
    freq.y = freq.y * nmsg_glitch_map(YChonk, 1.0, 100.0, 50.0, 1.0);

    freq = freq * float2(nmsg_glitch_periodicFunction(nmsg_glitch_prng(float3(floor(st * freq), 0.0)).x - Time),
                         nmsg_glitch_periodicFunction(nmsg_glitch_prng(float3(floor(st * freq), 0.0)).x - Time));

    float g = nmsg_glitch_map(Glitchiness, 0.0, 100.0, 0.0, 1.0);

    float xDrift = nmsg_glitch_prng(float3(floor(st * freq) + 10.0, 0.0)).x * g;
    float yDrift = nmsg_glitch_prng(float3(floor(st * freq) - 10.0, 0.0)).x * g;

    float sparseness = nmsg_glitch_map(Glitchiness, 0.0, 100.0, 8.0, 2.0);

    float rand = nmsg_glitch_prng(float3(floor(st * freq), 0.0)).x;
    float xOffset = clamp((nmsg_glitch_periodicFunction(rand + xDrift - Time) - nmsg_glitch_periodicFunction(xDrift - Time) * sparseness) * 4.0, 0.0, 1.0);
    float yOffset = clamp((nmsg_glitch_periodicFunction(rand + yDrift - Time) - nmsg_glitch_periodicFunction(yDrift - Time) * sparseness) * 4.0, 0.0, 1.0);

    float refractAmt = g * 0.125;

    st.x = (st.x + sin(xOffset * NMSG_G_TAU) * refractAmt);
    st.x = st.x - 1.0 * floor(st.x / 1.0); // nm_mod(st.x, 1.0)
    st.y = (st.y + sin(yOffset * NMSG_G_TAU) * refractAmt);
    st.y = st.y - 1.0 * floor(st.y / 1.0); // nm_mod(st.y, 1.0)

    float2 diff = float2(0.5 - st.x, 0.5 - st.y);
    if (AspectLens > 0.5)
    {
        diff = float2(0.5 * AspectRatio, 0.5) - float2(st.x * AspectRatio, st.y);
    }
    float centerDist = length(diff);

    float distort = 0.0;
    float zoom = 1.0;
    if (Distortion < 0.0)
    {
        distort = nmsg_glitch_map(Distortion, -100.0, 0.0, -0.5, 0.0);
        zoom = nmsg_glitch_map(Distortion, -100.0, 0.0, 0.01, 0.0);
    }
    else
    {
        distort = nmsg_glitch_map(Distortion, 0.0, 100.0, 0.0, 0.5);
        zoom = nmsg_glitch_map(Distortion, 0.0, 100.0, 0.0, -0.25);
    }

    float2 lensedCoords = frac((st - diff * zoom) - diff * centerDist * centerDist * distort);

    float aberrationOffset = nmsg_glitch_map(Aberration, 0.0, 100.0, 0.0, 0.05) * centerDist * NMSG_G_PI * 0.5;

    float redOffset = lerp(clamp(lensedCoords.x + aberrationOffset, 0.0, 1.0), lensedCoords.x, lensedCoords.x);
    float4 red = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, float2(redOffset, lensedCoords.y));

    float4 green = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, lensedCoords);

    float blueOffset = lerp(lensedCoords.x, clamp(lensedCoords.x - aberrationOffset, 0.0, 1.0), lensedCoords.x);
    float4 blue = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, float2(blueOffset, lensedCoords.y));

    float4 color = float4(red.r, green.g, blue.b, green.a);

    // ---- scanlines() / snow() ----
    color = nmsg_glitch_scanlines(color, UV, Resolution, ScanlinesAmt, Time, (int)Seed);
    color = nmsg_glitch_snow(color, fragCoord, SnowAmt, Time);

    // ---- vignette (WGSL parenthesised form) ----
    if (VignetteAmt < 0.0)
    {
        color = float4(
            lerp(color.rgb * (1.0 - pow(length(float2(0.5, 0.5) - UV) * 1.125, 2.0)), color.rgb, nmsg_glitch_map(VignetteAmt, -100.0, 0.0, 0.0, 1.0)),
            max(color.a, length(float2(0.5, 0.5) - UV) * nmsg_glitch_map(VignetteAmt, -100.0, 0.0, 1.0, 0.0))
        );
    }
    else
    {
        color = float4(
            lerp(color.rgb, 1.0 - (1.0 - color.rgb * (1.0 - pow(length(float2(0.5, 0.5) - UV) * 1.125, 2.0))), nmsg_glitch_map(VignetteAmt, 0.0, 100.0, 0.0, 1.0)),
            max(color.a, length(float2(0.5, 0.5) - UV) * nmsg_glitch_map(VignetteAmt, -100.0, 0.0, 1.0, 0.0))
        );
    }

    Out = color;
}

#endif // NM_SG_GLITCH_INCLUDED
