#ifndef NM_EFFECT_ATTRACTOR_INCLUDED
#define NM_EFFECT_ATTRACTOR_INCLUDED

// =============================================================================
// Attractor.hlsl — points/attractor (func: "attractor")
//
// Strange-attractor agent middleware. Ported PIXEL-IDENTICALLY from the
// canonical WGSL sources (top-left origin, no per-effect Y flip):
//   wgsl/agent.wgsl        progName "agent"        (frag_agent, MRT)
//   wgsl/passthrough.wgsl  progName "passthrough"  (frag_passthrough)
//
// MULTI-PASS / AGENT / FEEDBACK: 2 passes per frame in definition order:
//   1. "agent"       — FULLSCREEN over the state texture (one texel per agent),
//                      MRT: writes 3 PERSISTENT state textures in ONE pass via
//                      SV_Target0/1/2 (outXYZ -> global_xyz, outVel ->
//                      global_vel, outRGBA -> global_rgba). drawBuffers:3.
//                      The runtime ping-pongs each global per write/frame
//                      (reference 04 §10.2/§10.7; isStateSurface matches the
//                      xyz/vel/rgba suffixes so these PERSIST, not swap).
//   2. "passthrough" — FULLSCREEN copy of inputTex -> outputTex (2D chain
//                      continuity; the 2D image is untouched by the agent sim).
//
// IMPORTANT — NO DEPOSIT / NO POINTS-SCATTER PASS IN THIS EFFECT. The agent
// pass is a fullscreen MRT state update, NOT a drawMode:"points" scatter. The
// actual points-scatter / 1px deposit happens DOWNSTREAM in the separate
// pointsRender effect (this effect only advances agent state). Therefore this
// port has NO custom deposit vertex stage; both passes use NMVertFullscreen.
//
// State textures are the SHARED global_xyz/global_vel/global_rgba surfaces
// allocated by pointsEmit upstream (this effect declares textures:{}). They are
// rgba32f (full float) — required to hold raw attractor-space positions far
// outside [0,1]. Layout (matches pointsEmit):
//   xyz : [x, y, z, alive_flag]   vel : [vx, vy, vz, seed]   rgba : [r,g,b,a]
//
// NOTE: multi-pass / agent effect → ships as a runtime-rendered Texture2D. No
// Shader Graph Custom Function wrapper is provided (the C# runtime drives the
// 2 passes in order, rebinding the global_xyz/vel/rgba read/write targets).
//
// PORTING-GUIDE / parity notes:
//  * WGSL textureLoad(t, coord, 0) -> t.Load(int3(coord, 0)) (integer texel
//    fetch, point, no filtering). State is read this way in the agent pass.
//  * WGSL textureSample(t, s, uv) -> t.Sample(sampler_t, uv) (linear, clamp,
//    non-sRGB). Used only by passthrough.
//  * fragCoord = @builtin(position).xy (top-left, +0.5 centered) ->
//    NM_FragCoord(i). coord = vec2<i32>(fragCoord.xy) -> int2(fragCoord).
//  * stateSize derived from the BOUND state texture's own dimensions
//    (textureDimensions(xyzTex).x), exactly as the WGSL does. The stateSize
//    uniform exists for sizing only; the shader reads the texture size.
//  * u32(coord.x + coord.y*stateSize) + u32(u.seed): two's-complement reinterpret
//    cast -> (uint)(intExpr). u32(u.time*1000.0): numeric truncation -> (uint).
//  * Integer PCG-style hash (hash_uint) inlined VERBATIM; divisor 4294967295.0.
//    This effect uses its OWN hash, NOT NMCore pcg/prng/random.
//  * NaN test newPos.x != newPos.x reproduced literally (any(isnan) in GLSL).
//  * passthrough GLSL uses gl_FragCoord/resolution; WGSL uses interpolated uv.
//    We port the WGSL: uv == i.uv (== NM_FragCoord/resolution), pixel-identical.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input samplers (runtime rebinds per pass per definition.js inputs{}) ----
// agent:       xyzTex (Load), velTex (Load), rgbaTex (Load)  -- state textures
// passthrough: inputTex (Sample)
Texture2D    xyzTex;     SamplerState sampler_xyzTex;
Texture2D    velTex;     SamplerState sampler_velTex;
Texture2D    rgbaTex;    SamplerState sampler_rgbaTex;
Texture2D    inputTex;   SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
// stateSize is sizing-only (UI control:false, inherited from pointsEmit).
// viewMode is forwarded to downstream pointsRender; unused by these shaders.
// seed/time/resolution are engine globals (time/resolution via NMFullscreen
// aliases; seed has no engine alias so it is a bare uniform here).
int   attractor;   // globals.attractor default 0 (0..6)
float speed;       // globals.speed     default 1.0
int   stateSize;   // globals.stateSize default 256 (sizing-only; unused in body)
int   viewMode;    // globals.viewMode  default 1   (forwarded; unused in body)
int   seed;        // engine/inherited integer seed (u.seed in WGSL)

// =============================================================================
// Shared agent helpers (inlined VERBATIM from wgsl/agent.wgsl)
// =============================================================================

// Integer-based hash for cross-platform determinism (this effect's OWN hash).
uint attractor_hash_uint(uint seedU)
{
    uint state = seedU * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float attractor_hash(uint seedU)
{
    return (float)attractor_hash_uint(seedU) / 4294967295.0;
}

// Lorenz attractor (classic butterfly)
float3 attractor_lorenz(float3 p)
{
    float sigma = 10.0;
    float rho = 28.0;
    float beta = 8.0 / 3.0;
    return float3(
        sigma * (p.y - p.x),
        p.x * (rho - p.z) - p.y,
        p.x * p.y - beta * p.z
    );
}

// Rossler attractor (spiral)
float3 attractor_rossler(float3 p)
{
    float a = 0.2;
    float b = 0.2;
    float c = 5.7;
    return float3(
        -p.y - p.z,
        p.x + a * p.y,
        b + p.z * (p.x - c)
    );
}

// Aizawa attractor (torus-like)
float3 attractor_aizawa(float3 p)
{
    float a = 0.95;
    float b = 0.7;
    float c = 0.6;
    float d = 3.5;
    float e = 0.25;
    float f = 0.1;
    return float3(
        (p.z - b) * p.x - d * p.y,
        d * p.x + (p.z - b) * p.y,
        c + a * p.z - (p.z * p.z * p.z) / 3.0 - (p.x * p.x + p.y * p.y) * (1.0 + e * p.z) + f * p.z * p.x * p.x * p.x
    );
}

// Thomas attractor (cyclically symmetric)
float3 attractor_thomas(float3 p)
{
    float b = 0.208186;
    return float3(
        sin(p.y) - b * p.x,
        sin(p.z) - b * p.y,
        sin(p.x) - b * p.z
    );
}

// Halvorsen attractor (3-fold symmetric)
float3 attractor_halvorsen(float3 p)
{
    float a = 1.89;
    return float3(
        -a * p.x - 4.0 * p.y - 4.0 * p.z - p.y * p.y,
        -a * p.y - 4.0 * p.z - 4.0 * p.x - p.z * p.z,
        -a * p.z - 4.0 * p.x - 4.0 * p.y - p.x * p.x
    );
}

// Chen attractor (double scroll)
float3 attractor_chen(float3 p)
{
    float a = 40.0;
    float b = 3.0;
    float c = 28.0;
    return float3(
        a * (p.y - p.x),
        (c - a) * p.x - p.x * p.z + c * p.y,
        p.x * p.y - b * p.z
    );
}

// Dadras attractor (4-wing)
float3 attractor_dadras(float3 p)
{
    float a = 3.0;
    float b = 2.7;
    float c = 1.7;
    float d = 2.0;
    float e = 9.0;
    return float3(
        p.y - a * p.x + b * p.y * p.z,
        c * p.y - p.x * p.z + p.z,
        d * p.x * p.y - e * p.z
    );
}

float3 attractor_stepAttractor(float3 p, int attractorType, float dt)
{
    float3 dp;
    if (attractorType == 0) { dp = attractor_lorenz(p); }
    else if (attractorType == 1) { dp = attractor_rossler(p); }
    else if (attractorType == 2) { dp = attractor_aizawa(p); }
    else if (attractorType == 3) { dp = attractor_thomas(p); }
    else if (attractorType == 4) { dp = attractor_halvorsen(p); }
    else if (attractorType == 5) { dp = attractor_chen(p); }
    else { dp = attractor_dadras(p); }

    return p + dp * dt;
}

// =============================================================================
// PASS: agent — strange-attractor state update (frag_agent). MRT, drawBuffers:3.
// SV_Target0 = outXYZ (global_xyz), SV_Target1 = outVel (global_vel),
// SV_Target2 = outRGBA (global_rgba). Attachment slot order MUST match the
// definition.js outputs{} insertion order (outXYZ, outVel, outRGBA).
// =============================================================================
struct AttractorAgentOut
{
    float4 outXYZ  : SV_Target0;
    float4 outVel  : SV_Target1;
    float4 outRGBA : SV_Target2;
};

AttractorAgentOut frag_agent(NMVaryings i)
{
    AttractorAgentOut o;

    float2 fragCoord = NM_FragCoord(i);
    int2 coord = int2(fragCoord);

    uint tw, th;
    xyzTex.GetDimensions(tw, th);
    int stateSizeI = (int)tw;

    // Read current state (integer texel fetch, point).
    float4 pos = xyzTex.Load(int3(coord, 0));
    float4 vel = velTex.Load(int3(coord, 0));
    float4 col = rgbaTex.Load(int3(coord, 0));

    uint agentSeed = (uint)(coord.x + coord.y * stateSizeI) + (uint)seed;

    // Check if needs 3D initialization (pointsEmit emits 2D normalized coords).
    bool needs3DInit = pos.w >= 0.5 && pos.z == 0.0 && pos.x >= 0.0 && pos.x <= 1.0 && pos.y >= 0.0 && pos.y <= 1.0;

    if (needs3DInit)
    {
        uint initSeed = agentSeed + (uint)(time * 1000.0);
        float newX = (attractor_hash(initSeed) - 0.5) * 20.0;
        float newY = (attractor_hash(initSeed + 1u) - 0.5) * 20.0;
        float newZ = attractor_hash(initSeed + 2u) * 30.0 + 10.0;

        o.outXYZ  = float4(newX, newY, newZ, 1.0);
        o.outVel  = vel;
        o.outRGBA = col;
        return o;
    }

    // Skip dead agents.
    if (pos.w < 0.5)
    {
        o.outXYZ  = pos;
        o.outVel  = vel;
        o.outRGBA = col;
        return o;
    }

    // Step the attractor.
    float dt = speed * 0.01;
    float3 newPos = attractor_stepAttractor(pos.xyz, attractor, dt);

    // Check for divergence (NaN via self-compare, or too far).
    bool hasNaN = newPos.x != newPos.x || newPos.y != newPos.y || newPos.z != newPos.z;
    if (hasNaN || length(newPos) > 1000.0)
    {
        uint respawnSeed = agentSeed + (uint)(time * 1000.0);
        newPos = float3(
            (attractor_hash(respawnSeed) - 0.5) * 20.0,
            (attractor_hash(respawnSeed + 1u) - 0.5) * 20.0,
            attractor_hash(respawnSeed + 2u) * 30.0 + 10.0
        );
    }

    o.outXYZ  = float4(newPos, 1.0);
    o.outVel  = vel;
    o.outRGBA = col;
    return o;
}

// =============================================================================
// PASS: passthrough — copy inputTex -> outputTex (2D chain continuity).
// Ported from wgsl/passthrough.wgsl: textureSample(inputTex, sampler, uv).
// =============================================================================
float4 frag_passthrough(NMVaryings i) : SV_Target
{
    return inputTex.Sample(sampler_inputTex, i.uv);
}

#endif // NM_EFFECT_ATTRACTOR_INCLUDED
