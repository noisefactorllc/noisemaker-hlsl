#ifndef NM_EFFECT_LENIA_INCLUDED
#define NM_EFFECT_LENIA_INCLUDED

// =============================================================================
// Lenia.hlsl — points/lenia (func: "lenia")
//
// Particle Lenia artificial-life simulation. Ported PIXEL-IDENTICALLY from the
// canonical WGSL sources (top-left origin, no per-effect Y flip):
//   wgsl/clear.wgsl        progName "clear"       (frag_clear)        fullscreen
//   wgsl/deposit.wgsl      progName "deposit"     (vert_deposit /     DEPOSIT
//                                                  frag_deposit)      drawMode:points
//   wgsl/convolve.wgsl     progName "convolve"    (frag_convolve)     fullscreen
//   wgsl/agentField.wgsl   progName "agentField"  (frag_agentField)   fullscreen, MRT x3
//   wgsl/passthrough.wgsl  progName "passthrough" (frag_passthrough)  fullscreen
//
// AGENT / MULTI-PASS / MRT / POINTS-SCATTER / FEEDBACK. 5 passes per frame:
//   1 clear      (fullscreen)  : zero the density accumulation texture.
//   2 deposit    (DEPOSIT)     : drawMode:"points", one point per agent texel;
//                                additive Blend One One scatter into density.
//   3 convolve   (fullscreen)  : gaussian-shell kernel K(r) convolution -> field.
//   4 agentField (fullscreen)  : MRT x3 — update agent state from sampled field,
//                                writes outXYZ(SV_Target0)/outVel(1)/outRGBA(2).
//   5 passthrough(fullscreen)  : copy inputTex -> outputTex (2D chain continuity).
//
// PERSISTENT 'global_' agent state (rgba32f, double-buffered, isStateSurface):
//   global_xyz  : [x, y, z, alive]          x,y normalized [0,1]
//   global_vel  : [vx, vy, age, seed]
//   global_rgba : [r, g, b, a]              agent color
// These survive frame-to-frame (the runtime persists them via isStateSurface;
// names end in _xyz/_vel/_rgba). The agentField pass reads all three + the
// field and rewrites all three via MRT (in-place feedback). Transient private
// state (rgba16f, 50% resolution, recomputed each frame):
//   global_lenia_density : r=accumulated deposit (cleared, scattered, read).
//   global_lenia_field   : r=convolved U field.
//
// NOTE: agent / multi-pass / MRT / points-scatter effect → ships as a runtime-
// rendered Texture2D. NO Shader Graph Custom Function wrapper is provided (a
// Custom Function node is a single fullscreen fragment; it cannot express the
// 5-pass chain, the points-scatter deposit vertex, the MRT state writes, or the
// persistent feedback textures). The C# runtime drives the 5 passes in order,
// rebinding global_xyz/global_vel/global_rgba/global_lenia_density/
// global_lenia_field read/write targets per pass.
//
// PORTING-GUIDE / parity notes:
//  * WGSL textureLoad(t, coord, 0) → t.Load(int3(coord, 0)) (integer texel
//    fetch, point, no filtering). Agent state (rgba32f) and density are read
//    this way. The DEPOSIT vertex Loads xyz in the VERTEX stage (SM4.5 allows
//    vertex-stage Texture2D.Load).
//  * WGSL textureSampleLevel(t, s, uv, 0.0) → t.SampleLevel(sampler_t, uv, 0.0)
//    (mip 0, explicit). WGSL textureSample(t, s, uv) (implicit-LOD) is only legal
//    in a fragment stage; agentField uses it in uniform control flow (all fetches
//    precede the dead-particle early-out). In HLSL we use .Sample(...) likewise.
//    All field/density samples are bilinear, NON-sRGB. The WGSL convolve uses a
//    REPEAT-wrapped sample (fract(...) of the uv before sampling) — sampler wrap
//    mode is irrelevant because the coord is pre-wrapped with frac(); clamp is
//    fine. Same for agentField's gradient taps (fract(uv ± texel)).
//  * fragCoord = pos.xy (@builtin(position), top-left, +0.5 centered) →
//    NM_FragCoord(i). convolve/agentField derive coord/uv from the BOUND
//    texture's OWN dimensions (density / field), reproduced exactly. passthrough
//    derives coord from inputTex's dimensions.
//  * fract→frac, exp→exp, length→length, min→min. modulo is NEVER used here.
//  * vec2i(fragCoord.xy) → int2(fragCoord) (truncation toward zero; fragCoord is
//    non-negative). i32(ceil(searchRadius)) → (int)ceil(searchRadius).
//  * NO helpers come from NMCore (none of pcg/prng/random/nm_mod/etc. are used).
//    growth/growthDerivative/kernel are ported verbatim, inline.
//  * DEPOSIT vertex hazard: the WGSL deposit (deposit.wgsl) emits 1px points and
//    GLSL deposit.vert sets gl_PointSize=2.0; D3D/Unity Points topology is fixed
//    1px (no point size). We follow the WGSL (1px) per PORTING-GUIDE golden rule
//    #1 (port from WGSL). Off-screen culling uses clip (2,2,0,1) like the WGSL
//    (NDC >1 → fully clipped), NOT the GLSL (-999) sentinel. // TODO(verify):
//    the GLSL 2px deposit vs WGSL 1px deposit changes trail thickness; reference
//    golden is the WGSL path, so 1px is correct for parity.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Distinct input textures across all passes ------------------------------
// deposit:    xyzTex (Load in VS)
// convolve:   densityTex (Sample)
// agentField: xyzTex/velTex/rgbaTex (Load), fieldTex (Sample)
// passthrough:inputTex (Load)
// The runtime rebinds these per pass per definition.js inputs{}.
Texture2D    xyzTex;       SamplerState sampler_xyzTex;
Texture2D    velTex;       SamplerState sampler_velTex;
Texture2D    rgbaTex;      SamplerState sampler_rgbaTex;
Texture2D    fieldTex;     SamplerState sampler_fieldTex;
Texture2D    densityTex;   SamplerState sampler_densityTex;
Texture2D    inputTex;     SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
// deposit:    depositAmount
// convolve:   muK, sigmaK, searchRadius
// agentField: muG, sigmaG, repulsion, dt
// resolution is the engine global (NMFullscreen alias).
float muK;            // globals.muK           default 25.0
float sigmaK;         // globals.sigmaK        default 5.0
float muG;            // globals.muG           default 0.25
float sigmaG;         // globals.sigmaG        default 0.15
float repulsion;      // globals.repulsion     default 0.5
float dt;             // globals.dt            default 0.25
float searchRadius;   // globals.searchRadius  default 25.0
float depositAmount;  // globals.depositAmount default 3.6

static const float EPSILON = 0.0001;
static const float PI = 3.14159265359;

// =============================================================================
// PASS: clear — zero the density accumulation texture (frag_clear)
// =============================================================================
float4 frag_clear(NMVaryings i) : SV_Target
{
    return float4(0.0, 0.0, 0.0, 0.0);
}

// =============================================================================
// PASS: deposit — points-scatter agents into density (vert_deposit/frag_deposit)
// drawMode:"points"; one point per agent texel; additive Blend One One.
// =============================================================================
struct DepositVaryings
{
    float4 positionCS : SV_POSITION;
    float  pointSize  : PSIZE;       // D3D points topology requires a PSIZE output;
                                     // reference deposit.vert sets gl_PointSize = 1.0
                                     // (v1.0.79 a27bf823, was 2.0).
    float  amount     : TEXCOORD0;
};

DepositVaryings vert_deposit(uint vertexIndex : SV_VertexID)
{
    DepositVaryings o;
    o.pointSize = 1.0;   // reference gl_PointSize = 1.0 (v1.0.79 a27bf823, was 2.0).

    // Get state size from xyz texture dimensions (matches WGSL textureDimensions).
    uint tw, th;
    xyzTex.GetDimensions(tw, th);
    int stateSize = (int)tw;
    int totalAgents = stateSize * stateSize;

    // Cull vertices beyond texture size (WGSL: clip (2,2,0,1) -> fully clipped).
    if ((int)vertexIndex >= totalAgents)
    {
        o.positionCS = float4(2.0, 2.0, 0.0, 1.0);
        o.amount = 0.0;
        return o;
    }

    // Calculate texel for this agent.
    int x = (int)vertexIndex % stateSize;
    int y = (int)vertexIndex / stateSize;

    // Read agent position (vertex-stage integer texel fetch, point, no filter).
    float4 pos = xyzTex.Load(int3(x, y, 0));

    // Cull dead agents (WGSL: clip (2,2,0,1)).
    if (pos.w < 0.5)
    {
        o.positionCS = float4(2.0, 2.0, 0.0, 1.0);
        o.amount = 0.0;
        return o;
    }

    // Convert position (0..1) to clip space (-1..1).
    float2 clipPos = pos.xy * 2.0 - 1.0;

    // Y-orientation parity (CRITICAL): the convolve/agentField passes read the
    // density field via NM_FragCoord-derived UV (NMVertFullscreen counter-flips
    // clip.y by _ProjectionParams.x). This custom deposit VS MUST apply the SAME
    // counter-flip so the deposited density lands where the field passes read it;
    // otherwise the lenia field is vertically mirrored vs the simulation that
    // consumes it (corrupting the dynamics + the final trail).
    o.positionCS = float4(clipPos.x, clipPos.y * _ProjectionParams.x, 0.0, 1.0);
    o.amount = depositAmount;
    return o;
}

float4 frag_deposit(DepositVaryings i) : SV_Target
{
    // Each particle deposits a constant value (kernel convolution spreads it).
    return float4(i.amount, 0.0, 0.0, 1.0);
}

// =============================================================================
// PASS: convolve — gaussian-shell kernel K(r) convolution -> U field (frag_convolve)
// =============================================================================
// Gaussian shell kernel K(r) = exp(-((r - mu) / sigma)^2)
float lenia_kernel(float r, float mu, float sigma)
{
    float x = (r - mu) / sigma;
    return exp(-x * x);
}

float4 frag_convolve(NMVaryings i) : SV_Target
{
    float muKU = muK;
    float sigmaKU = sigmaK;
    float searchRadiusU = searchRadius;

    // Use the actual density texture size, not output resolution.
    uint dw, dh;
    densityTex.GetDimensions(dw, dh);
    float2 densitySize = float2((float)dw, (float)dh);
    float2 fragCoord = NM_FragCoord(i);
    float2 uv = fragCoord / densitySize;
    float2 texelSize = float2(1.0, 1.0) / densitySize;

    // Compute kernel weight for normalization.
    float wK = 0.0;
    int numSamples = 64;
    float dr = searchRadiusU / (float)numSamples;
    for (int si = 0; si < numSamples; si = si + 1)
    {
        float r = ((float)si + 0.5) * dr;
        wK += lenia_kernel(r, muKU, sigmaKU) * r * dr;
    }
    wK = 1.0 / max(wK * 2.0 * PI, EPSILON);

    // Accumulate kernel-weighted density from neighbors.
    float U = 0.0;
    int iRadius = (int)ceil(searchRadiusU);

    for (int dy = -iRadius; dy <= iRadius; dy = dy + 1)
    {
        for (int dx = -iRadius; dx <= iRadius; dx = dx + 1)
        {
            float r = length(float2((float)dx, (float)dy));

            // Skip if outside search radius.
            if (r > searchRadiusU)
            {
                continue;
            }

            // Sample density at neighbor (wrap around edges via pre-wrapped frac).
            float2 sampleUV = frac(uv + float2((float)dx, (float)dy) * texelSize);
            float density = densityTex.SampleLevel(sampler_densityTex, sampleUV, 0.0).r;

            // Apply kernel weight.
            float kVal = lenia_kernel(r, muKU, sigmaKU) * wK;
            U += density * kVal;
        }
    }

    return float4(U, 0.0, 0.0, 1.0);
}

// =============================================================================
// PASS: agentField — update agent state from sampled U field (frag_agentField)
// MRT x3: SV_Target0=outXYZ, SV_Target1=outVel, SV_Target2=outRGBA.
// =============================================================================
struct AgentFieldOutput
{
    float4 outXYZ  : SV_Target0;
    float4 outVel  : SV_Target1;
    float4 outRGBA : SV_Target2;
};

// Growth function G(u) = exp(-((u - mu) / sigma)^2)
float lenia_growth(float u, float mu, float sigma)
{
    float x = (u - mu) / sigma;
    return exp(-x * x);
}

// Derivative of growth: dG/du = G(u) * (-2(u-mu)/sigma^2)
float lenia_growthDerivative(float u, float mu, float sigma)
{
    float G = lenia_growth(u, mu, sigma);
    return G * (-2.0 * (u - mu)) / (sigma * sigma);
}

AgentFieldOutput frag_agentField(NMVaryings i)
{
    AgentFieldOutput o;

    // Reference uses the GLOBAL canvas resolution uniform ([width,height], set by
    // pipeline.js updateGlobalUniforms — NOT re-derived per render target). The
    // agentField pass renders OVER the stateSize x stateSize agent state texture,
    // so _NM_Resolution (current target size) would be the state size here, NOT the
    // canvas size. _NM_FullResolution carries the untiled canvas size independent of
    // the bound target, matching the reference's globalUniforms.resolution. // TODO(verify)
    float2 resolutionU = fullResolution;
    float muGU = muG;
    float sigmaGU = sigmaG;
    float repulsionU = repulsion;
    float dtU = dt;

    int2 coord = int2(NM_FragCoord(i));

    // Read current particle state (integer texel fetch, point, no filter).
    float4 xyz = xyzTex.Load(int3(coord, 0));
    float4 vel = velTex.Load(int3(coord, 0));
    float4 rgba = rgbaTex.Load(int3(coord, 0));

    // Sample U field at particle position — MUST be in uniform control flow.
    // Do all texture samples before any early returns.
    float2 uv = xyz.xy;
    // Use the field texture's actual size for correct texel stepping.
    uint fw, fh;
    fieldTex.GetDimensions(fw, fh);
    float2 texelSize = float2(1.0, 1.0) / float2((float)fw, (float)fh);
    float U = fieldTex.SampleLevel(sampler_fieldTex, uv, 0.0).r;
    float Ux_plus  = fieldTex.Sample(sampler_fieldTex, frac(uv + float2(texelSize.x, 0.0))).r;
    float Ux_minus = fieldTex.Sample(sampler_fieldTex, frac(uv - float2(texelSize.x, 0.0))).r;
    float Uy_plus  = fieldTex.Sample(sampler_fieldTex, frac(uv + float2(0.0, texelSize.y))).r;
    float Uy_minus = fieldTex.Sample(sampler_fieldTex, frac(uv - float2(0.0, texelSize.y))).r;

    float alive = xyz.w;

    // Pass through dead particles.
    if (alive < 0.5)
    {
        o.outXYZ = xyz;
        o.outVel = vel;
        o.outRGBA = rgba;
        return o;
    }

    // Compute gradient of U via finite differences.
    float2 gradU = float2(
        (Ux_plus - Ux_minus) / (2.0 * texelSize.x),
        (Uy_plus - Uy_minus) / (2.0 * texelSize.y)
    );

    // Scale gradient to world space.
    float worldScale = min(resolutionU.x, resolutionU.y) * 0.05;
    gradU /= worldScale;

    // Compute growth gradient: gradG = dG/dU * gradU
    float dGdU = lenia_growthDerivative(U, muGU, sigmaGU);
    float2 gradG = dGdU * gradU;

    // Repulsion gradient (approximated from U field).
    float2 gradR = repulsionU * gradU;

    // Total force: dp/dt = gradG - gradR
    float2 force = gradG - gradR;

    // Limit force magnitude for stability.
    float forceMag = length(force);
    if (forceMag > 10.0)
    {
        force = force / forceMag * 10.0;
    }

    // Update position (Euler integration).
    float2 newPos = uv + force * dtU * 0.01;

    // Wrap to [0,1] bounds (toroidal topology).
    newPos = frac(newPos + 1.0);

    // Store velocity for visualization.
    float2 velocity = force * dtU * 0.01;

    // Update age.
    float age = vel.z + 0.016;

    // Output.
    o.outXYZ = float4(newPos, xyz.z, 1.0);
    o.outVel = float4(velocity, age, vel.w);
    o.outRGBA = rgba;

    return o;
}

// =============================================================================
// PASS: passthrough — copy inputTex -> outputTex (frag_passthrough)
// =============================================================================
float4 frag_passthrough(NMVaryings i) : SV_Target
{
    int2 coord = int2(NM_FragCoord(i));
    return inputTex.Load(int3(coord, 0));
}

#endif // NM_EFFECT_LENIA_INCLUDED
