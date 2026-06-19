#ifndef NM_EFFECT_POINTSEMIT_INCLUDED
#define NM_EFFECT_POINTSEMIT_INCLUDED

// =============================================================================
// PointsEmit.hlsl — render/pointsEmit (func: "pointsEmit")
//
// AGENT-STATE INITIALIZER (3D/RENDER tier middleware). Initializes and maintains
// the PERSISTENT agent state-surfaces that downstream agent sims (physarum/flock/
// flow/dla/...) and pointsRender/pointsBillboardRender consume. pointsEmit itself
// does NOT draw geometry — both of its passes are FULLSCREEN over the state
// textures; agent rasterization happens in the renderer effects.
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL sources (top-left origin, no
// per-effect Y flip; golden rule #1):
//   wgsl/init.wgsl         progName "init"         (frag_init, MRT x3)  fullscreen
//   wgsl/passthrough.wgsl  progName "passthrough"  (frag_passthrough)   fullscreen
//
// PASS ORDER per frame (2) — from definition.js passes[]:
//   1. init        (program "init",        fullscreen, MRT3, drawBuffers:3)
//                  per-agent respawn/persist; writes new xyz/vel/rgba state.
//   2. passthrough (program "passthrough", fullscreen) copy pipeline input ->
//                  outputTex (2D-chain continuity).
//
// PERSISTENT STATE TEXTURES (survive frame-to-frame; runtime persists w/ NO swap
// since they are isStateSurface by suffix; reference 04 §10.7):
//   global_xyz  (rgba32f) — [x, y, z(=0), alive]  positions normalized [0,1]
//   global_vel  (rgba32f) — [0, 0, rotRand, strideRand]  per-agent randoms
//   global_rgba (rgba8)   — [r, g, b, a]  agent color sampled from inputTex
//   Sized stateSize x stateSize. init reads its OWN prior 'global_' output to
//   decide respawn-vs-persist (runtime double-buffers / ping-pongs).
//
// NOTE: multi-pass / agent-state effect → ships as a runtime-rendered Texture2D.
// NO Shader Graph Custom Function wrapper (multi-pass / 3D-render tier per the
// PORTING-GUIDE / task). The C# runtime drives the 2 passes in order, rebinding
// state read/write targets per pass (init writes all 3 via MRT drawBuffers:3).
//
// PORTING-GUIDE / parity notes:
//  * WGSL textureLoad(t, coord, 0) → t.Load(int3(coord, 0)) — integer texel fetch,
//    point, no filtering. Agent state reads + inputTex color read use this.
//  * fragCoord = @builtin(position).xy (top-left, +0.5 centered) → NM_FragCoord(i).
//    The init pass runs fullscreen OVER THE STATE texture, so the runtime binds
//    _NM_Resolution == the bound state size for that pass and
//    stateCoord = (int2)NM_FragCoord(i) == WGSL vec2i(coord.xy) exactly.
//    uv = coord.xy / f32(u.stateSize) reproduced literally (divides by the
//    stateSize UNIFORM, NOT the texture dims).
//  * fract→frac, mix→lerp, clamp/cos/sin/floor map 1:1. nm_mod / fmod NOT used.
//  * This effect's PRNG is its OWN PCG-style integer hash (hash_uint/hash/hash2),
//    ported verbatim inline (identical bytes to physarum's hash, but NOT a NMCore
//    helper — do NOT substitute pcg/prng/random).
//  * hash divisor is 4294967295.0 (= float(0xffffffffu)), NOT 2^32 (H11).
//  * float bits→uint: WGSL bitcast<u32>(u.time) → asuint(time) (bit reinterpret).
//  * float→u32: WGSL u32(seed)/u32(clusterId) is NUMERIC truncation → (uint)x.
//  * int→uint: WGSL u32(u.seed) → (uint)seed (two's-complement preserved).
//  * select(white, sampled, sampled.a > 0.0) → ternary (sampled.a > 0.0)?...:white.
//    NOTE WGSL select arg order is (falseVal, trueVal, cond) — reproduced as a
//    standard HLSL ternary.
//  * resetState: WGSL takes u32 tested `!= 0u`. We declare an int uniform and test
//    `!= 0` (runtime injects 1/0). definition.js types it boolean.
//  * passthrough: WGSL textureSample(inputTex, s, in.uv) where in.uv == the
//    fullscreen-VS uv. We reproduce via NM_FragCoord(i)/resolution to match the
//    GLSL passthrough (uv = gl_FragCoord.xy / resolution) and the WGSL VS uv
//    identically (top-left, no flip). t.Sample(sampler_t, uv): linear, clamp,
//    non-sRGB.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Textures (runtime rebinds per pass per definition.js inputs{}) ---------
// init:        xyzTex, velTex, rgbaTex (Load); inputTex (Load)
// passthrough: inputTex (Sample) -- bound to the pipeline input
Texture2D xyzTex;     SamplerState sampler_xyzTex;
Texture2D velTex;     SamplerState sampler_velTex;
Texture2D rgbaTex;    SamplerState sampler_rgbaTex;
Texture2D inputTex;   SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
// Engine globals (time, resolution, ...) come from NMFullscreen aliases.
int   seed;          // globals.seed       default 0   (int slider 0..100)
int   stateSize;     // globals.stateSize  default 256 (dropdown 64..2048)
int   layoutMode;    // globals.layout (uniform "layout"); init remaps -> layoutMode
float attrition;     // globals.attrition  default 0   (0..10, % per frame /100)
int   resetState;    // globals.resetState boolean (1/0), tested != 0

// =============================================================================
// Verbatim core helpers (this effect's OWN integer hashes — inline, per effect)
// =============================================================================
uint pe_hash_uint(uint seed)
{
    uint state = seed * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float pe_hash(uint seed)
{
    return (float)pe_hash_uint(seed) / 4294967295.0;
}

float2 pe_hash2(uint seed)
{
    return float2(pe_hash(seed), pe_hash(seed + 1u));
}

// =============================================================================
// PASS 1: init — per-agent respawn/persist. MRT x3 (frag_init, fullscreen).
//   SV_Target0 = outXYZ, SV_Target1 = outVel, SV_Target2 = outRGBA
//   (matches drawBuffers:3, outputs{ outXYZ:color, outVel:color1, outRGBA:color2 }).
// =============================================================================
struct PointsEmitOutputs
{
    float4 outXYZ  : SV_Target0;
    float4 outVel  : SV_Target1;
    float4 outRGBA : SV_Target2;
};

PointsEmitOutputs frag_init(NMVaryings i)
{
    PointsEmitOutputs o;

    // WGSL: coord = @builtin(position) (top-left, +0.5). The init pass runs over
    // the state texture, so _NM_Resolution == stateSize x stateSize for this pass.
    float2 coord = NM_FragCoord(i);
    int2 stateCoord = (int2)coord;                  // WGSL vec2<i32>(coord.xy)
    float2 uv = coord / (float)stateSize;           // WGSL coord.xy / f32(u.stateSize)

    // Agent seed for random generation — compute early for attrition check.
    // WGSL: u32(stateCoord.x + stateCoord.y * u.stateSize) + u32(u.seed).
    uint agentSeed = (uint)(stateCoord.x + stateCoord.y * stateSize) + (uint)seed;

    // Read previous state with Load (integer texel fetch, point) for parity.
    float4 pPos = xyzTex.Load(int3(stateCoord, 0));
    float4 pVel = velTex.Load(int3(stateCoord, 0));
    float4 pCol = rgbaTex.Load(int3(stateCoord, 0));

    // Respawn check. w of xyz holds the "alive" flag; resetState forces respawn.
    bool needsRespawn = (resetState != 0) || (pPos.w < 0.5) || (time < 0.01 && pPos.w == 0.0);

    // Attrition: per-frame random respawn chance. Mix continuous time into hash.
    if (!needsRespawn && attrition > 0.0)
    {
        uint timeBits = asuint(time);              // WGSL bitcast<u32>(u.time)
        uint check_seed = agentSeed * 1664525u + timeBits;
        check_seed = pe_hash_uint(check_seed);     // extra mixing
        float respawnRand = (float)check_seed / 4294967295.0;
        float attritionRate = attrition * 0.01;    // 0-10% per frame
        if (respawnRand < attritionRate)
        {
            needsRespawn = true;
        }
    }

    // Compute spawn values unconditionally (no branching in texture access).
    float2 rnd = pe_hash2(agentSeed);

    // Position based on layout mode.
    float3 newPos = float3(0.0, 0.0, 0.0);
    if (layoutMode == 0)         // Random
    {
        newPos = float3(rnd, 0.0);
    }
    else if (layoutMode == 1)    // Grid
    {
        newPos = float3(uv, 0.0);
    }
    else if (layoutMode == 2)    // Center
    {
        newPos = float3(0.5 + (rnd - 0.5) * 0.1, 0.0);
    }
    else if (layoutMode == 3)    // Ring
    {
        float angle = rnd.x * 6.28318;
        float radius = 0.3 + rnd.y * 0.1;
        newPos = float3(0.5 + float2(cos(angle), sin(angle)) * radius, 0.0);
    }
    else if (layoutMode == 4)    // Clusters
    {
        // 5 random cluster centers based on seed.
        uint clusterSeed = (uint)seed * 12345u;
        float clusterId = floor(rnd.x * 5.0);
        uint centerSeed = clusterSeed + (uint)clusterId * 31u;
        float2 center = float2(pe_hash(centerSeed), pe_hash(centerSeed + 17u));
        // Agents spread around center with ~15% radius.
        float r = pe_hash(agentSeed + 2u) * 0.15;
        float a = pe_hash(agentSeed + 3u) * 6.28318;
        newPos = float3(center + float2(cos(a), sin(a)) * r, 0.0);
        // Wrap to [0,1].
        newPos = float3(frac(newPos.xy), 0.0);
    }
    else if (layoutMode == 5)    // Spiral
    {
        // Archimedean spiral from center.
        float t = rnd.x * 20.0;
        float r = t * 0.02;      // Spiral expands slowly
        float a = t * 6.28318;
        newPos = float3(0.5 + float2(cos(a), sin(a)) * r, 0.0);
        // Clamp to valid range.
        newPos = float3(clamp(newPos.xy, float2(0.0, 0.0), float2(1.0, 1.0)), 0.0);
    }

    // Sample color from inputTex via Load (avoids uniform control-flow issue).
    // WGSL: texCoord = vec2<i32>(newPos.xy * vec2<f32>(textureDimensions(inputTex))).
    uint tw, th;
    inputTex.GetDimensions(tw, th);
    float2 texDims = float2((float)tw, (float)th);
    int2 texCoord = (int2)(newPos.xy * texDims);
    float4 sampledCol = inputTex.Load(int3(texCoord, 0));
    // Use sampled color if texture has content (alpha > 0), otherwise white.
    float4 newCol = (sampledCol.a > 0.0) ? sampledCol : float4(1.0, 1.0, 1.0, 1.0);

    if (needsRespawn)
    {
        // Per-agent randoms stored in vel for downstream effects:
        //   vel.z = rotRand   [0,1]     rotation variation
        //   vel.w = strideRand [-0.5,0.5] stride variation
        float rotRand = pe_hash(agentSeed + 100u);
        float strideRand = pe_hash(agentSeed + 101u) - 0.5;
        o.outXYZ  = float4(newPos, 1.0);
        o.outVel  = float4(0.0, 0.0, rotRand, strideRand);
        o.outRGBA = newCol;
    }
    else
    {
        o.outXYZ  = pPos;
        o.outVel  = pVel;
        o.outRGBA = pCol;
    }
    return o;
}

// =============================================================================
// PASS 2: passthrough — copy inputTex by uv (frag_passthrough, fullscreen).
//   Copies the chained pipeline input to outputTex (2D-chain continuity).
//   GLSL: uv = gl_FragCoord.xy / resolution; texture(inputTex, uv).
//   WGSL: textureSample(inputTex, s, in.uv) (in.uv == fullscreen VS uv).
//   Both equal NM_FragCoord(i)/resolution at pixel centers (top-left, no flip).
// =============================================================================
float4 frag_passthrough(NMVaryings i) : SV_Target
{
    float2 uv = NM_FragCoord(i) / resolution;
    return inputTex.Sample(sampler_inputTex, uv);
}

#endif // NM_EFFECT_POINTSEMIT_INCLUDED
