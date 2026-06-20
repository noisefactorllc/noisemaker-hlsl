#ifndef NM_EFFECT_NAVIERSTOKES_INCLUDED
#define NM_EFFECT_NAVIERSTOKES_INCLUDED

// =============================================================================
// NavierStokes.hlsl — synth/navierStokes (func: "navierStokes")
//
// Stable-fluids Navier-Stokes solver. Ported PIXEL-IDENTICALLY from the
// canonical WGSL sources (top-left origin, no per-effect Y flip):
//   wgsl/nsSplat.wgsl      progName "nsSplat"      (frag_nsSplat)
//   wgsl/nsAdvect.wgsl     progName "nsAdvect"     (frag_nsAdvect)
//   wgsl/nsDivergence.wgsl progName "nsDivergence" (frag_nsDivergence)
//   wgsl/nsPressure.wgsl   progName "nsPressure"   (frag_nsPressure)  repeat:iterations
//   wgsl/nsGradient.wgsl   progName "nsGradient"   (frag_nsGradient)
//   wgsl/nsSmooth.wgsl     progName "nsSmooth"     (frag_nsSmooth)
//   wgsl/ns.wgsl           progName "ns"           (frag_ns)
//
// MULTI-PASS / FEEDBACK: 7 passes per frame. Persistent ('global_') state
// textures global_ns_velocity (rg=velocity, b=dye, a=initialized-flag) and
// global_ns_pressure (r=pressure, g=divergence) carry sim state across frames
// and within-frame (the runtime ping-pongs each on every write — see
// reference 04 §10.2/§10.6/§10.7). global_ns_smoothed is a transient full-res
// upsample target. The pressure pass runs N=iterations times/frame; the
// runtime ping-pongs global_ns_pressure per iteration. The shader has NO
// iteration index (none is injected).
//
// NOTE: multi-pass effect → ships as a runtime-rendered Texture2D. No Shader
// Graph Custom Function wrapper is provided (the C# runtime drives the 7
// passes in order, rebinding global_ns_velocity/global_ns_pressure/
// global_ns_smoothed read/write targets per pass).
//
// PORTING-GUIDE / parity notes:
//  * WGSL textureLoad(t, coord, 0) → t.Load(int3(coord, 0)) (integer texel
//    fetch, point, no filtering). rgba16f state is read this way in every sim
//    pass. clamp(idx, minIdx, maxIdx) reproduced literally.
//  * WGSL textureSampleLevel(t, s, uv, 0.0) → t.SampleLevel(sampler_t, uv, 0.0)
//    (linear, clamp-to-edge, non-sRGB). Used only for inputTex in nsSplat/ns.
//  * fragCoord = pos.xy (@builtin(position), top-left, +0.5 centered) →
//    NM_FragCoord(i). Sim passes derive uv = fragCoord / texSize (the bound
//    texture's OWN dimensions). nsSmooth/ns derive uv = pos.xy / resolution
//    (the resolution UNIFORM, == render-target size), reproduced exactly.
//  * fract→frac, mix→lerp, modulo is NEVER used here (no nm_mod needed).
//  * vec2<i32>(textureDimensions(t,0)) → GetDimensions(w,h); int2((int)w,(int)h).
//  * vec2<i32>(floor(x)) and vec2<i32>(x) both truncate after floor in WGSL for
//    the non-negative fragCoord/texel ranges used; we mirror each cast site.
//  * Helpers (hash11/hash22/lum/fetch*/sampleBilinear/quad3v/bicubic4v/
//    catmull3v/catmull4v) are ported verbatim, inline, per program. NONE come
//    from NMCore (none of pcg/prng/random/nm_mod/etc. are used by this effect).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Distinct input samplers across all passes ------------------------------
// nsSplat:      bufTex (Load), inputTex (Sample)
// nsAdvect:     bufTex (Load)
// nsDivergence: velTex (Load)
// nsPressure:   bufTex (Load)
// nsGradient:   velTex (Load), pressureTex (Load)
// nsSmooth:     canvasTex (Load)
// ns:           fbTex (Load), inputTex (Sample)
// The runtime rebinds these per pass per definition.js inputs{}.
Texture2D    bufTex;        SamplerState sampler_bufTex;
Texture2D    inputTex;      SamplerState sampler_inputTex;
Texture2D    velTex;        SamplerState sampler_velTex;
Texture2D    pressureTex;   SamplerState sampler_pressureTex;
Texture2D    canvasTex;     SamplerState sampler_canvasTex;
Texture2D    fbTex;         SamplerState sampler_fbTex;

// ---- Per-effect named uniforms (match definition.js uniformLayouts) ----------
// nsSplat:   seed(d0.w), speed(d1.x), inputForce(d1.y), inputDye(d1.z), resetState(d1.w)
// nsAdvect:  speed(d0.w), dyeDecay(d1.x), velocityDecay(d1.y)
// nsSmooth:  smoothing(d0.z)
// ns:        inputIntensity(d1.x)
// resolution (d0.xy) is the engine global `resolution` (NMFullscreen alias).
float speed;            // globals.speed       default 100
float inputForce;       // globals.inputForce  default 0.5
float inputDye;         // globals.inputDye    default 0.9
float resetState;       // globals.resetState  boolean (1.0/0.0), tested > 0.5
float dyeDecay;         // globals.dyeDecay    default 98
float velocityDecay;    // globals.velocityDecay default 99
int   smoothing;        // globals.smoothing   default 1 (linear)
float inputIntensity;   // globals.inputIntensity default 10
int   seed;             // globals.seed        default 1

// =============================================================================
// PASS: nsSplat — external-force / source pass (frag_nsSplat)
// =============================================================================
static const int NS_NUM_INIT_VORTICES = 9;

float ns_hash11(float x)
{
    return frac(sin(x * 12.9898) * 43758.5453);
}

float2 ns_hash22(float2 p)
{
    float2 q = float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)));
    return frac(sin(q) * 43758.5453);
}

float ns_lum(float3 c)
{
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
}

float4 frag_nsSplat(NMVaryings i) : SV_Target
{
    float seedF      = (float)seed;
    float speedU     = speed;
    float inputForceU = inputForce;
    float inputDyeU  = inputDye;
    bool  resetStateB = resetState > 0.5;

    uint tw, th;
    bufTex.GetDimensions(tw, th);
    int2 texSizeI = int2((int)tw, (int)th);
    float2 texSize = float2(texSizeI);
    float2 fragCoord = NM_FragCoord(i);
    float2 uv = fragCoord / texSize;

    // State is rgba16f — read with Load on integer texel coords (point fetch).
    float4 prev = bufTex.Load(int3(clamp(int2(fragCoord), int2(0, 0), texSizeI - int2(1, 1)), 0));

    bool bufferEmpty = (prev.a == 0.0);
    if (resetStateB || bufferEmpty)
    {
        float2 vel = float2(0.0, 0.0);
        float dye = 0.0;
        for (int vi = 0; vi < NS_NUM_INIT_VORTICES; vi = vi + 1)
        {
            float idf = (float)vi;
            float2 c = ns_hash22(float2(idf * 7.31 + 1.0, seedF * 13.7 + idf));
            float signv = -1.0;
            if (ns_hash11(idf * 4.17 + seedF * 5.9) > 0.5) { signv = 1.0; }
            float radius = 0.10 + 0.06 * ns_hash11(idf * 2.11 + seedF);

            float2 d = uv - c;
            float r2 = dot(d, d);
            float falloff = exp(-r2 / (2.0 * radius * radius));
            float2 tangent = float2(-d.y, d.x);
            vel = vel + tangent * signv * falloff * 12.0;
            dye = dye + falloff;
        }
        return float4(vel, clamp(dye, 0.0, 1.0), 1.0);
    }

    float2 vel = prev.rg;
    float dye = prev.b;

    float dt = clamp(speedU, 0.0, 200.0) * 0.0001;

    float iForce = clamp(inputForceU, 0.0, 100.0) * 0.01;
    float iDye = clamp(inputDyeU, 0.0, 100.0) * 0.01;
    if (iForce > 0.0 || iDye > 0.0)
    {
        float2 texel = float2(1.0, 1.0) / texSize;
        // PARITY (HDR-input guard): the reference nsSplat reads lum(texture(inputTex,uv).rgb)
        // UNCLAMPED, but its input surface is always in [0,1], so clamping is a no-op for the
        // golden. The C# particle pipeline (pointsBillboardRender's additive rgba16f trail) can
        // hand navierStokes an out-of-[0,1] HDR surface; at velocityDecay≈100 (zero dissipation)
        // the unbounded dye injection then saturates to a white-out. Clamp the input read to
        // [0,1] so the force/dye injection is bounded exactly as it is for the reference.
        float lc = ns_lum(clamp(inputTex.SampleLevel(sampler_inputTex, uv, 0.0).rgb, 0.0, 1.0));
        float lr = ns_lum(clamp(inputTex.SampleLevel(sampler_inputTex, uv + float2(texel.x, 0.0), 0.0).rgb, 0.0, 1.0));
        float lu = ns_lum(clamp(inputTex.SampleLevel(sampler_inputTex, uv + float2(0.0, texel.y), 0.0).rgb, 0.0, 1.0));
        float2 grad = float2(lr - lc, lu - lc);
        vel = vel + grad * iForce * 50.0;
        dye = dye + lc * iDye * dt * 60.0;
    }

    dye = clamp(dye, 0.0, 2.0);

    return float4(vel, dye, 1.0);
}

// =============================================================================
// PASS: nsAdvect — semi-Lagrangian advection (frag_nsAdvect)
// =============================================================================
float4 ns_advect_fetchTex(int2 idx, int2 minIdx, int2 maxIdx)
{
    return bufTex.Load(int3(clamp(idx, minIdx, maxIdx), 0));
}

float4 ns_advect_sampleBilinear(float2 uv, int2 texSize)
{
    int2 minIdx = int2(0, 0);
    int2 maxIdx = texSize - int2(1, 1);
    float2 texSizeF = float2(texSize);
    float2 texelPos = uv * texSizeF - float2(0.5, 0.5);
    int2 baseI = int2(floor(texelPos));
    float2 f = frac(texelPos);

    float4 v00 = ns_advect_fetchTex(baseI,                 minIdx, maxIdx);
    float4 v10 = ns_advect_fetchTex(baseI + int2(1, 0),    minIdx, maxIdx);
    float4 v01 = ns_advect_fetchTex(baseI + int2(0, 1),    minIdx, maxIdx);
    float4 v11 = ns_advect_fetchTex(baseI + int2(1, 1),    minIdx, maxIdx);
    float4 v0 = lerp(v00, v10, float4(f.x, f.x, f.x, f.x));
    float4 v1 = lerp(v01, v11, float4(f.x, f.x, f.x, f.x));
    return lerp(v0, v1, float4(f.y, f.y, f.y, f.y));
}

float4 frag_nsAdvect(NMVaryings i) : SV_Target
{
    float speedU = speed;
    float dyeDecayU = dyeDecay;
    float velocityDecayU = velocityDecay;

    uint tw, th;
    bufTex.GetDimensions(tw, th);
    int2 texSize = int2((int)tw, (int)th);
    float2 texSizeF = float2(texSize);
    float2 fragCoord = NM_FragCoord(i);
    float2 uv = fragCoord / texSizeF;

    float4 here = bufTex.Load(int3(clamp(int2(fragCoord), int2(0, 0), texSize - int2(1, 1)), 0));
    float2 u = here.rg;

    float dt = clamp(speedU, 0.0, 200.0) * 0.0001;
    float2 backUv = clamp(uv - u * dt, float2(0.0, 0.0), float2(1.0, 1.0));

    float4 advected = ns_advect_sampleBilinear(backUv, texSize);
    float2 newVel = advected.rg;
    float newDye = advected.b;

    float vDecay = pow(clamp(velocityDecayU, 0.0, 100.0) * 0.01, dt * 60.0);
    float dDecay = pow(clamp(dyeDecayU, 0.0, 100.0) * 0.01, dt * 60.0);

    newVel = newVel * vDecay;
    newDye = newDye * dDecay;

    return float4(newVel, newDye, 1.0);
}

// =============================================================================
// PASS: nsDivergence — velocity divergence (frag_nsDivergence)
// =============================================================================
float2 ns_div_fetchVel(int2 idx, int2 minIdx, int2 maxIdx)
{
    return velTex.Load(int3(clamp(idx, minIdx, maxIdx), 0)).rg;
}

float4 frag_nsDivergence(NMVaryings i) : SV_Target
{
    uint tw, th;
    velTex.GetDimensions(tw, th);
    int2 texSize = int2((int)tw, (int)th);
    float2 texSizeF = float2(texSize);
    int2 minIdx = int2(0, 0);
    int2 maxIdx = texSize - int2(1, 1);
    float2 fragCoord = NM_FragCoord(i);
    int2 centerI = int2(floor(fragCoord));

    float2 uR = ns_div_fetchVel(centerI + int2(1, 0),  minIdx, maxIdx);
    float2 uL = ns_div_fetchVel(centerI + int2(-1, 0), minIdx, maxIdx);
    float2 uT = ns_div_fetchVel(centerI + int2(0, 1),  minIdx, maxIdx);
    float2 uB = ns_div_fetchVel(centerI + int2(0, -1), minIdx, maxIdx);

    if (fragCoord.x < 1.0) { uL.x = -uR.x; }
    if (fragCoord.x > texSizeF.x - 1.0) { uR.x = -uL.x; }
    if (fragCoord.y < 1.0) { uB.y = -uT.y; }
    if (fragCoord.y > texSizeF.y - 1.0) { uT.y = -uB.y; }

    float div = 0.5 * ((uR.x - uL.x) + (uT.y - uB.y));

    return float4(0.0, div, 0.0, 1.0);
}

// =============================================================================
// PASS: nsPressure — Jacobi pressure iteration (frag_nsPressure)
// repeat: "iterations" — runtime ping-pongs global_ns_pressure per iteration.
// =============================================================================
float4 frag_nsPressure(NMVaryings i) : SV_Target
{
    uint tw, th;
    bufTex.GetDimensions(tw, th);
    int2 texSize = int2((int)tw, (int)th);
    int2 minIdx = int2(0, 0);
    int2 maxIdx = texSize - int2(1, 1);
    int2 centerI = int2(floor(NM_FragCoord(i)));

    float pR = bufTex.Load(int3(clamp(centerI + int2(1, 0),  minIdx, maxIdx), 0)).r;
    float pL = bufTex.Load(int3(clamp(centerI + int2(-1, 0), minIdx, maxIdx), 0)).r;
    float pT = bufTex.Load(int3(clamp(centerI + int2(0, 1),  minIdx, maxIdx), 0)).r;
    float pB = bufTex.Load(int3(clamp(centerI + int2(0, -1), minIdx, maxIdx), 0)).r;

    float div = bufTex.Load(int3(clamp(centerI, minIdx, maxIdx), 0)).g;

    float p = (pR + pL + pT + pB - div) * 0.25;

    return float4(p, div, 0.0, 1.0);
}

// =============================================================================
// PASS: nsGradient — gradient subtraction / projection (frag_nsGradient)
// =============================================================================
float4 frag_nsGradient(NMVaryings i) : SV_Target
{
    uint tw, th;
    velTex.GetDimensions(tw, th);
    int2 texSize = int2((int)tw, (int)th);
    int2 minIdx = int2(0, 0);
    int2 maxIdx = texSize - int2(1, 1);
    int2 centerI = int2(floor(NM_FragCoord(i)));

    float pR = pressureTex.Load(int3(clamp(centerI + int2(1, 0),  minIdx, maxIdx), 0)).r;
    float pL = pressureTex.Load(int3(clamp(centerI + int2(-1, 0), minIdx, maxIdx), 0)).r;
    float pT = pressureTex.Load(int3(clamp(centerI + int2(0, 1),  minIdx, maxIdx), 0)).r;
    float pB = pressureTex.Load(int3(clamp(centerI + int2(0, -1), minIdx, maxIdx), 0)).r;

    float2 grad = 0.5 * float2(pR - pL, pT - pB);

    float4 here = velTex.Load(int3(clamp(centerI, minIdx, maxIdx), 0));
    float2 u = here.rg - grad;

    return float4(u, here.b, 1.0);
}

// =============================================================================
// PASS: nsSmooth — kernel upsample from compute canvas → smoothed (frag_nsSmooth)
// =============================================================================
float4 ns_smooth_fetchTex(int2 idx, int2 minIdx, int2 maxIdx)
{
    return canvasTex.Load(int3(clamp(idx, minIdx, maxIdx), 0));
}

float4 ns_smooth_quad3v(float4 p0, float4 p1, float4 p2, float t)
{
    float t2 = t * t;
    return p0 * 0.5 * (1.0 - t) * (1.0 - t) +
           p1 * 0.5 * (-2.0 * t2 + 2.0 * t + 1.0) +
           p2 * 0.5 * t2;
}

float4 ns_smooth_bicubic4v(float4 p0, float4 p1, float4 p2, float4 p3, float t)
{
    float t2 = t * t;
    float t3 = t2 * t;
    float b0 = (1.0 - t) * (1.0 - t) * (1.0 - t) / 6.0;
    float b1 = (3.0 * t3 - 6.0 * t2 + 4.0) / 6.0;
    float b2 = (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) / 6.0;
    float b3 = t3 / 6.0;
    return p0 * b0 + p1 * b1 + p2 * b2 + p3 * b3;
}

float4 ns_smooth_catmull3v(float4 p0, float4 p1, float4 p2, float t)
{
    float t2 = t * t;
    float t3 = t2 * t;
    float4 m = 0.5 * (p2 - p0);
    return (2.0*t3 - 3.0*t2 + 1.0) * p1 +
           (t3 - 2.0*t2 + t) * m +
           (-2.0*t3 + 3.0*t2) * p2 +
           (t3 - t2) * m;
}

float4 ns_smooth_catmull4v(float4 p0, float4 p1, float4 p2, float4 p3, float t)
{
    return p1 + 0.5 * t * (p2 - p0 + t * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 + t * (3.0 * (p1 - p2) + p3 - p0)));
}

float4 frag_nsSmooth(NMVaryings i) : SV_Target
{
    float2 resolutionU = resolution;
    int smoothingI = (int)((float)smoothing);

    uint tw, th;
    canvasTex.GetDimensions(tw, th);
    int2 texSize = int2((int)tw, (int)th);
    float2 texSizeF = float2(texSize);
    int2 minIdx = int2(0, 0);
    int2 maxIdx = texSize - int2(1, 1);

    float2 uv = NM_FragCoord(i) / resolutionU;
    float2 texelPos = uv * texSizeF - float2(0.5, 0.5);
    int2 baseI = int2(floor(texelPos));
    float2 f = frac(texelPos);

    float4 sampled;

    if (smoothingI == 0)
    {
        int2 idx = clamp(int2(floor(texelPos + 0.5)), minIdx, maxIdx);
        sampled = canvasTex.Load(int3(idx, 0));
    }
    else if (smoothingI == 2)
    {
        float4 v00 = ns_smooth_fetchTex(baseI,              minIdx, maxIdx);
        float4 v10 = ns_smooth_fetchTex(baseI + int2(1, 0), minIdx, maxIdx);
        float4 v01 = ns_smooth_fetchTex(baseI + int2(0, 1), minIdx, maxIdx);
        float4 v11 = ns_smooth_fetchTex(baseI + int2(1, 1), minIdx, maxIdx);
        float2 w = smoothstep(float2(0.0, 0.0), float2(1.0, 1.0), f);
        float4 v0 = lerp(v00, v10, float4(w.x, w.x, w.x, w.x));
        float4 v1 = lerp(v01, v11, float4(w.x, w.x, w.x, w.x));
        sampled = lerp(v0, v1, float4(w.y, w.y, w.y, w.y));
    }
    else if (smoothingI == 3)
    {
        float4 p[9];
        for (int j = 0; j < 3; j = j + 1)
        {
            for (int ii = 0; ii < 3; ii = ii + 1)
            {
                p[j * 3 + ii] = ns_smooth_fetchTex(baseI + int2(ii - 1, j - 1), minIdx, maxIdx);
            }
        }
        float4 r0 = ns_smooth_catmull3v(p[0], p[1], p[2], f.x);
        float4 r1 = ns_smooth_catmull3v(p[3], p[4], p[5], f.x);
        float4 r2 = ns_smooth_catmull3v(p[6], p[7], p[8], f.x);
        sampled = ns_smooth_catmull3v(r0, r1, r2, f.y);
    }
    else if (smoothingI == 4)
    {
        float4 p[16];
        for (int j = 0; j < 4; j = j + 1)
        {
            for (int ii = 0; ii < 4; ii = ii + 1)
            {
                p[j * 4 + ii] = ns_smooth_fetchTex(baseI + int2(ii - 1, j - 1), minIdx, maxIdx);
            }
        }
        float4 r0 = ns_smooth_catmull4v(p[0], p[1], p[2], p[3], f.x);
        float4 r1 = ns_smooth_catmull4v(p[4], p[5], p[6], p[7], f.x);
        float4 r2 = ns_smooth_catmull4v(p[8], p[9], p[10], p[11], f.x);
        float4 r3 = ns_smooth_catmull4v(p[12], p[13], p[14], p[15], f.x);
        sampled = ns_smooth_catmull4v(r0, r1, r2, r3, f.y);
    }
    else if (smoothingI == 5)
    {
        float4 p[9];
        for (int j = 0; j < 3; j = j + 1)
        {
            for (int ii = 0; ii < 3; ii = ii + 1)
            {
                p[j * 3 + ii] = ns_smooth_fetchTex(baseI + int2(ii - 1, j - 1), minIdx, maxIdx);
            }
        }
        float4 r0 = ns_smooth_quad3v(p[0], p[1], p[2], f.x);
        float4 r1 = ns_smooth_quad3v(p[3], p[4], p[5], f.x);
        float4 r2 = ns_smooth_quad3v(p[6], p[7], p[8], f.x);
        sampled = ns_smooth_quad3v(r0, r1, r2, f.y);
    }
    else if (smoothingI == 6)
    {
        float4 p[16];
        for (int j = 0; j < 4; j = j + 1)
        {
            for (int ii = 0; ii < 4; ii = ii + 1)
            {
                p[j * 4 + ii] = ns_smooth_fetchTex(baseI + int2(ii - 1, j - 1), minIdx, maxIdx);
            }
        }
        float4 r0 = ns_smooth_bicubic4v(p[0], p[1], p[2], p[3], f.x);
        float4 r1 = ns_smooth_bicubic4v(p[4], p[5], p[6], p[7], f.x);
        float4 r2 = ns_smooth_bicubic4v(p[8], p[9], p[10], p[11], f.x);
        float4 r3 = ns_smooth_bicubic4v(p[12], p[13], p[14], p[15], f.x);
        sampled = ns_smooth_bicubic4v(r0, r1, r2, r3, f.y);
    }
    else
    {
        float4 v00 = ns_smooth_fetchTex(baseI,              minIdx, maxIdx);
        float4 v10 = ns_smooth_fetchTex(baseI + int2(1, 0), minIdx, maxIdx);
        float4 v01 = ns_smooth_fetchTex(baseI + int2(0, 1), minIdx, maxIdx);
        float4 v11 = ns_smooth_fetchTex(baseI + int2(1, 1), minIdx, maxIdx);
        float4 v0 = lerp(v00, v10, float4(f.x, f.x, f.x, f.x));
        float4 v1 = lerp(v01, v11, float4(f.x, f.x, f.x, f.x));
        sampled = lerp(v0, v1, float4(f.y, f.y, f.y, f.y));
    }

    return sampled;
}

// =============================================================================
// PASS: ns — display blit of smoothed canvas, blend with input (frag_ns)
// =============================================================================
float4 frag_ns(NMVaryings i) : SV_Target
{
    float2 resolutionU = resolution;
    float inputIntensityU = inputIntensity;

    uint tw, th;
    fbTex.GetDimensions(tw, th);
    int2 texSize = int2((int)tw, (int)th);
    float2 texSizeF = float2(texSize);
    int2 minIdx = int2(0, 0);
    int2 maxIdx = texSize - int2(1, 1);

    float2 pos = NM_FragCoord(i);
    float2 texelPos = (pos * texSizeF / resolutionU) - float2(0.5, 0.5);
    int2 baseI = int2(floor(texelPos));
    float2 f = frac(texelPos);

    float v00 = fbTex.Load(int3(clamp(baseI,              minIdx, maxIdx), 0)).b;
    float v10 = fbTex.Load(int3(clamp(baseI + int2(1, 0), minIdx, maxIdx), 0)).b;
    float v01 = fbTex.Load(int3(clamp(baseI + int2(0, 1), minIdx, maxIdx), 0)).b;
    float v11 = fbTex.Load(int3(clamp(baseI + int2(1, 1), minIdx, maxIdx), 0)).b;

    float v0 = lerp(v00, v10, f.x);
    float v1 = lerp(v01, v11, f.x);
    float state = lerp(v0, v1, f.y);

    float intensity = clamp(state, 0.0, 1.0);
    float3 outCol = float3(intensity, intensity, intensity);

    float blend = clamp(inputIntensityU, 0.0, 100.0) * 0.01;
    if (blend > 0.0)
    {
        // PARITY (HDR-input guard): same rationale as nsSplat — bound an out-of-[0,1]
        // particle-field input so the display blend cannot leak HDR into the output.
        float3 inputColor = clamp(inputTex.SampleLevel(sampler_inputTex, pos / resolutionU, 0.0).rgb, 0.0, 1.0);
        outCol = lerp(outCol, inputColor, float3(blend, blend, blend));
    }

    return float4(outCol, 1.0);
}

#endif // NM_EFFECT_NAVIERSTOKES_INCLUDED
