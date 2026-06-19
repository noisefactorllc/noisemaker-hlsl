#ifndef NM_EFFECT_DLA_INCLUDED
#define NM_EFFECT_DLA_INCLUDED

// =============================================================================
// Dla.hlsl — points/dla (func: "dla") — Diffusion-Limited Aggregation
//
// AGENT-BASED multi-pass effect. Ported PIXEL-IDENTICALLY from the canonical
// WGSL sources (top-left origin, no per-effect Y flip):
//   wgsl/initGrid.wgsl     progName "initGrid"     (frag_initGrid)   fullscreen
//   wgsl/copyGrid.wgsl     progName "copyGrid"     (frag_copyGrid)   fullscreen
//   wgsl/agent.wgsl        progName "agent"        (frag_agent)      fullscreen, MRT x3
//   wgsl/depositGrid.wgsl  progName "depositGrid"  (vert/frag_deposit) POINTS scatter
//   wgsl/passthrough.wgsl  progName "passthrough"  (frag_passthrough) fullscreen
//
// PASS ORDER per frame (5):
//   1. initGrid   (fullscreen)        decay/reseed the persistent anchor grid
//   2. copyGrid   (fullscreen)        blit grid -> write buffer (post-swap refresh)
//   3. agent      (fullscreen, MRT3)  random-walk + stick detection; MRT writes
//                                     new xyz/vel/rgba agent state
//   4. depositGrid(POINTS scatter)    Blend One One — additive deposit of agents
//                                     that just stuck (vel.y==1) into the grid
//   5. passthrough(fullscreen)        composite grid over input -> outputTex
//
// PERSISTENT STATE TEXTURES (survive frame-to-frame; runtime ping-pongs them):
//   global_xyz  (rgba32f) — xy=position[0,1], z=0, w=alive flag      (state-surface)
//   global_vel  (rgba32f) — x=seed, y=justStuck, z=0, w=agentRand    (state-surface)
//   global_rgba (rgba32f) — agent color rgba                         (state-surface)
//   global_dla_grid (rgba16f) — anchor grid: rgb=color, a=energy. Persistent
//                                 feedback surface (NOT a state-surface by the
//                                 isStateSurface predicate, but it reads its own
//                                 prior 'global_' output so it persists).
// xyz/vel/rgba are produced upstream by pointsEmit and consumed downstream by
// pointsRender; dla updates them in place (outputXyz/Vel/Rgba alias the inputs).
//
// MULTI-PASS / AGENT → ships as a runtime-rendered Texture2D. NO Shader Graph
// Custom Function wrapper is provided (the C# runtime drives the 5 passes in
// order, rebinding state read/write targets per pass and issuing
// DrawProcedural(Points, stateSize*stateSize) for the deposit scatter).
//
// PORTING-GUIDE / parity notes:
//  * WGSL textureLoad(t, coord, 0) → t.Load(int3(coord, 0)) — integer texel
//    fetch, point, no filtering. Agent/grid rgba state is read this way.
//  * WGSL textureSample(t, s, uv) → t.Sample(sampler_t, uv) — linear, clamp,
//    non-sRGB. Used by copyGrid and passthrough (UV sampling of the grid/input).
//  * WGSL fract → frac, mix → lerp, smoothstep → smoothstep, normalize/cos/sin
//    map 1:1. nm_mod is NOT used here (wrap01 uses fract(max(v,0))).
//  * bitcast<u32>(f) → asuint(f); bitcast<f32>(u) → asfloat(u). The PCG-style
//    rand() bit-twiddling masks (& 0x007FFFFFu) | 0x3F800000u and the -1.0 are
//    reproduced verbatim from the WGSL (NOTE: the WGSL masks BOTH draws; the
//    GLSL omits the mask on the first — we follow WGSL per golden rule #1).
//  * The agent seed evolution uses agentId and the PREVIOUS seed bits ONLY
//    (frameSeed = hash_uint(agentId*31u + bitcast<u32>(seed))) — the WGSL has
//    NO frame/time uniform (the GLSL variant's `frame`/`time` path is NOT the
//    canonical source; we port the WGSL exactly).
//  * vec2<f32>(textureDimensions(t)) → GetDimensions(w,h); float2((float)w,...).
//  * vec2<i32>(x) truncates toward zero after the implicit floor for the
//    non-negative coords used → int2(x) mirrors it.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Textures (runtime rebinds per pass per definition.js inputs{}) ---------
// initGrid:     gridTex (Load)
// copyGrid:     gridTex (Sample)
// agent:        xyzTex,velTex,rgbaTex,gridTex (Load); inputTex (Load)
// depositGrid:  xyzTex,velTex,rgbaTex (Load, in VERTEX stage)
// passthrough:  inputTex,gridTex (Sample)
Texture2D xyzTex;    SamplerState sampler_xyzTex;
Texture2D velTex;    SamplerState sampler_velTex;
Texture2D rgbaTex;   SamplerState sampler_rgbaTex;
Texture2D gridTex;   SamplerState sampler_gridTex;
Texture2D inputTex;  SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
float anchorDensity;  // globals.anchorDensity default 0.5
float stride;         // globals.stride        default 15
float inputWeight;    // globals.inputWeight   default 15
float decay;          // globals.decay         default 0.25
float deposit;        // globals.deposit       default 17.5
float attrition;      // globals.attrition     default 7.5
float matteOpacity;   // globals.matteOpacity  default 1.0
int   stateSize;      // globals.stateSize     default 256
// initGrid WGSL declares a resetState flag (clears grid when nonzero). Not in
// definition.js globals; the runtime injects it. Default 0 (no reset).
int   resetState;     // injected reset flag, tested != 0

// =============================================================================
// Shared PCG-style helpers (ported verbatim from agent.wgsl). Kept local to
// this effect — NOT from NMCore (this effect's prng differs from the shared one).
// =============================================================================
uint dla_hash_uint(uint seed)
{
    uint state = seed * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float dla_hash(uint seed)
{
    return (float)dla_hash_uint(seed) / 4294967295.0;
}

// PCG-style random using a float seed stored as bits (inout, WGSL ptr<function>).
float dla_rand(inout float seed)
{
    uint bits = asuint(seed);
    bits = dla_hash_uint(bits);
    seed = asfloat((bits & 0x007FFFFFu) | 0x3F800000u) - 1.0;
    bits = dla_hash_uint(bits + 1u);
    seed = asfloat((bits & 0x007FFFFFu) | 0x3F800000u) - 1.0;
    return seed;
}

float2 dla_randomDirection(inout float seed)
{
    float theta = dla_rand(seed) * 6.28318530718;
    return float2(cos(theta), sin(theta));
}

float2 dla_wrap01(float2 v)
{
    return frac(max(v, float2(0.0, 0.0)));
}

float dla_sampleGrid(float2 uv)
{
    uint gw, gh;
    gridTex.GetDimensions(gw, gh);
    float2 dims = float2((float)gw, (float)gh);
    int2 coord = int2(dla_wrap01(uv) * dims);
    return gridTex.Load(int3(coord, 0)).a;
}

float dla_neighborhood(float2 uv, float radius)
{
    uint gw, gh;
    gridTex.GetDimensions(gw, gh);
    float2 dims = float2((float)gw, (float)gh);
    float2 texel = radius / dims;
    float accum = 0.0;
    accum += dla_sampleGrid(uv);
    accum += dla_sampleGrid(uv + float2(texel.x, 0.0));
    accum += dla_sampleGrid(uv - float2(texel.x, 0.0));
    accum += dla_sampleGrid(uv + float2(0.0, texel.y));
    accum += dla_sampleGrid(uv - float2(0.0, texel.y));
    return accum * 0.2;
}

// =============================================================================
// PASS 1: initGrid — decay + reseed the persistent anchor grid (fullscreen)
// =============================================================================
float dla_hash21(float2 p)
{
    float3 p3 = frac(float3(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, float3(p3.z, p3.y, p3.x) + 31.32);
    return frac((p3.x + p3.y) * p3.z);
}

float4 frag_initGrid(NMVaryings i) : SV_Target
{
    // If resetState is true, clear the grid.
    if (resetState != 0)
    {
        return float4(0.0, 0.0, 0.0, 0.0);
    }

    float2 fragCoord = NM_FragCoord(i);
    int2 coord = int2(fragCoord);
    float2 uv = fragCoord / resolution;

    // Sample previous grid value (integer texel fetch).
    float4 prevSample = gridTex.Load(int3(coord, 0));
    float prev = prevSample.a;
    float3 prevColor = prevSample.rgb;

    // Apply decay (0 = full persistence, higher = faster fade).
    float persistence = 1.0 - decay;
    float energy = prev * persistence;
    float3 color = prevColor * persistence;

    // Cap energy to prevent runaway accumulation.
    energy = min(energy, 3.0);

    // Seed initial structure - always try, but only where grid is empty.
    float rng = dla_hash21(fragCoord);

    // Radial falloff from center - larger area for seeding.
    float radial = smoothstep(0.25, 0.0, length(uv - 0.5));

    // Seed density controls threshold (higher = more seeds).
    float seedThreshold = 1.0 - anchorDensity * 0.1;
    float seedWeight = step(seedThreshold, rng) * radial;

    // Only seed where there's no existing structure.
    if (seedWeight > 0.0 && prev < 0.1)
    {
        float strength = lerp(0.5, 1.0, rng);
        energy = max(energy, strength);
        color = float3(strength, strength, strength);
    }

    return float4(color, energy);
}

// =============================================================================
// PASS 2: copyGrid — blit grid to write buffer for proper blending (fullscreen)
// =============================================================================
float4 frag_copyGrid(NMVaryings i) : SV_Target
{
    return gridTex.Sample(sampler_gridTex, i.uv);
}

// =============================================================================
// PASS 3: agent — random walk + stick detection. MRT x3 (fullscreen).
//   SV_Target0 = outXYZ, SV_Target1 = outVel, SV_Target2 = outRGBA
// =============================================================================
struct DlaAgentOutputs
{
    float4 outXYZ  : SV_Target0;
    float4 outVel  : SV_Target1;
    float4 outRGBA : SV_Target2;
};

DlaAgentOutputs frag_agent(NMVaryings i)
{
    DlaAgentOutputs o;

    float2 fragCoord = NM_FragCoord(i);
    int2 coord = int2(fragCoord);

    uint sw, sh;
    xyzTex.GetDimensions(sw, sh);
    int2 stateDims = int2((int)sw, (int)sh);

    // Read input state from pipeline (from pointsEmit).
    float4 xyz = xyzTex.Load(int3(coord, 0));
    float4 vel = velTex.Load(int3(coord, 0));
    float4 rgba = rgbaTex.Load(int3(coord, 0));

    // Extract state.
    float2 pos = xyz.xy;
    float alive = xyz.w;

    // vel.x = seed, vel.y = justStuck flag, vel.w = agentRand from emitter.
    float seed = vel.x;
    float agentRand = vel.w;

    // Initialize or evolve seed using agent ID and existing seed.
    uint agentId = (uint)(coord.x + coord.y * (int)stateDims.x);
    if (seed <= 0.0)
    {
        seed = dla_hash(agentId + 12345u) + 0.001;
    }
    // Mix in agentId and previous seed to ensure a different direction each frame.
    uint frameSeed = dla_hash_uint(agentId * 31u + asuint(seed));
    seed = asfloat((frameSeed & 0x007FFFFFu) | 0x3F800000u) - 1.0;

    // If not alive, pass through (waiting for respawn from pointsEmit).
    if (alive < 0.5)
    {
        o.outXYZ = xyz;
        o.outVel = float4(seed, 0.0, 0.0, agentRand);
        o.outRGBA = rgba;
        return o;
    }

    // Grid dimensions for step size.
    uint gw, gh;
    gridTex.GetDimensions(gw, gh);
    float2 gridDims = float2((float)gw, (float)gh);
    float texel = 1.0 / max(gridDims.x, gridDims.y);

    // Check proximity to existing structure.
    float local = dla_neighborhood(pos, 2.0);
    float proximity = smoothstep(0.015, 0.12, local);

    // Random direction for walk.
    float2 randomDir = dla_randomDirection(seed);

    // Input-weighted direction.
    float inputW = inputWeight / 100.0;
    float2 stepDir = randomDir;
    if (inputW > 0.0)
    {
        uint iw, ih;
        inputTex.GetDimensions(iw, ih);
        float2 inputDimsF = float2((float)iw, (float)ih);
        int2 inputCoord = int2(dla_wrap01(pos) * inputDimsF);
        float4 inputVal = inputTex.Load(int3(inputCoord, 0));
        float2 inputDir = inputVal.xy * 2.0 - 1.0;
        if (length(inputDir) > 0.01)
        {
            inputDir = normalize(inputDir);
            stepDir = normalize(lerp(randomDir, inputDir, inputW));
        }
    }

    // Step size: slow down near structure for finer aggregation.
    float stepSize = (stride / 10.0) * texel * lerp(3.0, 0.5, proximity);

    // Add wander jitter.
    stepDir += dla_randomDirection(seed) * 0.3;
    stepDir = normalize(stepDir);

    // Move agent.
    float2 candidate = dla_wrap01(pos + stepDir * stepSize);

    // Check for sticking - require direct adjacency (radius 1.0).
    float here = dla_sampleGrid(candidate);
    float nearby = dla_neighborhood(candidate, 1.0);

    // Stick if adjacent to structure but local spot is empty.
    bool stuck = (nearby > 0.3 && here < 0.5);

    // Attrition: random respawn (0-10 scale → 0-0.1).
    bool needsRespawn = false;
    if (attrition > 0.0)
    {
        float attritionRate = attrition * 0.01;
        if (dla_rand(seed) < attritionRate)
        {
            needsRespawn = true;
        }
    }

    if (stuck)
    {
        // Agent stuck: mark dead for respawn, flag justStuck for deposit.
        o.outXYZ = float4(candidate, 0.0, 0.0);          // w=0 signals death
        o.outVel = float4(seed, 1.0, 0.0, agentRand);    // y=1 "just stuck"
        o.outRGBA = rgba;
    }
    else if (needsRespawn)
    {
        // Attrition death: mark for respawn.
        o.outXYZ = float4(candidate, 0.0, 0.0);          // w=0 signals death
        o.outVel = float4(seed, 0.0, 0.0, agentRand);    // y=0, not stuck
        o.outRGBA = rgba;
    }
    else
    {
        // Continue walking.
        o.outXYZ = float4(candidate, 0.0, 1.0);          // w=1 alive
        o.outVel = float4(seed, 0.0, 0.0, agentRand);
        o.outRGBA = rgba;
    }
    return o;
}

// =============================================================================
// PASS 4: depositGrid — POINTS scatter (Blend One One additive).
//
// Custom vertex stage: one point per agent (count = stateSize*stateSize). The
// runtime issues DrawProcedural(Points, count). Reads agent state in the VERTEX
// stage via Texture2D.Load (SM4.5 permits VS texture Load). D3D points are 1px,
// matching the reference's gl_PointSize=1 / WGSL implicit 1px deposit.
// =============================================================================
struct DlaDepositVaryings
{
    float4 positionCS : SV_POSITION;
    float  weight     : TEXCOORD0;
    float3 color      : TEXCOORD1;
};

int2 dla_decodeIndex(int index, int2 dims)
{
    int x = index % dims.x;
    int y = index / dims.x;
    return int2(x, y);
}

DlaDepositVaryings vert_deposit(uint vertexID : SV_VertexID)
{
    DlaDepositVaryings o;

    uint dw, dh;
    xyzTex.GetDimensions(dw, dh);
    int2 dims = int2((int)dw, (int)dh);
    int totalAgents = dims.x * dims.y;

    // Skip if vertex index exceeds agent count.
    if ((int)vertexID >= totalAgents)
    {
        o.positionCS = float4(-2.0, -2.0, 0.0, 1.0);
        o.weight = 0.0;
        o.color = float3(0.0, 0.0, 0.0);
        return o;
    }

    int2 coord = dla_decodeIndex((int)vertexID, dims);

    float4 xyz = xyzTex.Load(int3(coord, 0));
    float4 vel = velTex.Load(int3(coord, 0));
    float4 rgba = rgbaTex.Load(int3(coord, 0));

    // vel.y == 1.0 means this agent just stuck.
    float justStuck = vel.y;

    o.weight = justStuck;
    o.color = rgba.rgb;

    // Only render if just stuck.
    if (justStuck < 0.5)
    {
        o.positionCS = float4(-2.0, -2.0, 0.0, 1.0);
        return o;
    }

    // Position from xyz (normalized [0,1]) → clip space.
    // WGSL/D3D both top-left clip; no Y flip (golden rule #1).
    float2 clip = xyz.xy * 2.0 - 1.0;
    o.positionCS = float4(clip, 0.0, 1.0);

    return o;
}

float4 frag_deposit(DlaDepositVaryings i) : SV_Target
{
    // Discard if not a stuck agent.
    if (i.weight < 0.5)
    {
        discard;
    }

    // Deposit energy with agent color.
    // deposit range [0.5, 20] maps to energy [0.05, 2.0].
    float energy = deposit * 0.1;
    return float4(i.color * energy, energy);
}

// =============================================================================
// PASS 5: passthrough — composite grid over input → outputTex (fullscreen)
// =============================================================================
float4 frag_passthrough(NMVaryings i) : SV_Target
{
    float2 uv = NM_FragCoord(i) / resolution;
    float4 input = inputTex.Sample(sampler_inputTex, uv);
    float4 grid = gridTex.Sample(sampler_gridTex, uv);

    // Blend grid structure over input. Grid alpha indicates structure presence.
    float gridStrength = clamp(grid.a, 0.0, 1.0);
    float3 gridColor = grid.rgb;
    float matteAlpha = matteOpacity;

    // Where grid exists, show grid color; else show input (premultiplied by matte).
    float3 color = lerp(input.rgb * matteAlpha, gridColor, gridStrength);

    // Alpha: where grid exists, full opacity; elsewhere, matte opacity.
    float alpha = max(gridStrength, matteAlpha);

    return float4(color, alpha);
}

#endif // NM_EFFECT_DLA_INCLUDED
