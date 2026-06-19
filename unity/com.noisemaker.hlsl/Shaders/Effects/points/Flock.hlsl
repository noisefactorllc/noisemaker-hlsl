#ifndef NM_EFFECT_FLOCK_INCLUDED
#define NM_EFFECT_FLOCK_INCLUDED

// =============================================================================
// Flock.hlsl — points/flock (func: "flock")
//
// 2D "Boids" flocking agent simulation. Common Agent Architecture middleware.
// Ported PIXEL-IDENTICALLY from the canonical WGSL sources (top-left origin,
// no per-effect Y flip):
//   wgsl/agent.wgsl        progName "agent"        (frag_agent)  MRT 3 outputs
//   wgsl/passthrough.wgsl  progName "passthrough"  (frag_passthrough)
//
// MULTI-PASS / AGENT STATE: 2 passes per frame in definition order:
//   1. "agent"       — fullscreen over the state texture. Reads the three
//                      PERSISTENT ('global_') particle-state textures
//                      global_xyz [x,y,z,alive], global_vel [vx,vy,age,seed],
//                      global_rgba [r,g,b,a], applies boids flocking
//                      (separation / alignment / cohesion + noise + boundary),
//                      and writes new state back via MRT (3 render targets:
//                      SV_Target0=xyz, SV_Target1=vel, SV_Target2=rgba). This is
//                      the WGSL @location(0/1/2) Outputs struct. drawBuffers:3.
//   2. "passthrough" — fullscreen blit of inputTex -> outputTex for 2D-chain
//                      continuity (the flock effect does not alter the visible
//                      color buffer; the upstream pointsEmit/downstream
//                      pointsRender handle scatter/render).
//
// IMPORTANT: flock has NO deposit (drawMode:"points") pass and NO diffuse pass.
// The points-scatter / deposit lives in the separate `pointsRender` effect, not
// here. So there is NO custom scatter vertex stage in this file — both passes
// are fullscreen and use NMVertFullscreen.
//
// STATE TEXTURES (persistence): global_xyz / global_vel / global_rgba are NOT
// declared by flock's own definition (its `textures` is {}). They are created
// upstream by pointsEmit and INHERITED through the particle pipeline. They are
// rgba32f (full float) persistent state surfaces, double-buffered/ping-ponged
// by the runtime (ref 04: isStateSurface matches the bare xyz|vel|rgba names →
// end-of-frame persistence, not display swap). The runtime rebinds each pass's
// input/output state textures and sets named uniforms via MaterialPropertyBlock
// by reference names. The same surface is both read (xyzTex/velTex/rgbaTex) and
// written (outXYZ/outVel/outRGBA) — the runtime ping-pongs read/write.
//
// NOTE: multi-pass / agent effect → ships as a runtime-rendered Texture2D. No
// Shader Graph Custom Function wrapper is provided (the C# runtime drives the 2
// passes and rebinds global_xyz/global_vel/global_rgba read/write targets).
//
// PORTING-GUIDE / parity notes:
//  * WGSL textureLoad(t, coord, 0) → t.Load(int3(coord, 0)) (integer texel
//    fetch, point, no filtering). rgba32f state is read this way.
//  * vec2i(fragCoord.xy) truncates → int2(NM_FragCoord(i)). vec2i(...) of a
//    float vector truncates toward zero; reproduced with (int2) casts.
//  * textureDimensions(xyzTex,0) → xyzTex.GetDimensions(w,h); int2((int)w,(int)h).
//  * WGSL `position %  bounds` (float modulo) → nm_mod (NEVER fmod). The WGSL
//    wrapPosition is `(position % bounds + bounds) % bounds`; the GLSL is
//    `mod(position + bounds, bounds)`. These are algebraically the SAME for the
//    operand ranges here; we port the WGSL form literally with nm_mod.
//  * `boundaryMode == 0` integer branch on an int uniform (truncated).
//  * `u32(time*10.0)` is a numeric truncation of a float to uint → (uint)(time*10.0).
//    `time` is the engine's normalized 0..1 animation time (NMFullscreen alias),
//    matching the WGSL Uniforms.time the reference binds here.
//  * PRNG is the effect's OWN integer hash (hash_uint / hash / noise2D via
//    hashFloat) — ported verbatim inline. NMCore's pcg/prng/random are NOT used.
//  * fract→frac, mix→lerp. PCG-style divisor is 4294967295.0 (matches reference).
//  * select / atan2 not used. No reassociation of the boids arithmetic.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input state samplers (rebound per pass per definition.js inputs{}) ------
// agent:       xyzTex, velTex, rgbaTex   (all Load — integer texel fetch)
// passthrough: inputTex                  (Sample — bilinear, clamp, non-sRGB)
Texture2D    xyzTex;     SamplerState sampler_xyzTex;
Texture2D    velTex;     SamplerState sampler_velTex;
Texture2D    rgbaTex;    SamplerState sampler_rgbaTex;
Texture2D    inputTex;   SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
float separation;        // default 2.0
float alignment;         // default 1.0
float cohesion;          // default 1.0
float perceptionRadius;  // default 50
float separationRadius;  // default 25
float maxSpeed;          // default 4.0
float maxForce;          // default 0.3
int   boundaryMode;      // default 0 (wrap), 1 = softWall
float wallMargin;        // default 50
float noiseWeight;       // default 0.1

// =============================================================================
// PASS: agent — boids flocking state update (frag_agent), MRT 3 outputs
// =============================================================================

// === ORIGINAL BOIDS HELPER FUNCTIONS (PRESERVED EXACTLY, ported verbatim) ====

uint flock_hash_uint(uint seed)
{
    uint state = seed * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float flock_hash(uint seed)
{
    return (float)flock_hash_uint(seed) / 4294967295.0;
}

float2 flock_hash2(uint seed)
{
    return float2(flock_hash(seed), flock_hash(seed + 1u));
}

float flock_hashFloat(float n)
{
    return frac(sin(n) * 43758.5453123);
}

float flock_noise2D(float2 p)
{
    float2 i = floor(p);
    float2 f = frac(p);
    float2 ff = f * f * (3.0 - 2.0 * f);
    float n = i.x + i.y * 57.0;
    return lerp(
        lerp(flock_hashFloat(n), flock_hashFloat(n + 1.0), ff.x),
        lerp(flock_hashFloat(n + 57.0), flock_hashFloat(n + 58.0), ff.x),
        ff.y
    ) * 2.0 - 1.0;
}

float2 flock_wrapPosition(float2 position, float2 bounds)
{
    // WGSL: (position % bounds + bounds) % bounds  (% is float modulo → nm_mod)
    return nm_mod(nm_mod(position, bounds) + bounds, bounds);
}

float2 flock_limitVec(float2 v, float maxLen)
{
    float len = length(v);
    if (len > maxLen && len > 0.0)
    {
        return v * (maxLen / len);
    }
    return v;
}

float2 flock_setMag(float2 v, float mag)
{
    float len = length(v);
    if (len > 0.0)
    {
        return v * (mag / len);
    }
    return v;
}

// Spatial grid parameters - 16x16 grid cells
static const int FLOCK_GRID_SIZE = 16;

int2 flock_getGridCell(float2 pos, float2 res)
{
    float2 cellSize = res / (float)FLOCK_GRID_SIZE;
    return (int2)clamp(pos / cellSize, float2(0.0, 0.0), float2((float)(FLOCK_GRID_SIZE - 1), (float)(FLOCK_GRID_SIZE - 1)));
}

// === END ORIGINAL HELPER FUNCTIONS ===

// MRT output struct — mirrors WGSL Outputs { @location(0) xyz, @location(1) vel,
// @location(2) rgba }. drawBuffers:3 in the definition binds these three render
// targets to outXYZ=global_xyz, outVel=global_vel, outRGBA=global_rgba.
struct FlockAgentOutputs
{
    float4 xyz  : SV_Target0;
    float4 vel  : SV_Target1;
    float4 rgba : SV_Target2;
};

FlockAgentOutputs frag_agent(NMVaryings i)
{
    int2 coord = (int2)NM_FragCoord(i);

    uint tw, th;
    xyzTex.GetDimensions(tw, th);
    int2 stateSize = int2((int)tw, (int)th);

    // Read input state from pipeline (rgba32f, point Load)
    float4 xyz  = xyzTex.Load(int3(coord, 0));
    float4 vel  = velTex.Load(int3(coord, 0));
    float4 rgba = rgbaTex.Load(int3(coord, 0));

    // Extract components
    float px = xyz.x;   // normalized x
    float py = xyz.y;   // normalized y
    float alive = xyz.w;

    // vel stores: [vx, vy, age, seed]
    float vx = vel.x;
    float vy = vel.y;
    float age = vel.z;
    float seed = vel.w;

    uint boidId = (uint)coord.x + (uint)coord.y * (uint)stateSize.x;

    // Convert normalized to pixel coords for the algorithm
    float2 pos = float2(px, py) * resolution;
    float2 velocity = float2(vx, vy);

    // If not alive, pass through unchanged
    if (alive < 0.5)
    {
        FlockAgentOutputs deadOut;
        deadOut.xyz  = xyz;
        deadOut.vel  = vel;
        deadOut.rgba = rgba;
        return deadOut;
    }

    // Initialize velocity on first use (if zero from pointsEmit)
    if (length(velocity) == 0.0 && seed == 0.0)
    {
        seed = flock_hash(boidId + 99999u);
        float angle = flock_hash(boidId + 12345u) * 6.28318530718;
        float speed = flock_hash(boidId + 23456u) * maxSpeed * 0.5 + maxSpeed * 0.25;
        velocity = float2(cos(angle), sin(angle)) * speed;
    }

    // Attrition is now handled by pointsEmit

    // === ORIGINAL BOIDS ALGORITHM (PRESERVED EXACTLY) ===

    float2 separationForce = float2(0.0, 0.0);
    float2 alignmentSum = float2(0.0, 0.0);
    float2 cohesionSum = float2(0.0, 0.0);
    int separationCount = 0;
    int alignmentCount = 0;
    int cohesionCount = 0;

    int2 myCell = flock_getGridCell(pos, resolution);
    float perceptionSq = perceptionRadius * perceptionRadius;
    float separationSq = separationRadius * separationRadius;

    int totalBoids = stateSize.x * stateSize.y;

    // Sample neighbors - iterate through nearby agents
    for (int dy = -1; dy <= 1; dy++)
    {
        for (int dx = -1; dx <= 1; dx++)
        {
            int2 checkCell = myCell + int2(dx, dy);

            if (boundaryMode == 0)
            {
                // Wrap mode: (checkCell + GRID_SIZE) % GRID_SIZE (integer % is fine,
                // operands non-negative after the + GRID_SIZE)
                checkCell = (checkCell + FLOCK_GRID_SIZE) % FLOCK_GRID_SIZE;
            }
            else
            {
                checkCell = clamp(checkCell, int2(0, 0), int2(FLOCK_GRID_SIZE - 1, FLOCK_GRID_SIZE - 1));
            }

            uint cellSeed = (uint)(checkCell.y * FLOCK_GRID_SIZE + checkCell.x);

            for (int s = 0; s < 8; s++)
            {
                uint sampleSeed = cellSeed * 31u + (uint)s + (uint)(time * 10.0);
                int sampleIdx = (int)(flock_hash_uint(sampleSeed) % (uint)totalBoids);

                int sx = sampleIdx % stateSize.x;
                int sy = sampleIdx / stateSize.x;

                // Skip self
                if (sx == coord.x && sy == coord.y) continue;

                float4 otherXyz = xyzTex.Load(int3(int2(sx, sy), 0));
                float4 otherVel = velTex.Load(int3(int2(sx, sy), 0));

                // Skip dead agents
                if (otherXyz.w < 0.5) continue;

                float2 otherPos = otherXyz.xy * resolution;
                float2 otherVelocity = otherVel.xy;

                // Calculate distance (with wrapping if needed)
                float2 diff = otherPos - pos;
                if (boundaryMode == 0)
                {
                    if (diff.x > resolution.x * 0.5) { diff.x -= resolution.x; }
                    if (diff.x < -resolution.x * 0.5) { diff.x += resolution.x; }
                    if (diff.y > resolution.y * 0.5) { diff.y -= resolution.y; }
                    if (diff.y < -resolution.y * 0.5) { diff.y += resolution.y; }
                }

                float distSq = dot(diff, diff);

                // Separation (close neighbors)
                if (distSq < separationSq && distSq > 0.0)
                {
                    float2 away = -diff;
                    float dist = sqrt(distSq);
                    separationForce += away / dist;
                    separationCount++;
                }

                // Alignment and Cohesion (perception radius)
                if (distSq < perceptionSq && distSq > 0.0)
                {
                    alignmentSum += otherVelocity;
                    alignmentCount++;

                    cohesionSum += otherPos;
                    cohesionCount++;
                }
            }
        }
    }

    // Calculate steering forces
    float2 steer = float2(0.0, 0.0);

    // Separation
    if (separationCount > 0)
    {
        float2 sepForce = separationForce / (float)separationCount;
        if (length(sepForce) > 0.0)
        {
            sepForce = flock_setMag(sepForce, maxSpeed);
            sepForce = sepForce - velocity;
            sepForce = flock_limitVec(sepForce, maxForce);
            steer += sepForce * separation;
        }
    }

    // Alignment
    if (alignmentCount > 0)
    {
        float2 avgVel = alignmentSum / (float)alignmentCount;
        if (length(avgVel) > 0.0)
        {
            avgVel = flock_setMag(avgVel, maxSpeed);
            float2 alignSteer = avgVel - velocity;
            alignSteer = flock_limitVec(alignSteer, maxForce);
            steer += alignSteer * alignment;
        }
    }

    // Cohesion
    if (cohesionCount > 0)
    {
        float2 avgPos = cohesionSum / (float)cohesionCount;
        float2 desired = avgPos - pos;
        if (length(desired) > 0.0)
        {
            desired = flock_setMag(desired, maxSpeed);
            float2 cohesionSteer = desired - velocity;
            cohesionSteer = flock_limitVec(cohesionSteer, maxForce);
            steer += cohesionSteer * cohesion;
        }
    }

    // Noise/turbulence
    if (noiseWeight > 0.0)
    {
        float noiseScale = 0.01;
        float nx = flock_noise2D(pos * noiseScale + time * 0.5);
        float ny = flock_noise2D(pos * noiseScale + float2(100.0, 100.0) + time * 0.5);
        float2 noiseForce = float2(nx, ny) * maxForce * noiseWeight;
        steer += noiseForce;
    }

    // Boundary handling
    if (boundaryMode == 1)
    {
        float2 wallForce = float2(0.0, 0.0);
        float turnStrength = maxForce * 2.0;

        if (pos.x < wallMargin)
        {
            wallForce.x = turnStrength * (1.0 - pos.x / wallMargin);
        }
        else if (pos.x > resolution.x - wallMargin)
        {
            wallForce.x = -turnStrength * (1.0 - (resolution.x - pos.x) / wallMargin);
        }

        if (pos.y < wallMargin)
        {
            wallForce.y = turnStrength * (1.0 - pos.y / wallMargin);
        }
        else if (pos.y > resolution.y - wallMargin)
        {
            wallForce.y = -turnStrength * (1.0 - (resolution.y - pos.y) / wallMargin);
        }

        steer += wallForce;
    }

    // Apply steering and update velocity
    velocity += steer;
    velocity = flock_limitVec(velocity, maxSpeed);

    // Update position
    pos += velocity;

    // Boundary wrap
    if (boundaryMode == 0)
    {
        pos = flock_wrapPosition(pos, resolution);
    }
    else
    {
        pos = clamp(pos, float2(1.0, 1.0), resolution - float2(1.0, 1.0));
    }

    // Update age
    age += 0.016;

    // === END ORIGINAL ALGORITHM ===

    // Convert back to normalized coords
    float newPx = pos.x / resolution.x;
    float newPy = pos.y / resolution.y;

    FlockAgentOutputs o;
    o.xyz  = float4(newPx, newPy, xyz.z, 1.0);
    o.vel  = float4(velocity, age, seed);
    o.rgba = rgba;
    return o;
}

// =============================================================================
// PASS: passthrough — copy inputTex -> outputTex for 2D-chain continuity
// =============================================================================
float4 frag_passthrough(NMVaryings i) : SV_Target
{
    // WGSL: uv = fragCoord.xy / resolution; return textureSample(inputTex, s, uv).
    // i.uv already == fragCoord / resolution (NMVertFullscreen), but reproduce
    // the reference expression exactly via NM_FragCoord / resolution.
    float2 uv = NM_FragCoord(i) / resolution;
    return inputTex.SampleLevel(sampler_inputTex, uv, 0.0);
}

#endif // NM_EFFECT_FLOCK_INCLUDED
