#ifndef NM_EFFECT_LIFE_INCLUDED
#define NM_EFFECT_LIFE_INCLUDED

// =============================================================================
// Life.hlsl — points/life (func: "life")
//
// Particle-Life: type-based attraction/repulsion particle simulation.
// Ported PIXEL-IDENTICALLY from the canonical WGSL sources (top-left origin,
// no per-effect Y flip):
//   wgsl/matrix.wgsl       progName "matrix"       (frag_matrix)
//   wgsl/agent.wgsl        progName "agent"        (frag_agent)   MRT drawBuffers:4
//   wgsl/passthrough.wgsl  progName "passthrough"  (frag_passthrough)
//
// MULTI-PASS / AGENT-BASED MIDDLEWARE: 3 passes per frame in definition order:
//   1. matrix  (fullscreen) — generates the 8x8 forceMatrix from matrixSeed.
//   2. agent   (fullscreen, MRT 4 outputs) — reads agent state from the
//      PERSISTENT particle surfaces global_xyz/global_vel/global_rgba and the
//      internal global_life_data, evaluates inter-particle forces via a spatial
//      grid + the forceMatrix, integrates, and writes all 4 state textures back
//      (MRT: location0=xyz, location1=vel, location2=rgba, location3=data).
//   3. passthrough (fullscreen) — copies inputTex -> outputTex for 2D chain
//      continuity (the downstream pointsRender effect does the points scatter).
//
// NOTE: This effect has NO deposit / drawMode:"points" pass. It is agent-update
// MIDDLEWARE (per CLAUDE.md's Agent-Based Effects Pattern, the deposit/diffuse/
// blend stages live in the separate points/pointsRender effect, which consumes
// the global_xyz/global_vel/global_rgba surfaces this effect updates). All three
// passes here are fullscreen (#pragma vertex NMVertFullscreen). No custom
// scatter vertex is required for this effect.
//
// STATE / FEEDBACK: the particle state lives in PERSISTENT 'global_'-prefixed
// surfaces that survive frame-to-frame and are double-buffered/ping-ponged by
// the runtime (reference 04 §10.2/§10.7, isStateSurface matches xyz|vel|rgba).
//   global_xyz       : [x, y, 0, alive]        normalized coords [0,1]
//   global_vel       : [vx, vy, age, seed]
//   global_rgba      : [r, g, b, a]            agent color
//   global_life_data : [typeId, mass, 0, 0]    internal; rgba16f per reference
// The agent pass reads and writes all four in one MRT pass; the runtime resolves
// each global to its current read/write buffer so the read/write aliasing is
// avoided (definition.js notes global_life_data uses the global_ prefix
// specifically to get double-buffered ping-pong).
//
// MULTI-PASS effect → ships as a runtime-rendered Texture2D. No Shader Graph
// Custom Function wrapper is provided (the C# runtime drives the 3 passes in
// order, rebinding the global_xyz/vel/rgba/life_data + forceMatrix read/write
// targets per pass). (Per PORTING-GUIDE step 4 / task: SKIP the Shader Graph
// wrapper — multi-pass/agent.)
//
// PORTING-GUIDE / parity notes:
//  * WGSL textureLoad(t, coord, 0) → t.Load(int3(coord, 0)) (integer texel
//    fetch, point, no filtering). State (rgba32f surfaces) + forceMatrix
//    (rgba16f) are read this way. matrix.wgsl reads no textures.
//  * WGSL textureSampleLevel(t, s, uv, 0) → t.SampleLevel(sampler_t, uv, 0)
//    (linear, clamp-to-edge, non-sRGB). Used only by passthrough.
//  * fragCoord = pos.xy (@builtin(position), top-left, +0.5 centered) →
//    NM_FragCoord(i). agent/matrix use coord = int2(fragCoord) (WGSL
//    vec2i(position.xy) truncates the +0.5-centered coord to the integer texel,
//    matching the integer texel index). passthrough uses uv = pos.xy / resolution.
//  * vec2<i32>(textureDimensions(t,0)) → GetDimensions(w,h); int2((int)w,(int)h).
//  * Hash: this effect ships its OWN PCG-variant hash (hash_uint/hash/hash2) that
//    DIFFERS from NMCore nm_pcg/nm_random; it is inlined verbatim per the rule.
//  * GLSL mod(h, 2.0) in typeColor == WGSL h % 2.0 == HLSL nm_mod(h, 2.0) (the
//    only NMCore helper used; nm_mod, never fmod — H6). All other helpers inline.
//  * WGSL `%` on f32 in wrapPosition (`pos % 1.0`) is float remainder → nm_mod.
//    WGSL `%` on i32 (cell wrap `(checkCell + GRID_SIZE) % GRID_SIZE`, sampleIdx
//    `% stateSize.x`, etc.) is integer trunc-toward-zero → HLSL `%` (operands are
//    made non-negative first by `+ GRID_SIZE`, matching the source).
//  * u32(f) numeric truncation (e.g. u32(u.time*1000.0)) → (uint)f (truncation,
//    NOT asuint — H). i32(f) → (int)f truncation. f32(u) → (float)u.
//  * uint wraparound arithmetic (seed*747796405u + ...) matches HLSL uint mod 2^32.
//  * PCG divisor 4294967295.0 reproduced literally (H11).
//  * atan2 / select are not used by this effect.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input samplers (runtime rebinds per pass per definition.js inputs{}) ----
// matrix:      (no inputs)
// agent:       xyzTex, velTex, rgbaTex, dataTex (Load); forceMatrix (Load);
//              inputTex (Load)
// passthrough: inputTex (Sample)
Texture2D    xyzTex;        SamplerState sampler_xyzTex;
Texture2D    velTex;        SamplerState sampler_velTex;
Texture2D    rgbaTex;       SamplerState sampler_rgbaTex;
Texture2D    dataTex;       SamplerState sampler_dataTex;
Texture2D    forceMatrix;   SamplerState sampler_forceMatrix;
Texture2D    inputTex;      SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -------
// Booleans are bound as int 1/0 and tested != 0 exactly as the GLSL/WGSL do.
int   typeCount;        // globals.typeCount        default 6
float attractionScale;  // globals.attractionScale  default 1.0
float repulsionScale;   // globals.repulsionScale   default 1.0
float minRadius;        // globals.minRadius        default 0.01
float maxRadius;        // globals.maxRadius        default 0.08
float maxSpeed;         // globals.maxSpeed         default 0.003
float friction;         // globals.friction         default 0.1
int   boundaryMode;     // globals.boundaryMode     default 0 (wrap)
float matrixSeed;       // globals.matrixSeed       default 42
int   symmetricForces;  // globals.symmetricForces  boolean (1/0)
int   useTypeColor;     // globals.useTypeColor     boolean (1/0)

// =============================================================================
// SHARED HASH (effect-specific PCG variant — verbatim, NOT NMCore)
// Used by both the matrix and agent passes.
// =============================================================================
uint life_hash_uint(uint seed)
{
    uint state = seed * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float life_hash(uint seed)
{
    return (float)life_hash_uint(seed) / 4294967295.0;
}

float2 life_hash2(uint seed)
{
    return float2(life_hash(seed), life_hash(seed + 1u));
}

// =============================================================================
// PASS: matrix — ForceMatrix generator (frag_matrix)
// Output pixel [typeA, typeB] = [strength, prefDist, curveShape, 1].
// =============================================================================
float4 frag_matrix(NMVaryings i) : SV_Target
{
    int2 coord = (int2)NM_FragCoord(i);   // vec2i(position.xy): truncate centered coord
    int typeA = coord.x;
    int typeB = coord.y;

    // Skip if outside active types
    if (typeA >= typeCount || typeB >= typeCount)
    {
        return float4(0.0, 0.0, 0.0, 0.0);
    }

    // Generate deterministic random based on seed and type pair
    uint seed = (uint)(matrixSeed * 1000.0) + (uint)(typeA * 31 + typeB * 17);

    // For symmetric forces, use canonical ordering
    if (symmetricForces != 0 && typeB < typeA)
    {
        seed = (uint)(matrixSeed * 1000.0) + (uint)(typeB * 31 + typeA * 17);
    }

    // Same type always has mild repulsion
    float strength;
    if (typeA == typeB)
    {
        strength = -0.3 - life_hash(seed) * 0.4;
    }
    else
    {
        strength = life_hash(seed) * 2.0 - 1.0;
    }

    // Preferred distance (normalized)
    float prefDist = 0.3 + life_hash(seed + 1u) * 0.5;

    // Curve shape
    float curveShape = life_hash(seed + 2u);

    return float4(strength, prefDist, curveShape, 1.0);
}

// =============================================================================
// PASS: agent — combined force evaluation + integration (frag_agent)
// MRT: 4 outputs (drawBuffers:4). location0=xyz, 1=vel, 2=rgba, 3=data.
// =============================================================================

// Type colors (rainbow palette) — verbatim. GLSL mod(h,2.0) == nm_mod(h,2.0).
float3 life_typeColor(int typeId, int totalTypes)
{
    float hue = (float)typeId / (float)totalTypes;
    float h = hue * 6.0;
    float c = 1.0;
    float x = c * (1.0 - abs(nm_mod(h, 2.0) - 1.0));
    float3 rgb;
    if (h < 1.0) { rgb = float3(c, x, 0.0); }
    else if (h < 2.0) { rgb = float3(x, c, 0.0); }
    else if (h < 3.0) { rgb = float3(0.0, c, x); }
    else if (h < 4.0) { rgb = float3(0.0, x, c); }
    else if (h < 5.0) { rgb = float3(x, 0.0, c); }
    else { rgb = float3(c, 0.0, x); }
    return rgb;
}

// === SPATIAL GRID ===
static const int LIFE_GRID_SIZE = 16;

int2 life_getGridCell(float2 pos)
{
    float2 cellSize = float2(1.0, 1.0) / (float)LIFE_GRID_SIZE;
    return (int2)clamp(pos / cellSize, float2(0.0, 0.0), float2((float)(LIFE_GRID_SIZE - 1), (float)(LIFE_GRID_SIZE - 1)));
}

// === FORCE FUNCTIONS ===
float life_radialForce(float dist, float strength, float prefDist, float curveShape)
{
    float normDist = (dist - minRadius) / (maxRadius - minRadius);

    // Scale forces to velocity space
    float forceScale = maxSpeed * 10.0;

    if (normDist < 0.0)
    {
        // Inside minRadius: hard repulsion
        return -repulsionScale * (1.0 - dist / minRadius) * forceScale;
    }

    if (normDist > 1.0)
    {
        // Outside maxRadius: no force
        return 0.0;
    }

    // In the interaction band: apply force curve
    float force;
    if (normDist < prefDist)
    {
        force = strength * (normDist / prefDist);
    }
    else
    {
        force = strength * (1.0 - (normDist - prefDist) / (1.0 - prefDist));
    }

    // Apply curve shape
    float shaped = sign(force) * pow(abs(force), 1.0 - curveShape * 0.5);

    // Scale by attraction/repulsion multipliers and forceScale
    if (shaped > 0.0)
    {
        return shaped * attractionScale * forceScale;
    }
    else
    {
        return shaped * repulsionScale * forceScale;
    }
}

// === VECTOR HELPERS ===
// WGSL `(pos % 1.0 + 1.0) % 1.0` is float remainder; nm_mod reproduces it
// (and additionally matches the GLSL `mod(pos + 1.0, 1.0)` exactly).
float2 life_wrapPosition(float2 pos)
{
    return nm_mod(nm_mod(pos, float2(1.0, 1.0)) + float2(1.0, 1.0), float2(1.0, 1.0));
}

float2 life_limitVec(float2 v, float maxLen)
{
    float len = length(v);
    if (len > maxLen && len > 0.0)
    {
        return v * (maxLen / len);
    }
    return v;
}

struct LifeAgentOutputs
{
    float4 xyz  : SV_Target0;
    float4 vel  : SV_Target1;
    float4 rgba : SV_Target2;
    float4 data : SV_Target3;
};

LifeAgentOutputs frag_agent(NMVaryings i)
{
    int2 coord = (int2)NM_FragCoord(i);   // vec2i(position.xy)
    uint sw, sh;
    xyzTex.GetDimensions(sw, sh);
    int2 stateSize = int2((int)sw, (int)sh);

    // Read input state from pipeline (point fetch on integer texels)
    float4 xyz  = xyzTex.Load(int3(coord, 0));
    float4 vel  = velTex.Load(int3(coord, 0));
    float4 rgba = rgbaTex.Load(int3(coord, 0));
    float4 data = dataTex.Load(int3(coord, 0));

    // Extract components (normalized coords [0,1])
    float px = xyz.x;
    float py = xyz.y;
    float alive = xyz.w;

    float vx = vel.x;
    float vy = vel.y;
    float age = vel.z;
    float seed = vel.w;

    float typeId = data.x;
    float mass = data.y;

    uint particleId = (uint)(coord.x + coord.y * stateSize.x);

    float2 pos = float2(px, py);
    float2 velocity = float2(vx, vy);

    LifeAgentOutputs OUT;

    // If not alive, pass through unchanged
    if (alive < 0.5)
    {
        OUT.xyz = xyz;
        OUT.vel = vel;
        OUT.rgba = rgba;
        OUT.data = data;
        return OUT;
    }

    // Initialize data on first use (typeId=0 and mass=0 means uninitialized)
    if (typeId == 0.0 && mass == 0.0)
    {
        uint initSeed = particleId + (uint)(time * 1000.0);
        typeId = floor(life_hash(initSeed + 4u) * (float)typeCount);
        mass = 0.8 + life_hash(initSeed + 5u) * 0.4;

        // Initialize velocity if zero
        if (length(velocity) == 0.0)
        {
            float angle = life_hash(initSeed + 2u) * 6.28318530718;
            float speed = life_hash(initSeed + 3u) * maxSpeed * 0.3;
            velocity = float2(cos(angle), sin(angle)) * speed;
        }
    }

    // Ensure mass is valid
    mass = max(mass, 0.1);

    // Set color based on type (matches WGSL: rgba is recomputed before forces;
    // the GLSL writes it only at output, but the value is identical for the
    // useTypeColor path; the non-typeColor path overrides it below either way).
    rgba = float4(life_typeColor((int)typeId, typeCount), 1.0);

    // Attrition is now handled by pointsEmit

    // === FORCE EVALUATION ===
    float2 totalForce = float2(0.0, 0.0);
    int neighborCount = 0;
    int myType = (int)typeId;

    int2 myCell = life_getGridCell(pos);
    int totalParticles = stateSize.x * stateSize.y;

    // Sample neighbors using spatial grid
    for (int dy = -1; dy <= 1; dy++)
    {
        for (int dx = -1; dx <= 1; dx++)
        {
            int2 checkCell = myCell + int2(dx, dy);

            // Wrap cell coordinates (operands made non-negative first → HLSL %)
            checkCell = (checkCell + LIFE_GRID_SIZE) % LIFE_GRID_SIZE;

            uint cellSeed = (uint)(checkCell.y * LIFE_GRID_SIZE + checkCell.x);

            // Sample particles from this cell
            for (int s = 0; s < 12; s++)
            {
                uint sampleSeed = cellSeed * 31u + (uint)s + (uint)(time * 7.0);
                int sampleIdx = (int)(life_hash_uint(sampleSeed) % (uint)totalParticles);

                int sx = sampleIdx % stateSize.x;
                int sy = sampleIdx / stateSize.x;

                // Skip self
                if (sx == coord.x && sy == coord.y)
                {
                    continue;
                }

                // Read neighbor state
                float4 otherXyz = xyzTex.Load(int3(int2(sx, sy), 0));
                float4 otherData = dataTex.Load(int3(int2(sx, sy), 0));

                float2 otherPos = otherXyz.xy;
                float otherAlive = otherXyz.w;
                int otherType = (int)otherData.x;

                // Skip dead or uninitialized
                if (otherAlive < 0.5)
                {
                    continue;
                }

                // Calculate distance with wrapping (toroidal)
                float2 diff = otherPos - pos;

                if (diff.x > 0.5) { diff.x -= 1.0; }
                if (diff.x < -0.5) { diff.x += 1.0; }
                if (diff.y > 0.5) { diff.y -= 1.0; }
                if (diff.y < -0.5) { diff.y += 1.0; }

                float dist = length(diff);

                // Skip if outside max interaction range
                if (dist < 0.0001 || dist > maxRadius)
                {
                    continue;
                }

                // Look up force parameters from ForceMatrix
                float4 forceParams = forceMatrix.Load(int3(int2(myType, otherType), 0));
                float strength = forceParams.x;
                float prefDist = forceParams.y;
                float curveShape = forceParams.z;

                // Calculate force magnitude
                float forceMag = life_radialForce(dist, strength, prefDist, curveShape);

                // Convert to force vector
                float2 forceDir = diff / dist;
                totalForce += forceDir * forceMag;
                neighborCount++;
            }
        }
    }

    // Normalize by mass
    totalForce /= mass;

    // === INTEGRATION ===

    // Apply forces
    velocity += totalForce;

    // Apply friction/damping
    velocity *= (1.0 - friction);

    // Limit speed
    velocity = life_limitVec(velocity, maxSpeed);

    // Update position
    pos += velocity;

    // Handle boundaries
    if (boundaryMode == 0)
    {
        // Wrap (toroidal)
        pos = life_wrapPosition(pos);
    }
    else
    {
        // Bounce
        if (pos.x < 0.0) { pos.x = -pos.x; velocity.x = -velocity.x; }
        if (pos.x > 1.0) { pos.x = 2.0 - pos.x; velocity.x = -velocity.x; }
        if (pos.y < 0.0) { pos.y = -pos.y; velocity.y = -velocity.y; }
        if (pos.y > 1.0) { pos.y = 2.0 - pos.y; velocity.y = -velocity.y; }
        pos = clamp(pos, float2(0.001, 0.001), float2(0.999, 0.999));
    }

    // Update age
    age += 0.016;

    float4 outColor = rgba;
    if (useTypeColor != 0)
    {
        outColor = float4(life_typeColor((int)typeId, typeCount), 1.0);
    }
    else
    {
        // Sample from input texture based on position (WGSL textureLoad path:
        // inputCoord = vec2i(pos * inputDims), point fetch on the input texture).
        uint iw, ih;
        inputTex.GetDimensions(iw, ih);
        float2 inputDims = float2((float)iw, (float)ih);
        int2 inputCoord = (int2)(pos * inputDims);
        outColor = inputTex.Load(int3(inputCoord, 0));
    }

    // Output updated state
    OUT.xyz  = float4(pos, 0.0, 1.0);
    OUT.vel  = float4(velocity, age, seed);
    OUT.rgba = outColor;
    OUT.data = float4(typeId, mass, 0.0, 1.0);
    return OUT;
}

// =============================================================================
// PASS: passthrough — copy inputTex -> output (frag_passthrough)
// =============================================================================
float4 frag_passthrough(NMVaryings i) : SV_Target
{
    // WGSL: uv = position.xy / u.resolution; textureSampleLevel(inputTex,...,0).
    float2 uv = NM_FragCoord(i) / resolution;
    return inputTex.SampleLevel(sampler_inputTex, uv, 0.0);
}

#endif // NM_EFFECT_LIFE_INCLUDED
