#ifndef NM_EFFECT_PHYSICAL_INCLUDED
#define NM_EFFECT_PHYSICAL_INCLUDED

// =============================================================================
// Physical.hlsl — points/physical (func: "physical")
//
// Physics-based particle simulation (gravity, wind, drag, wander). Ported
// PIXEL-IDENTICALLY from the canonical WGSL sources (top-left origin, no
// per-effect Y flip):
//   wgsl/agent.wgsl        progName "agent"        (MRT: frag_agent)
//   wgsl/passthrough.wgsl  progName "passthrough"  (frag_passthrough)
//
// MULTI-PASS / AGENT MIDDLEWARE: this effect is COMMON-AGENT-ARCHITECTURE
// middleware in a particle pipeline (pointsEmit -> physical -> pointsRender).
// It does NOT itself create, deposit, or scatter agents — there is NO
// drawMode "points" deposit pass, NO diffuse pass, NO trail texture in this
// effect. The deposit (points scatter, additive Blend One One), trail and
// diffuse passes live in the *pointsRender* effect; agent allocation +
// respawn live in *pointsEmit*. Physical only UPDATES persistent agent state.
// (So although this is the AGENT/POINTS tier, the scatter-vertex guidance does
// not apply here — physical contains no points-draw pass. See pointsRender for
// the deposit.vert/.frag scatter vertex.)
//
//   PASS 1 "agent" (fullscreen-over-state, MRT 3 outputs, drawBuffers:3):
//     Renders fullscreen across the agent STATE texture (one fragment per
//     agent texel). Reads previous state from the persistent 'global_'-prefixed
//     state textures, integrates one physics step, and writes the three updated
//     state textures via MRT. The runtime ping-pongs each global state surface
//     (reference 04 §10.7 isStateSurface: names end with _xyz / _vel / _rgba =>
//     persist, NO end-of-frame swap; the particle sim continues from the last
//     frame's buffers; within-frame writes ping-pong, §10.2).
//   PASS 2 "passthrough" (fullscreen):
//     Copies inputTex -> outputTex for 2D-chain continuity. Pure blit by uv.
//
// STATE TEXTURES (all rgba32f, full float, persistent, shared across the
// particle pipeline that created them — keys global_xyz/global_vel/global_rgba):
//   global_xyz : [x, y, z, alive]    positions normalized [0,1]; w=1 alive/0 dead
//   global_vel : [vx, vy, vz, seed]  z velocity; w = per-agent seed [0,1]
//   global_rgba: [r, g, b, a]        agent color (passed through)
//
// NOTE: multi-pass / agent-middleware effect -> ships as a runtime-rendered
// Texture2D. NO Shader Graph Custom Function wrapper is provided (the C#
// runtime drives the 2 passes in order, rebinding the global_xyz/vel/rgba
// read/write state targets per frame; it cannot be a single-node generator).
//
// PORTING-GUIDE / parity notes:
//  * WGSL textureLoad(t, coord, 0) -> t.Load(int3(coord, 0)) (integer texel
//    fetch, point, no filtering). The agent pass reads rgba32f state this way.
//  * The agent texel coord in WGSL is vec2i(fragCoord.xy) where fragCoord is
//    the rasterizer position OVER THE STATE TEXTURE (viewport == stateSize).
//    Per the house convention for points-agent effects (see Flow.hlsl /
//    Flock.hlsl), the runtime sets _NM_Resolution == the bound STATE texture
//    size for the agent pass, so coord = (int2)NM_FragCoord(i) ==
//    vec2i(fragCoord.xy) exactly. We use that here for consistency.
//    NOTE: physical's agent body does NOT read `resolution` at all (the WGSL
//    Uniforms struct declares it but the body only uses `u.time` and the
//    physics scalars), so the stride-resolution hazard that affects Flow does
//    NOT apply here — coord derivation is the only use and it matches.
//  * PRNG: this effect ships its OWN hash (PCG-style hash_uint + hash), which
//    differs from NMCore's pcg/prng/random -- per PORTING-GUIDE rule 2 we
//    inline THIS effect's version, not the shared one. hash divisor is
//    4294967295.0 (= float(0xffffffffu)).
//  * u32(i.x)/u32(i.y) in noise2D are NUMERIC truncations of floor()ed coords
//    (NOT asuint bit reinterprets) -> (uint)i.x. The agent positions px,py are
//    in [0,1] and the noise sample point = vec2(px,py)*2 + time*0.5 (time is
//    normalized >= 0), so the floored coords are non-negative and the cast is
//    well defined; we mirror the WGSL cast site exactly.
//  * fract -> frac, mix -> lerp, floor -> floor. No nm_mod / fmod used.
//  * 6.283185 literal reproduced verbatim (NOT 2*PI) to match the WGSL.
//  * Early-out for dead agents (alive < 0.5) returns state unchanged via MRT.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input textures across both passes --------------------------------------
// agent:       xyzTex, velTex, rgbaTex (Load by integer texel)
// passthrough: inputTex (Sample)
// The runtime rebinds these per pass per definition.js inputs{}.
Texture2D    inputTex;   SamplerState sampler_inputTex;
Texture2D    xyzTex;     SamplerState sampler_xyzTex;
Texture2D    velTex;     SamplerState sampler_velTex;
Texture2D    rgbaTex;    SamplerState sampler_rgbaTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
// agent uses: gravity, wind, energy, drag, deviation, wander, plus engine
// global `time`. (stateSize is a sizing-only global with ui.control:false; the
// shader derives state dims from the bound state texture, NOT from a uniform --
// exactly like the WGSL textureDimensions(xyzTex). So no stateSize uniform is
// read by the shader body.)
float gravity;     // globals.gravity    default 0.05
float wind;        // globals.wind       default 0
float energy;      // globals.energy     default 0.5
float drag;        // globals.drag       default 0.15
float deviation;   // globals.deviation  default 0.75
float wander;      // globals.wander     default 0.25

// =============================================================================
// PASS: agent — physics integration (MRT: outXYZ / outVel / outRGBA)
// MRT output struct: location 0 = xyz, 1 = vel, 2 = rgba (matches drawBuffers:3
// and definition.js outputs{ outXYZ:color, outVel:color1, outRGBA:color2 }).
// =============================================================================
struct PhysicalAgentOutputs
{
    float4 xyz  : SV_Target0;
    float4 vel  : SV_Target1;
    float4 rgba : SV_Target2;
};

// Effect-local PRNG (verbatim from agent.wgsl -- do NOT substitute NMCore pcg).
uint physical_hash_uint(uint seed)
{
    uint state = seed * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float physical_hash(uint seed)
{
    return (float)physical_hash_uint(seed) / 4294967295.0;
}

// Smooth value noise for wander perturbation (verbatim from agent.wgsl).
float physical_noise2D(float2 p)
{
    float2 i = floor(p);
    float2 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);   // Smoothstep

    uint n = (uint)i.x + (uint)i.y * 57u;
    float a = physical_hash(n);
    float b = physical_hash(n + 1u);
    float c = physical_hash(n + 57u);
    float d = physical_hash(n + 58u);

    return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}

// Fractal noise for smoother motion (verbatim from agent.wgsl).
float physical_fbm(float2 p_in)
{
    float v = 0.0;
    float a = 0.5;
    float2 p = p_in;
    for (int idx = 0; idx < 3; idx++)
    {
        v += a * physical_noise2D(p);
        p *= 2.0;
        a *= 0.5;
    }
    return v;
}

PhysicalAgentOutputs frag_agent(NMVaryings i)
{
    // Agent texel = vec2i(fragCoord.xy). House convention (Flock/Flow): the
    // agent pass renders over the state texture, so NM_FragCoord(i) == texel.
    int2 coord = (int2)NM_FragCoord(i);
    // State texture dimensions (== stateSize x stateSize). Clamp for safety.
    uint sw, sh;
    xyzTex.GetDimensions(sw, sh);
    int2 stateSize = int2((int)sw, (int)sh);
    coord = clamp(coord, int2(0, 0), stateSize - int2(1, 1));

    // Read input state from the pipeline (rgba32f, point fetch).
    float4 xyz  = xyzTex.Load(int3(coord, 0));
    float4 vel  = velTex.Load(int3(coord, 0));
    float4 rgba = rgbaTex.Load(int3(coord, 0));

    // Extract components (positions in normalized coords [0,1]).
    float px = xyz.x;
    float py = xyz.y;
    float pz = xyz.z;
    float alive = xyz.w;

    float vx = vel.x;
    float vy = vel.y;
    float vz = vel.z;
    float seed_f = vel.w;

    // If not alive, pass through unchanged.
    if (alive < 0.5)
    {
        PhysicalAgentOutputs deadOut;
        deadOut.xyz  = xyz;
        deadOut.vel  = vel;
        deadOut.rgba = rgba;
        return deadOut;
    }

    // Per-particle deviation (0 = all same speed, 1 = highly varied).
    float deviationMultiplier = 1.0 + (seed_f - 0.5) * deviation * 2.0;

    // Smooth wander perturbation using noise field.
    float noiseScale = 2.0;   // Adjust for normalized coords
    float wanderAngle = physical_fbm(float2(px, py) * noiseScale + time * 0.5) * 6.283185 * 2.0;
    float wanderStrength = wander * 0.002;   // Scaled for normalized coords
    float wanderX = cos(wanderAngle) * wanderStrength;
    float wanderY = sin(wanderAngle) * wanderStrength;

    // Physics forces (scaled for normalized coords). energy = global multiplier.
    float ax = (wind * 0.01 + wanderX) * energy;
    float ay = (-gravity * 0.01 + wanderY) * energy;   // Negate: +gravity pulls down

    // Update velocity with deviation.
    vx += ax * deviationMultiplier;
    vy += ay * deviationMultiplier;

    // Apply drag coefficient (0 = no drag, 0.2 = heavy drag).
    float dragFactor = 1.0 - drag;
    vx *= dragFactor;
    vy *= dragFactor;

    // Update position (deviation already factored into velocity).
    px += vx;
    py += vy;

    // Check for respawn conditions - set alive=0 to signal respawn.
    bool needsRespawn = false;

    // Respawn if out of bounds (normalized coords).
    if (px < 0.0 || px > 1.0 || py < 0.0 || py > 1.0)
    {
        needsRespawn = true;
    }

    // Attrition is now handled by pointsEmit.

    PhysicalAgentOutputs o;
    if (needsRespawn)
    {
        // Signal respawn by setting alive flag to 0; pointsEmit respawns next frame.
        o.xyz  = float4(px, py, pz, 0.0);
        o.vel  = float4(vx, vy, vz, seed_f);
        o.rgba = rgba;
    }
    else
    {
        o.xyz  = float4(px, py, pz, 1.0);
        o.vel  = float4(vx, vy, vz, seed_f);
        o.rgba = rgba;
    }
    return o;
}

// =============================================================================
// PASS: passthrough — copy input -> output for 2D-chain continuity (frag_passthrough)
// =============================================================================
float4 frag_passthrough(NMVaryings i) : SV_Target
{
    // WGSL: textureSample(inputTex, sampler, uv) with uv = the fullscreen UV.
    // The GLSL form uses uv = gl_FragCoord.xy / resolution; both equal i.uv
    // (NM_FragCoord = uv*resolution). We reproduce the divide-by-resolution form.
    float2 uv = NM_FragCoord(i) / resolution;
    return inputTex.SampleLevel(sampler_inputTex, uv, 0.0);
}

#endif // NM_EFFECT_PHYSICAL_INCLUDED
