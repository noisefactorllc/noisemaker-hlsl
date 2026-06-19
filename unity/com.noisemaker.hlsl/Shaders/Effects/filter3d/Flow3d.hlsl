#ifndef NM_EFFECT_FLOW3D_INCLUDED
#define NM_EFFECT_FLOW3D_INCLUDED

// =============================================================================
// Flow3d.hlsl — filter3d/flow3d (func: "flow3d") — 3D agent-based flow field.
//
// 3D / RENDER tier. AGENT-BASED multi-pass effect (MRT agent state in 2D
// textures, points-scatter deposit into a 3D VOLUME ATLAS, feedback). Ported
// PIXEL-IDENTICALLY from the canonical WGSL sources (top-left origin, no
// per-effect Y flip; golden rule #1):
//   wgsl/agent.wgsl    progName "agent"   (frag_agent, MRT x3)  fullscreen-over-state
//   wgsl/diffuse.wgsl  progName "diffuse" (frag_diffuse)        fullscreen (volume atlas)
//   wgsl/copy.wgsl     progName "copy"    (frag_copy)           fullscreen (volume atlas)
//   wgsl/deposit.wgsl  progName "deposit" (vert/frag_deposit)   POINTS scatter (volume atlas)
//   wgsl/blend.wgsl    progName "blend"   (frag_blend)          fullscreen (volume atlas)
//
// PASS ORDER per frame (5) — from definition.js passes[]:
//   1. agent   (program "agent",   fullscreen over the 512x512 state grid, MRT3)
//              advances each agent's 3D position by sampling the input volume for
//              flow direction; MRT writes outState1/2/3.
//   2. diffuse (program "diffuse", fullscreen over the volume ATLAS)
//              decays the trail volume by persistence (intensity/100).
//   3. copy    (program "copy",    fullscreen over the volume ATLAS)
//              blits the decayed trail to the write buffer before deposit so
//              hardware blending lands on the decayed content after ping-pong.
//   4. deposit (program "deposit", POINTS scatter, Blend One One additive)
//              one point per agent (count=262144); the VERTEX stage Loads agent
//              3D position from state1, maps it to a 2D atlas NDC, scatters color.
//   5. blend   (program "blend",   fullscreen over the volume ATLAS)
//              combines the input volume (inputTex3d) with the trail volume into
//              the blended output volume (outputTex3d).
//
// VOLUME ATLAS MODEL: this effect's volumes are NOT the shared 64x4096 vol0..7;
// they are PRIVATE 'global_' atlas surfaces sized (volumeSize) x (volumeSize^2),
// rgba16f. A 2D atlas texel (u,v) maps to voxel (x,y,z) by:
//   x = u ;  y = v % volSize ;  z = v / volSize     (atlas height = volSize slices)
// i.e. atlasY = y_voxel + z_voxel * volSize  (deposit/agent), reproduced exactly.
// The geoBuffer (xyz=normal, w=depth) is declared but written by a DOWNSTREAM
// render3d/renderLit3d raymarch, not here (flow3d only writes the blended volume).
//
// PERSISTENT STATE TEXTURES (survive frame-to-frame; runtime ping-pongs them):
//   global_flow3d_state1 (rgba16f, 512x512) — [x, y, z, rotRand]  3D pos + rot rand
//   global_flow3d_state2 (rgba16f, 512x512) — [r, g, b, seed]     color + seed
//   global_flow3d_state3 (rgba16f, 512x512) — [age, initialized, theta, phi]
//     All three are isStateSurface=true (name contains 'state') → end-of-frame
//     bindings persist with NO swap; the agent pass updates them in place via MRT.
//   global_flow3d_trail   (rgba16f, atlas) — accumulated agent trail volume.
//     PERSISTENT feedback surface: decayed by diffuse, copied by copy, additively
//     deposited into by deposit (Blend One One), read by blend. Reads its own
//     prior 'global_' output so it persists (runtime double-buffers; ref 04
//     §10.2/§10.7). NOT an isStateSurface (no _xyz/_vel/_rgba suffix, no 'state').
//   global_flow3d_blended (rgba16f, atlas) — output volume (outputTex3d).
//
// NOTE: multi-pass / agent / 3D effect → ships as a runtime-rendered Texture2D
// volume atlas. NO Shader Graph Custom Function wrapper (PORTING-GUIDE: 3D /
// multi-pass / geometry effects are runtime-driven). The C# runtime drives the
// 5 passes in order, rebinding read/write targets, and issues
// DrawProcedural(Points, 262144) for the deposit scatter.
//
// PORTING-GUIDE / parity notes:
//  * WGSL textureLoad(t, coord, 0) → t.Load(int3(coord, 0)) — integer texel
//    fetch, point, no filtering. Agent state reads, atlas trilinear taps, the
//    diffuse/copy/blend body, and the deposit vertex reads all use this. The
//    volume "trilinear" sampleVolume is a MANUAL 8-tap Load+lerp (NOT a hardware
//    Sample), reproduced verbatim so the atlas (u,v)->(x,y,z) mapping is exact.
//  * This effect uses NO hardware texture Sample anywhere (all integer Loads).
//  * fragCoord = @builtin(position).xy (top-left, +0.5 centered) → NM_FragCoord(i).
//    The agent pass runs fullscreen OVER THE STATE texture; the diffuse/copy/
//    deposit/blend passes run over the volume ATLAS. _NM_Resolution == the bound
//    target size for that pass, so coord = (int2)NM_FragCoord(i) == WGSL
//    vec2<i32>(position.xy) exactly (house convention; see Physarum/NavierStokes).
//  * fract→frac, mix→lerp, clamp/cos/sin/acos/length/floor map 1:1. nm_mod/fmod
//    NOT used here — wrapping is the verbatim wrap_float helper (floor-based).
//  * hash divisor is 4294967295.0 (= float(0xffffffffu)), NOT 2^32.
//  * float→u32 in WGSL u32(flow_x*10.0 + ...) is a NUMERIC truncation → (uint)f.
//  * This effect's PRNG is its OWN hash_uint/hash/hash3 (PCG-style), ported
//    verbatim inline. It DIFFERS from NMCore's pcg/prng/random — do NOT
//    substitute. No NMCore helpers are used by this effect.
//  * BEHAVIOR was a compile-time #define in the reference (computeRotationBias
//    dispatch). Per PORTING-GUIDE we declare it as an int uniform and branch at
//    runtime with [branch] (same as the WGSL const-fold path; keeps all variants).
//  * `time` in agent.wgsl is bound as a per-pass uniform (binding 7); it is the
//    engine global normalized time → use NMFullscreen's `time` alias.
//  * D3D points are 1px, matching the reference gl_PointSize=1 / WGSL implicit
//    1px deposit. The deposit vertex Loads agent state in the VERTEX stage (SM4.5).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Textures (runtime rebinds per pass per definition.js inputs{}) ---------
// agent:   stateTex1,stateTex2,stateTex3 (Load); mixerTex==inputTex3d (Load via
//          sampleVolume); inputGeoTex==inputGeo (declared, unused in body).
// diffuse: sourceTex == global_flow3d_trail (Load).
// copy:    sourceTex == global_flow3d_trail (Load).
// deposit: stateTex1,stateTex2 (Load, in VERTEX stage).
// blend:   mixerTex==inputTex3d (Load), trailTex==global_flow3d_trail (Load).
Texture2D stateTex1;    SamplerState sampler_stateTex1;
Texture2D stateTex2;    SamplerState sampler_stateTex2;
Texture2D stateTex3;    SamplerState sampler_stateTex3;
Texture2D mixerTex;     SamplerState sampler_mixerTex;
Texture2D inputGeoTex;  SamplerState sampler_inputGeoTex;
Texture2D sourceTex;    SamplerState sampler_sourceTex;
Texture2D trailTex;     SamplerState sampler_trailTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
int   BEHAVIOR;          // globals.behavior  default 1 (obedient). Was #define; now int uniform.
float density;           // globals.density           default 20
float stride;            // globals.stride            default 1
float strideDeviation;   // globals.strideDeviation   default 0.05
float kink;              // globals.kink              default 1
float intensity;         // globals.intensity         default 90 (trail persistence)
float inputIntensity;    // globals.inputIntensity    default 50 (input mix)
float lifetime;          // globals.lifetime          default 30
int   volumeSize;        // globals.volumeSize        default 32

static const float FLOW3D_TAU         = 6.283185307179586;
static const float FLOW3D_PI          = 3.141592653589793;
static const float FLOW3D_RIGHT_ANGLE = 1.5707963267948966;

// =============================================================================
// Verbatim core helpers (this effect's OWN hashes / volume sampler — inline)
// =============================================================================
uint flow3d_hash_uint(uint seed)
{
    uint state = seed * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float flow3d_hash(uint seed)
{
    return (float)flow3d_hash_uint(seed) / 4294967295.0;
}

float3 flow3d_hash3(uint seed)
{
    return float3(flow3d_hash(seed), flow3d_hash(seed + 1u), flow3d_hash(seed + 2u));
}

float flow3d_wrap_float(float value, float size)
{
    if (size <= 0.0) { return 0.0; }
    float scaled = floor(value / size);
    float wrapped = value - scaled * size;
    if (wrapped < 0.0) { wrapped = wrapped + size; }
    return wrapped;
}

int flow3d_wrap_int(int value, int size)
{
    if (size <= 0) { return 0; }
    int result = value % size;
    if (result < 0) { result = result + size; }
    return result;
}

// Convert 3D voxel coord to 2D atlas texel coord (atlasY = y + z*volSize).
int2 flow3d_atlasTexel(int3 p, int volSize)
{
    int3 clamped = clamp(p, int3(0, 0, 0), int3(volSize - 1, volSize - 1, volSize - 1));
    return int2(clamped.x, clamped.y + clamped.z * volSize);
}

// Manual trilinear sample of the input volume atlas (8 Loads + lerps). The
// atlas is bound as mixerTex (inputTex3d). textureLoad → .Load(int3(coord,0)).
float4 flow3d_sampleVolume(float3 pos, int volSize)
{
    float volSizeF = (float)volSize;
    float3 texelPos = clamp(pos, float3(0.0, 0.0, 0.0), float3(volSizeF - 1.0, volSizeF - 1.0, volSizeF - 1.0));
    float3 texelFloor = floor(texelPos);
    float3 fr = texelPos - texelFloor;

    int3 i0 = int3(texelFloor);
    int3 i1 = min(i0 + int3(1, 1, 1), int3(volSize - 1, volSize - 1, volSize - 1));

    float4 c000 = mixerTex.Load(int3(flow3d_atlasTexel(int3(i0.x, i0.y, i0.z), volSize), 0));
    float4 c100 = mixerTex.Load(int3(flow3d_atlasTexel(int3(i1.x, i0.y, i0.z), volSize), 0));
    float4 c010 = mixerTex.Load(int3(flow3d_atlasTexel(int3(i0.x, i1.y, i0.z), volSize), 0));
    float4 c110 = mixerTex.Load(int3(flow3d_atlasTexel(int3(i1.x, i1.y, i0.z), volSize), 0));
    float4 c001 = mixerTex.Load(int3(flow3d_atlasTexel(int3(i0.x, i0.y, i1.z), volSize), 0));
    float4 c101 = mixerTex.Load(int3(flow3d_atlasTexel(int3(i1.x, i0.y, i1.z), volSize), 0));
    float4 c011 = mixerTex.Load(int3(flow3d_atlasTexel(int3(i0.x, i1.y, i1.z), volSize), 0));
    float4 c111 = mixerTex.Load(int3(flow3d_atlasTexel(int3(i1.x, i1.y, i1.z), volSize), 0));

    float4 c00 = lerp(c000, c100, fr.x);
    float4 c10 = lerp(c010, c110, fr.x);
    float4 c01 = lerp(c001, c101, fr.x);
    float4 c11 = lerp(c011, c111, fr.x);

    float4 c0 = lerp(c00, c10, fr.y);
    float4 c1 = lerp(c01, c11, fr.y);

    return lerp(c0, c1, fr.z);
}

float3 flow3d_getFallbackColor(float3 pos, uint seed)
{
    float3 col = flow3d_hash3(seed + (uint)(pos.x * 10.0 + pos.y * 100.0 + pos.z * 1000.0));
    col = col * 0.5 + 0.25 + flow3d_hash3(seed) * 0.25;
    return clamp(col, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

float flow3d_srgb_to_linear(float value)
{
    if (value <= 0.04045) { return value / 12.92; }
    return pow((value + 0.055) / 1.055, 2.4);
}

float flow3d_cube_root(float value)
{
    if (value == 0.0) { return 0.0; }
    float sign_value = (value >= 0.0) ? 1.0 : -1.0;
    return sign_value * pow(abs(value), 1.0 / 3.0);
}

float flow3d_oklab_l(float3 rgb)
{
    float r_lin = flow3d_srgb_to_linear(clamp(rgb.x, 0.0, 1.0));
    float g_lin = flow3d_srgb_to_linear(clamp(rgb.y, 0.0, 1.0));
    float b_lin = flow3d_srgb_to_linear(clamp(rgb.z, 0.0, 1.0));
    float l = 0.4121656120 * r_lin + 0.5362752080 * g_lin + 0.0514575653 * b_lin;
    float m = 0.2118591070 * r_lin + 0.6807189584 * g_lin + 0.1074065790 * b_lin;
    float s = 0.0883097947 * r_lin + 0.2818474174 * g_lin + 0.6302613616 * b_lin;
    return 0.2104542553 * flow3d_cube_root(l) + 0.7936177850 * flow3d_cube_root(m) - 0.0040720468 * flow3d_cube_root(s);
}

float flow3d_normalized_sine(float value)
{
    return (sin(value) + 1.0) * 0.5;
}

// 7-way behavior dispatch. WGSL used the BEHAVIOR const; here it is an int
// uniform and we [branch] at runtime (PORTING-GUIDE: define→int uniform).
float flow3d_computeRotationBias(float baseHeading, float baseRotRand, float timeV, int agentIndex, int totalAgents)
{
    [branch]
    if (BEHAVIOR <= 0)
    {
        return 0.0;
    }
    else if (BEHAVIOR == 1)
    {
        return baseHeading;
    }
    else if (BEHAVIOR == 2)
    {
        // Crosshatch: 4 cardinal directions (PI/2 spacing).
        return baseHeading + floor(baseRotRand * 4.0) * FLOW3D_RIGHT_ANGLE;
    }
    else if (BEHAVIOR == 3)
    {
        return baseHeading + (baseRotRand - 0.5) * 0.25;
    }
    else if (BEHAVIOR == 4)
    {
        return baseRotRand * FLOW3D_TAU;
    }
    else if (BEHAVIOR == 5)
    {
        int quarterSize = max(1, totalAgents / 4);
        int band = agentIndex / quarterSize;
        if (band <= 0)
        {
            return baseHeading;
        }
        else if (band == 1)
        {
            return baseHeading + floor(baseRotRand * 4.0) * FLOW3D_RIGHT_ANGLE;
        }
        else if (band == 2)
        {
            return baseHeading + (baseRotRand - 0.5) * 0.25;
        }
        else
        {
            return baseRotRand * FLOW3D_TAU;
        }
    }
    else if (BEHAVIOR == 10)
    {
        return flow3d_normalized_sine((timeV - baseRotRand) * FLOW3D_TAU);
    }
    else
    {
        return baseRotRand * FLOW3D_TAU;
    }
}

// =============================================================================
// PASS 1: agent — 3D GPGPU agent simulation. MRT x3 (frag_agent, fullscreen).
//   SV_Target0 = outState1, SV_Target1 = outState2, SV_Target2 = outState3
//   (matches drawBuffers:3, outputs{ outState1, outState2, outState3 }).
//   Runs over the 512x512 state grid (_NM_Resolution == state size for this pass).
// =============================================================================
struct Flow3dAgentOutputs
{
    float4 outState1 : SV_Target0;
    float4 outState2 : SV_Target1;
    float4 outState3 : SV_Target2;
};

Flow3dAgentOutputs frag_agent(NMVaryings i)
{
    Flow3dAgentOutputs o;

    int2 coord = (int2)NM_FragCoord(i);

    // Use actual state texture size, not canvas resolution. WGSL:
    // textureDimensions(stateTex1, 0).
    uint sw, sh;
    stateTex1.GetDimensions(sw, sh);
    int width = (int)sw;
    int height = (int)sh;

    int volSize = volumeSize;
    float volSizeF = (float)volSize;

    float4 state1 = stateTex1.Load(int3(coord, 0));
    float4 state2 = stateTex2.Load(int3(coord, 0));
    float4 state3 = stateTex3.Load(int3(coord, 0));

    float flow_x = state1.x;
    float flow_y = state1.y;
    float flow_z = state1.z;
    float rotRand = state1.w;
    float cr = state2.x;
    float cg = state2.y;
    float cb = state2.z;
    float seed_f = state2.w;
    float age = state3.x;
    float initialized = state3.y;
    float theta = state3.z;
    float phi = state3.w;

    uint agentSeed = (uint)(coord.x + coord.y * width);
    uint baseSeed = agentSeed + (uint)(time * 1000.0);

    int totalAgents = width * height;
    int agentIndex = coord.x + coord.y * width;

    // Initialize agent if needed.
    if (initialized < 0.5)
    {
        float3 pos = flow3d_hash3(agentSeed);
        flow_x = pos.x * volSizeF;
        flow_y = pos.y * volSizeF;
        flow_z = pos.z * volSizeF;

        rotRand = flow3d_hash(agentSeed + 200u);
        theta = flow3d_hash(agentSeed + 300u) * FLOW3D_TAU;
        phi = acos(2.0 * flow3d_hash(agentSeed + 400u) - 1.0);

        float4 inputColor = flow3d_sampleVolume(float3(flow_x, flow_y, flow_z), volSize);

        if (length(inputColor.rgb) < 0.01)
        {
            float3 fallbackCol = flow3d_getFallbackColor(float3(flow_x, flow_y, flow_z), agentSeed);
            cr = fallbackCol.r;
            cg = fallbackCol.g;
            cb = fallbackCol.b;
        }
        else
        {
            cr = inputColor.r;
            cg = inputColor.g;
            cb = inputColor.b;
        }

        seed_f = (float)agentSeed;
        age = 0.0;
        initialized = 1.0;
    }

    // Check for respawn.
    float agentPhase = (float)agentIndex / (float)max(totalAgents, 1);
    float staggeredAge = age + agentPhase * lifetime;
    bool shouldRespawn = lifetime > 0.0 && staggeredAge >= lifetime;

    if (shouldRespawn)
    {
        float3 pos = flow3d_hash3(baseSeed);
        flow_x = pos.x * volSizeF;
        flow_y = pos.y * volSizeF;
        flow_z = pos.z * volSizeF;

        rotRand = flow3d_hash(baseSeed + 200u);
        theta = flow3d_hash(baseSeed + 300u) * FLOW3D_TAU;
        phi = acos(2.0 * flow3d_hash(baseSeed + 400u) - 1.0);

        float4 inputColor = flow3d_sampleVolume(float3(flow_x, flow_y, flow_z), volSize);

        if (length(inputColor.rgb) < 0.01)
        {
            float3 fallbackCol = flow3d_getFallbackColor(float3(flow_x, flow_y, flow_z), baseSeed);
            cr = fallbackCol.r;
            cg = fallbackCol.g;
            cb = fallbackCol.b;
        }
        else
        {
            cr = inputColor.r;
            cg = inputColor.g;
            cb = inputColor.b;
        }

        age = 0.0;
    }

    // Sample input for flow direction.
    float4 texel = flow3d_sampleVolume(float3(flow_x, flow_y, flow_z), volSize);

    float indexValue;
    if (length(texel.rgb) < 0.01)
    {
        indexValue = flow3d_hash((uint)(flow_x * 10.0 + flow_y * 100.0 + flow_z * 1000.0 + time * 10.0));
    }
    else
    {
        indexValue = flow3d_oklab_l(texel.rgb);
    }

    float baseHeading = flow3d_hash(0u) * FLOW3D_TAU;
    float rotationBias = flow3d_computeRotationBias(baseHeading, rotRand, time, agentIndex, totalAgents);

    theta = theta + indexValue * FLOW3D_TAU * kink * 0.1 + rotationBias * 0.1;
    phi = phi + (indexValue - 0.5) * FLOW3D_PI * kink * 0.1;
    phi = clamp(phi, 0.01, FLOW3D_PI - 0.01);

    float sinPhi = sin(phi);
    float cosPhi = cos(phi);
    float sinTheta = sin(theta);
    float cosTheta = cos(theta);

    float3 direction = float3(
        sinPhi * cosTheta,
        sinPhi * sinTheta,
        cosPhi
    );

    float scale = max(volSizeF / 64.0, 1.0);
    float strideRand = flow3d_hash(agentSeed + 500u) - 0.5;
    float devFactor = 1.0 + strideRand * 2.0 * strideDeviation;
    float actualStride = max(0.1, stride * scale * devFactor);

    float newX = flow_x + direction.x * actualStride;
    float newY = flow_y + direction.y * actualStride;
    float newZ = flow_z + direction.z * actualStride;

    newX = flow3d_wrap_float(newX, volSizeF);
    newY = flow3d_wrap_float(newY, volSizeF);
    newZ = flow3d_wrap_float(newZ, volSizeF);

    age = age + 0.016;

    o.outState1 = float4(newX, newY, newZ, rotRand);
    o.outState2 = float4(cr, cg, cb, seed_f);
    o.outState3 = float4(age, initialized, theta, phi);

    return o;
}

// =============================================================================
// PASS 2: diffuse — decay the 3D trail volume (frag_diffuse, fullscreen atlas).
//   WGSL: return textureLoad(sourceTex, coord, 0) * clamp(intensity/100, 0, 1).
// =============================================================================
float4 frag_diffuse(NMVaryings i) : SV_Target
{
    int2 coord = (int2)NM_FragCoord(i);

    // Sample the trail texture directly (no blur).
    float4 trailColor = sourceTex.Load(int3(coord, 0));

    // Apply intensity decay (persistence). intensity=100 → no decay; 0 → fade.
    float decay = clamp(intensity / 100.0, 0.0, 1.0);
    return trailColor * decay;
}

// =============================================================================
// PASS 3: copy — blit source to destination (ping-pong correction after diffuse).
//   WGSL: return textureLoad(sourceTex, coord, 0).
// =============================================================================
float4 frag_copy(NMVaryings i) : SV_Target
{
    int2 coord = (int2)NM_FragCoord(i);
    return sourceTex.Load(int3(coord, 0));
}

// =============================================================================
// PASS 4: deposit — POINTS scatter (Blend One One additive) into the trail atlas.
//
// Custom vertex stage: one point per agent (count = 262144, fixed in
// definition.js). The runtime issues DrawProcedural(Points, count). Reads agent
// state in the VERTEX stage via Texture2D.Load (SM4.5 permits VS texture Load).
// D3D points are 1px, matching the reference gl_PointSize=1 / WGSL implicit 1px.
//
// Ported verbatim from deposit.wgsl (and deposit.vert): maps the agent's 3D
// position to a 2D atlas position (atlasY = y + floor(z)*volSize), then to NDC
// (no Y flip per golden rule #1). Off-screen cull writes position (2,2,0,1).
// =============================================================================
struct Flow3dDepositVaryings
{
    float4 positionCS : SV_POSITION;
    float4 color      : TEXCOORD0;
};

Flow3dDepositVaryings vert_deposit(uint vertexID : SV_VertexID)
{
    Flow3dDepositVaryings o;

    int agentIndex = (int)vertexID;

    // Use actual state texture size, not canvas resolution.
    uint sw, sh;
    stateTex1.GetDimensions(sw, sh);
    int texWidth = (int)sw;
    int texHeight = (int)sh;
    int volSize = volumeSize;
    float volSizeF = (float)volSize;

    // Calculate max agents based on density.
    int maxDim = max(texWidth, texHeight);
    int maxAgents = (int)((float)maxDim * density * 0.2);

    // Skip if beyond agent count.
    if (agentIndex >= maxAgents)
    {
        o.positionCS = float4(2.0, 2.0, 0.0, 1.0);
        o.color = float4(0.0, 0.0, 0.0, 0.0);
        return o;
    }

    // Map agent index to state texture coordinate.
    int stateTexWidth = texWidth;
    int stateX = agentIndex % stateTexWidth;
    int stateY = agentIndex / stateTexWidth;

    if (stateY >= texHeight)
    {
        o.positionCS = float4(2.0, 2.0, 0.0, 1.0);
        o.color = float4(0.0, 0.0, 0.0, 0.0);
        return o;
    }

    // Read agent state (3D position in state1.xyz).
    float4 state1 = stateTex1.Load(int3(int2(stateX, stateY), 0));
    float4 state2 = stateTex2.Load(int3(int2(stateX, stateY), 0));

    float x = state1.x;  // [0, volSize)
    float y = state1.y;  // [0, volSize)
    float z = state1.z;  // [0, volSize)

    // Convert 3D position to 2D atlas position.
    // Atlas layout: width = volSize, height = volSize * volSize.
    // y_atlas = y_voxel + z_voxel * volSize.
    float atlasX = x;
    float atlasY = y + floor(z) * volSizeF;

    // Convert to normalized device coordinates.
    float atlasWidth = volSizeF;
    float atlasHeight = volSizeF * volSizeF;

    float2 ndc = float2(
        (atlasX / atlasWidth) * 2.0 - 1.0,
        (atlasY / atlasHeight) * 2.0 - 1.0
    );

    o.positionCS = float4(ndc, 0.0, 1.0);
    o.color = float4(state2.rgb, 1.0);

    return o;
}

float4 frag_deposit(Flow3dDepositVaryings i) : SV_Target
{
    return i.color;
}

// =============================================================================
// PASS 5: blend — combine input volume with trail volume (frag_blend, atlas).
//   Both mixerTex (inputTex3d) and trailTex are 2D atlas representations of 3D
//   volumes (width=volumeSize, height=volumeSize^2). WGSL reads with integer
//   coords directly (textureLoad).
// =============================================================================
float4 frag_blend(NMVaryings i) : SV_Target
{
    int2 coord = (int2)NM_FragCoord(i);

    // Both textures are 3D atlas format, sample directly with integer coords.
    float inputIntensityValue = inputIntensity / 100.0;
    float4 baseSample = mixerTex.Load(int3(coord, 0));
    float4 baseColor = float4(baseSample.rgb * inputIntensityValue, baseSample.a);

    float4 trailColor = trailTex.Load(int3(coord, 0));

    // Combine: add trail on top of input (same as 2D flow).
    float3 combinedRgb = clamp(baseColor.rgb + trailColor.rgb, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
    float finalAlpha = clamp(max(baseColor.a, trailColor.a), 0.0, 1.0);

    return float4(combinedRgb, finalAlpha);
}

#endif // NM_EFFECT_FLOW3D_INCLUDED
