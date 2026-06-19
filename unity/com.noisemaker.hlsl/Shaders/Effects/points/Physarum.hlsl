#ifndef NM_EFFECT_PHYSARUM_INCLUDED
#define NM_EFFECT_PHYSARUM_INCLUDED

// =============================================================================
// Physarum.hlsl — points/physarum (func: "physarum") — slime-mold agent sim
//
// AGENT-BASED multi-pass effect (hardest tier: MRT state, points-scatter
// deposit, feedback). Ported PIXEL-IDENTICALLY from the canonical WGSL sources
// (top-left origin, no per-effect Y flip; golden rule #1):
//   wgsl/diffuse.wgsl      progName "diffuse"      (frag_diffuse)      fullscreen
//   wgsl/agent.wgsl        progName "agent"        (frag_agent, MRT x3) fullscreen
//   wgsl/passthrough.wgsl  progName "passthrough"  (frag_passthrough)  fullscreen
//   wgsl/deposit.wgsl      progName "deposit"      (vert/frag_deposit) POINTS scatter
//   (passthrough is reused for the final 2D-chain blit too)
//
// PASS ORDER per frame (5) — from definition.js passes[]:
//   1. decayTrail (program "diffuse",   fullscreen)        apply persistence to the
//                                                          pheromone before agents sense
//   2. agent      (program "agent",     fullscreen, MRT3)  sensor-based steering; MRT
//                                                          writes new xyz/vel/rgba state
//   3. copy       (program "passthrough",fullscreen)       blit decayed pheromone to
//                                                          write buffer before deposit
//   4. deposit    (program "deposit",   POINTS scatter)    Blend One One — additive
//                                                          scatter of agent pheromones
//   5. passthrough(program "passthrough",fullscreen)       copy input -> output for
//                                                          2D-chain continuity
//
// PERSISTENT STATE TEXTURES (survive frame-to-frame; runtime ping-pongs them):
//   global_xyz  (rgba32f) — [x, y, heading(rad), alive]   positions normalized [0,1]
//   global_vel  (rgba32f) — [0, 0, age, seed]             age/seed for the sim
//   global_rgba (rgba32f) — [r, g, b, a]                  agent color (from pointsEmit)
//   global_physarum_pheromone (rgba16f, 100%) — private pheromone/chemistry trail.
//     PERSISTENT feedback surface: decayed by decayTrail, copied by copy, additively
//     deposited into by deposit (Blend One One), sensed by agent. It reads its own
//     prior 'global_' output so it persists frame-to-frame (runtime double-buffers /
//     ping-pongs; reference 04 §10.2/§10.7). NOTE: NOT a state-surface by the
//     isStateSurface predicate (name has no _xyz/_vel/_rgba suffix, no 'state'), but
//     the feedback read+write of the same 'global_' key keeps it alive.
// global_xyz/vel/rgba are created upstream by pointsEmit (sized stateSize x stateSize)
// and consumed downstream by pointsRender; physarum updates them in place (the effect
// declares outputXyz/Vel/Rgba aliasing the inputs). They ARE state-surfaces
// (suffix _xyz/_vel/_rgba) → end-of-frame bindings persist with NO swap.
//
// NOTE: multi-pass / agent effect → ships as a runtime-rendered Texture2D. NO Shader
// Graph Custom Function wrapper is provided (agent/multi-pass per PORTING-GUIDE).
// The C# runtime drives the 5 passes in order, rebinding state read/write targets
// per pass and issuing DrawProcedural(Points, stateSize*stateSize) for the deposit
// scatter.
//
// PORTING-GUIDE / parity notes:
//  * WGSL textureLoad(t, coord, 0) → t.Load(int3(coord, 0)) — integer texel fetch,
//    point, no filtering. Agent state reads + deposit vertex reads use this. rgba32f.
//  * WGSL textureSample(t, s, uv) / textureSampleLevel(t,s,uv,0.0) →
//    t.Sample(sampler_t, uv) / t.SampleLevel(sampler_t, uv, 0.0) — linear, clamp,
//    non-sRGB. Used by diffuse/passthrough (UV blit) and agent's trail/input sensing.
//  * fragCoord = @builtin(position).xy (top-left, +0.5 centered) → NM_FragCoord(i).
//    The agent pass runs fullscreen OVER THE STATE texture, so the runtime binds
//    _NM_Resolution == the bound state size for that pass and coord = (int2)
//    NM_FragCoord(i) == WGSL vec2i(fragCoord.xy) exactly (house convention; see
//    Flock/Dla). diffuse derives uv = fragCoord / u.resolution (resolution UNIFORM
//    == render-target size). Reproduced literally.
//  * fract→frac, mix→lerp, clamp/cos/sin/dot map 1:1. nm_mod / fmod NOT used here
//    (wrapping is frac(pos + 1.0)). No NMCore helpers used — this effect's PRNG is
//    its OWN PCG-style hash (hash_uint/hash) + a sin-hash (hash_f), ported verbatim
//    inline (differs from NMCore's pcg/prng/random; do NOT substitute).
//  * hash divisor is 4294967295.0 (= float(0xffffffffu)), NOT 2^32.
//  * float→u32 in WGSL u32(seed*1000.0) is a NUMERIC truncation → (uint)(seed*1000.0).
//  * resetState: WGSL diffuse takes a u32 tested `!= 0u`. We declare an int uniform
//    and test `!= 0` (the runtime injects 1/0). definition.js types it boolean.
//  * D3D points are 1px, matching the reference gl_PointSize=1 / WGSL implicit 1px
//    deposit. The deposit vertex Loads agent state in the VERTEX stage (SM4.5).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Textures (runtime rebinds per pass per definition.js inputs{}) ---------
// decayTrail (diffuse): trailTex (Sample)
// agent:                xyzTex,velTex,rgbaTex (Load); trailTex,inputTex (Sample)
// copy (passthrough):   inputTex (Sample)  -- bound to global_physarum_pheromone
// deposit:              xyzTex,rgbaTex (Load, in VERTEX stage)
// passthrough:          inputTex (Sample)  -- bound to the pipeline input
Texture2D xyzTex;     SamplerState sampler_xyzTex;
Texture2D velTex;     SamplerState sampler_velTex;
Texture2D rgbaTex;    SamplerState sampler_rgbaTex;
Texture2D trailTex;   SamplerState sampler_trailTex;
Texture2D inputTex;   SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
float moveSpeed;        // globals.moveSpeed       default 1.78
float turnSpeed;        // globals.turnSpeed       default 1
float sensorAngle;      // globals.sensorAngle     default 1.26
float sensorDistance;   // globals.sensorDistance  default 0.03 (normalized [0,1])
float inputWeight;      // globals.inputWeight     default 0
float deposit;          // globals.deposit         default 0.5
float decay;            // globals.decay           default 0.1
int   resetState;       // globals.resetState      boolean (1/0), tested != 0

static const float PHYS_TAU = 6.28318530718;

// =============================================================================
// Verbatim core helpers (this effect's OWN hashes — inline, per effect)
// =============================================================================
uint phys_hash_uint(uint seed)
{
    uint state = seed * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float phys_hash(uint seed)
{
    return (float)phys_hash_uint(seed) / 4294967295.0;
}

float phys_hash_f(float n)
{
    return frac(sin(n) * 43758.5453123);
}

// Wrap position to [0,1].  WGSL: fract(pos + vec2f(1.0)).
float2 phys_wrapPosition(float2 pos)
{
    return frac(pos + float2(1.0, 1.0));
}

float phys_luminance(float3 color)
{
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

// Sample trail at normalized UV (luminance). WGSL textureSampleLevel(...,0.0).
float phys_sampleTrail(float2 uv)
{
    return phys_luminance(trailTex.SampleLevel(sampler_trailTex, uv, 0.0).rgb);
}

// Sample input texture for external field attraction.
float phys_sampleExternalField(float2 uv, float weight)
{
    if (weight <= 0.0) { return 0.0; }
    float blend = clamp(weight * 0.01, 0.0, 1.0);
    return phys_luminance(inputTex.SampleLevel(sampler_inputTex, uv, 0.0).rgb) * blend * 0.05;
}

// =============================================================================
// PASS 1: diffuse — decay the existing pheromone trail (frag_diffuse).
// Pass name "decayTrail". WGSL: returns trailColor * persistence, or 0 on reset.
// =============================================================================
float4 frag_diffuse(NMVaryings i) : SV_Target
{
    // If resetState is true, clear the trail.
    if (resetState != 0)
    {
        return float4(0.0, 0.0, 0.0, 0.0);
    }

    float2 uv = NM_FragCoord(i) / resolution;

    // Sample the trail texture directly (no blur).
    float4 trailColor = trailTex.Sample(sampler_trailTex, uv);

    // Apply decay. decay=0 → persistence 1.0 (no decay); decay=1 → 0.0 (instant fade).
    float persistence = clamp(1.0 - decay, 0.0, 1.0);
    return trailColor * persistence;
}

// =============================================================================
// PASS 2: agent — sensor-based steering. MRT x3 (frag_agent, fullscreen).
//   SV_Target0 = outXYZ, SV_Target1 = outVel, SV_Target2 = outRGBA
//   (matches drawBuffers:3, outputs{ outXYZ:color, outVel:color1, outRGBA:color2 }).
// =============================================================================
struct PhysAgentOutputs
{
    float4 outXYZ  : SV_Target0;
    float4 outVel  : SV_Target1;
    float4 outRGBA : SV_Target2;
};

PhysAgentOutputs frag_agent(NMVaryings i)
{
    PhysAgentOutputs o;

    // State texture dims (== stateSize x stateSize). WGSL: textureDimensions(xyzTex,0).
    uint sw, sh;
    xyzTex.GetDimensions(sw, sh);
    int2 stateSize = int2((int)sw, (int)sh);

    // WGSL: coord = vec2i(i32(fragCoord.x), i32(fragCoord.y)). The agent pass runs
    // over the state texture, so _NM_Resolution is the state size for this pass.
    int2 coord = (int2)NM_FragCoord(i);

    // Read current state (rgba32f, point fetch).
    float4 xyz  = xyzTex.Load(int3(coord, 0));
    float4 vel  = velTex.Load(int3(coord, 0));
    float4 rgba = rgbaTex.Load(int3(coord, 0));

    float2 pos     = xyz.xy;   // normalized [0,1]
    float  heading = xyz.z;    // radians
    float  alive   = xyz.w;
    float  age     = vel.z;
    float  seed    = vel.w;

    // Dead agent — pass through; pointsEmit handles respawn. Initialize heading
    // from seed.  WGSL: hash(u32(seed * 1000.0)) * TAU.
    if (alive < 0.5)
    {
        o.outXYZ  = float4(pos, phys_hash((uint)(seed * 1000.0)) * PHYS_TAU, 0.0);
        o.outVel  = vel;
        o.outRGBA = rgba;
        return o;
    }

    // Sensor positions in normalized coords.
    float2 forwardDir = float2(cos(heading), sin(heading));
    float2 leftDir    = float2(cos(heading - sensorAngle), sin(heading - sensorAngle));
    float2 rightDir   = float2(cos(heading + sensorAngle), sin(heading + sensorAngle));

    float2 sensorPosF = phys_wrapPosition(pos + forwardDir * sensorDistance);
    float2 sensorPosL = phys_wrapPosition(pos + leftDir    * sensorDistance);
    float2 sensorPosR = phys_wrapPosition(pos + rightDir   * sensorDistance);

    // Sample trail + external field at sensor positions.
    float valF = phys_sampleTrail(sensorPosF) + phys_sampleExternalField(sensorPosF, inputWeight);
    float valL = phys_sampleTrail(sensorPosL) + phys_sampleExternalField(sensorPosL, inputWeight);
    float valR = phys_sampleTrail(sensorPosR) + phys_sampleExternalField(sensorPosR, inputWeight);

    // Steering logic.
    float newHeading = heading;
    if (valF > valL && valF > valR)
    {
        // Forward is best, keep going.
    }
    else if (valF < valL && valF < valR)
    {
        // Forward is worst, turn randomly.
        newHeading += (phys_hash_f(time + pos.x) - 0.5) * 2.0 * turnSpeed * moveSpeed;
    }
    else if (valL > valR)
    {
        // Turn left.
        newHeading -= turnSpeed * moveSpeed;
    }
    else if (valR > valL)
    {
        // Turn right.
        newHeading += turnSpeed * moveSpeed;
    }

    // Move forward.
    float2 moveDir = float2(cos(newHeading), sin(newHeading));

    // Speed modulation from input texture.
    float speedScale = 1.0;
    float blend = clamp(inputWeight * 0.01, 0.0, 1.0);
    if (blend > 0.0)
    {
        float localInput = phys_luminance(inputTex.SampleLevel(sampler_inputTex, pos, 0.0).rgb);
        // Invert: slow in bright, fast in dark.
        speedScale = lerp(1.0, lerp(1.8, 0.35, localInput), blend);
    }

    // Scale moveSpeed to normalized coords.
    float normalizedSpeed = moveSpeed * 0.001 * speedScale;
    float2 newPos = phys_wrapPosition(pos + moveDir * normalizedSpeed);

    // Update age.
    float newAge = age + 0.016;

    o.outXYZ  = float4(newPos, newHeading, 1.0);   // alive = 1
    o.outVel  = float4(0.0, 0.0, newAge, seed);
    o.outRGBA = rgba;                              // color unchanged
    return o;
}

// =============================================================================
// PASS 3 & 5: passthrough — copy inputTex by uv (frag_passthrough, fullscreen).
//   Pass "copy"        : inputTex == global_physarum_pheromone (blit to write buf).
//   Pass "passthrough" : inputTex == pipeline input (2D-chain continuity).
//   WGSL: uv = position.xy / u.resolution; return textureSample(inputTex, s, uv).
// =============================================================================
float4 frag_passthrough(NMVaryings i) : SV_Target
{
    float2 uv = NM_FragCoord(i) / resolution;
    return inputTex.Sample(sampler_inputTex, uv);
}

// =============================================================================
// PASS 4: deposit — POINTS scatter (Blend One One additive).
//
// Custom vertex stage: one point per agent (count = stateSize*stateSize). The
// runtime issues DrawProcedural(Points, count). Reads agent state in the VERTEX
// stage via Texture2D.Load (SM4.5 permits VS texture Load). D3D points are 1px,
// matching the reference gl_PointSize=1 / WGSL implicit 1px deposit.
//
// Ported verbatim from deposit.wgsl (and deposit.vert / deposit.frag for the
// scatter clip-space transform): clipPos = pos.xy * 2.0 - 1.0 (top-left clip, no
// Y flip per golden rule #1); off-screen cull writes position (2,2,0,1).
// =============================================================================
struct PhysDepositVaryings
{
    float4 positionCS : SV_POSITION;
    float4 color      : TEXCOORD0;
};

PhysDepositVaryings vert_deposit(uint vertexID : SV_VertexID)
{
    PhysDepositVaryings o;

    // State size from xyz texture dimensions (inherited from pointsEmit).
    uint tw, th;
    xyzTex.GetDimensions(tw, th);
    int stateSize = (int)tw;
    int totalAgents = stateSize * stateSize;

    // Cull vertices beyond texture size.
    if ((int)vertexID >= totalAgents)
    {
        o.positionCS = float4(2.0, 2.0, 0.0, 1.0);
        o.color = float4(0.0, 0.0, 0.0, 0.0);
        return o;
    }

    // Texel for this agent.  WGSL: x = id % stateSize, y = id / stateSize.
    int x = (int)vertexID % stateSize;
    int y = (int)vertexID / stateSize;

    // Read agent position and color (VS Load, SM4.5).
    float4 pos = xyzTex.Load(int3(int2(x, y), 0));
    float4 col = rgbaTex.Load(int3(int2(x, y), 0));

    // Cull dead agents (pos.w >= 0.5 means alive).
    if (pos.w < 0.5)
    {
        o.positionCS = float4(2.0, 2.0, 0.0, 1.0);
        o.color = float4(0.0, 0.0, 0.0, 0.0);
        return o;
    }

    // Convert position (0..1) to clip space (-1..1). No Y flip (golden rule #1).
    float2 clipPos = pos.xy * 2.0 - 1.0;
    o.positionCS = float4(clipPos, 0.0, 1.0);

    // Apply deposit amount.
    o.color = float4(col.rgb * deposit, col.a * deposit);
    return o;
}

float4 frag_deposit(PhysDepositVaryings i) : SV_Target
{
    return i.color;
}

#endif // NM_EFFECT_PHYSARUM_INCLUDED
