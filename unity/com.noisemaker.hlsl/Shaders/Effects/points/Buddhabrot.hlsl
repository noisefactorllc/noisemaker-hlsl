#ifndef NM_EFFECT_BUDDHABROT_INCLUDED
#define NM_EFFECT_BUDDHABROT_INCLUDED

// =============================================================================
// Buddhabrot.hlsl — points/buddhabrot (func: "buddhabrot")
//
// Buddhabrot fractal via progressive orbit accumulation. Ported PIXEL-
// IDENTICALLY from the canonical WGSL sources (top-left origin, no per-effect
// Y flip):
//   wgsl/agent.wgsl       progName "agent"       (frag_agent, MRT 3 outputs)
//   wgsl/zWrite.wgsl      progName "zWrite"      (frag_zWrite, single output)
//   wgsl/passthrough.wgsl progName "passthrough" (frag_passthrough, single)
//
// MULTI-PASS / AGENT FEEDBACK: 3 passes per frame. This effect is the AGENT-
// UPDATE middleware of the Common Agent Architecture. It reads & rewrites the
// PERSISTENT ('global_') particle-state textures created by the surrounding
// pointsEmit pipeline:
//   global_xyz  : [screenX, screenY, phase, alive]   (phase: 0=fresh,0.5=depositing)
//   global_vel  : [c.re, c.im, step, escapeStep]      (orbit seed + progress)
//   global_rgba : [brightness, brightness, brightness, 1]
// The "agent" pass is a FULLSCREEN pass over the state texture that writes all
// three with MRT (drawBuffers:3). The runtime ping-pongs each state surface per
// write and persists them frame-to-frame via the isStateSurface predicate
// (names xyz/vel/rgba qualify — reference 04 §10.7). State textures are
// rgba32f (full float) so step counts / escapeStep survive exactly.
//
// IMPORTANT — there is NO deposit/points-scatter pass in THIS effect. The
// scatter ("points" drawMode, additive Blend One One) lives in the separate
// pointsEmit/pointsRender middleware effects of the chain
//   solid().pointsEmit(stateSize:512).buddhabrot().pointsRender(intensity:99).write(o0)
// buddhabrot only advances orbit state and writes a per-agent screen position
// that pointsRender later scatters. Hence every pass here uses NMVertFullscreen
// (no custom deposit vertex). The custom scatter-vertex risk does not apply.
//
// NOTE: multi-pass / agent effect → ships as a runtime-rendered Texture2D. No
// Shader Graph Custom Function wrapper is provided (the C# runtime drives the 3
// passes in order, rebinding global_xyz/global_vel/global_rgba/global_zState
// read/write targets per pass).
//
// PORTING-GUIDE / parity notes:
//  * WGSL textureLoad(t, coord, 0) → t.Load(int3(coord, 0)) (integer texel
//    fetch, point, no filtering). All state reads use this. rgba32f.
//  * WGSL vec2<i32>(fragCoord.xy) truncates the centered coord; NM_FragCoord(i)
//    returns (px+0.5), so int2(fragCoord) truncates to the integer texel index
//    exactly as WGSL does. Reproduced literally.
//  * WGSL textureDimensions(t,0) → t.GetDimensions(w,h); stateSize = (int)w.
//  * fract→frac, no modulo used (no nm_mod needed). No NMCore helpers used —
//    this effect's PRNG is its OWN PCG-style hash (hash_uint/hash), ported
//    verbatim inline (it differs from NMCore's pcg/prng/random; do NOT
//    substitute).
//  * float→u32: WGSL u32(f) is a numeric truncation → (uint)f. The XOR seed mix
//    u32(coord.x + coord.y*stateSize) etc. preserve two's-complement on cast.
//  * The escape/deposit loops use a fixed bound of 2048 with an inner break
//    (i >= iterCap / i >= currentStep / i >= stepI). Reproduced literally;
//    [loop] prevents the HLSL compiler from trying to unroll 2048 iterations.
//  * passthrough samples bilinear: uv = fragCoord / resolution (the resolution
//    UNIFORM == render-target size). textureSample → Sample(sampler, uv).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input samplers (rebound per pass per definition.js inputs{}) -----------
// agent:       xyzTex, velTex, rgbaTex (all Load, rgba32f)
// zWrite:      xyzTex, velTex          (Load)
// passthrough: inputTex                (Sample, bilinear)
Texture2D    xyzTex;    SamplerState sampler_xyzTex;
Texture2D    velTex;    SamplerState sampler_velTex;
Texture2D    rgbaTex;   SamplerState sampler_rgbaTex;
Texture2D    inputTex;  SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
// stateSize is NOT consumed in-shader (texSize comes from textureDimensions),
// but is declared for parity with the definition (drives texture sizing only).
int   maxIter;     // globals.maxIter   default 200
int   minIter;     // globals.minIter   default 1
int   mode;        // globals.mode      default 0 (0=standard, 1=anti)
float centerX;     // globals.centerX   default -0.5
float centerY;     // globals.centerY   default 0
float zoom;        // globals.zoom      default 1.0

// =============================================================================
// Verbatim core helpers (this effect's OWN PCG-style hash — inline, per effect)
// =============================================================================
uint bb_hash_uint(uint seed)
{
    uint state = seed * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float bb_hash(uint seed)
{
    return (float)bb_hash_uint(seed) / 4294967295.0;
}

// Map complex z to screen [0,1] — rotated CW 90 deg for traditional orientation
float2 bb_complexToScreen(float2 z)
{
    return float2(
        (z.y - centerY) * zoom * zoom * 0.2 + 0.5,
        (centerX - z.x) * zoom * zoom * 0.2 + 0.5
    );
}

// Cardioid + period-2 bulb interior test
bool bb_inMandelbrotInterior(float cRe, float cIm)
{
    float y2 = cIm * cIm;
    float q = (cRe - 0.25) * (cRe - 0.25) + y2;
    if (q * (q + (cRe - 0.25)) <= 0.25 * y2) { return true; }
    float xp1 = cRe + 1.0;
    return xp1 * xp1 + y2 <= 0.0625;
}

// =============================================================================
// PASS: agent — orbit advance, 3 MRT outputs (frag_agent)
// outputs: outXYZ (color/loc0), outVel (color1/loc1), outRGBA (color2/loc2)
// =============================================================================
struct AgentOutputs
{
    float4 outXYZ  : SV_Target0;
    float4 outVel  : SV_Target1;
    float4 outRGBA : SV_Target2;
};

AgentOutputs frag_agent(NMVaryings i)
{
    AgentOutputs o;

    int2 coord = int2(NM_FragCoord(i));   // WGSL vec2<i32>(fragCoord.xy) truncation

    uint tw, th;
    xyzTex.GetDimensions(tw, th);
    int stateSize = (int)tw;

    float4 pos = xyzTex.Load(int3(coord, 0));
    float4 vel = velTex.Load(int3(coord, 0));
    float4 col = rgbaTex.Load(int3(coord, 0));

    if (pos.w < 0.5)
    {
        o.outXYZ = pos;
        o.outVel = vel;
        o.outRGBA = col;
        return o;
    }

    // Seed varies per agent and per respawn cycle via time
    uint agentSeed = bb_hash_uint((uint)(coord.x + coord.y * stateSize))
                   ^ (uint)(time * 65536.0)
                   ^ (uint)(vel.z * 137.0);

    bool needsInit = pos.z < 0.25;

    if (needsInit)
    {
        float cRe = bb_hash(agentSeed) * 3.5 - 2.5;
        float cIm = bb_hash(agentSeed + 1u) * 3.0 - 1.5;

        // Cardioid + bulb rejection for standard mode
        if (mode == 0 && bb_inMandelbrotInterior(cRe, cIm))
        {
            o.outXYZ = float4(pos.xy, 0.0, 0.0);
            o.outVel = vel;
            o.outRGBA = float4(0.0, 0.0, 0.0, 0.0);
            return o;
        }

        // Test orbit to classify
        float2 z = float2(0.0, 0.0);
        int escapeAt = 0;
        int iterCap = min(maxIter, 2048);

        [loop]
        for (int it = 0; it < 2048; it = it + 1)
        {
            if (it >= iterCap) { break; }
            float zr = z.x * z.x - z.y * z.y + cRe;
            float zi = 2.0 * z.x * z.y + cIm;
            z = float2(zr, zi);
            if (dot(z, z) > 4.0)
            {
                escapeAt = it + 1;
                break;
            }
        }

        bool escaped = escapeAt > 0;
        float escapeStep = 0.0;
        float brightness = 0.0;

        if (mode == 0)
        {
            if (escaped && escapeAt >= minIter)
            {
                escapeStep = (float)escapeAt;
                brightness = 0.03;
            }
        }
        else
        {
            if (!escaped)
            {
                escapeStep = (float)iterCap;
                brightness = 0.03;
            }
        }

        // Non-qualifying orbit — signal death for pointsEmit respawn
        if (brightness == 0.0)
        {
            o.outXYZ = float4(pos.xy, 0.0, 0.0);
            o.outVel = vel;
            o.outRGBA = float4(0.0, 0.0, 0.0, 0.0);
            return o;
        }

        // Start deposit at z1 = c
        float2 screen = bb_complexToScreen(float2(cRe, cIm));

        o.outXYZ = float4(screen, 0.5, 1.0);
        o.outVel = float4(cRe, cIm, 1.0, escapeStep);
        o.outRGBA = float4(brightness, brightness, brightness, 1.0);
        return o;
    }

    // ---- Active deposit phase ----
    // Recompute z from scratch using c and step count (no texture dependency)

    float cReA = vel.x;
    float cImA = vel.y;
    float step = vel.z;
    float escapeStepA = vel.w;

    // Recompute z to current step from z0 = 0
    float2 zA = float2(0.0, 0.0);
    int currentStep = (int)step;
    [loop]
    for (int j = 0; j < 2048; j = j + 1)
    {
        if (j >= currentStep) { break; }
        float zr = zA.x * zA.x - zA.y * zA.y + cReA;
        float zi = 2.0 * zA.x * zA.y + cImA;
        zA = float2(zr, zi);
    }

    // Advance 8 more steps
    [loop]
    for (int s = 0; s < 8; s = s + 1)
    {
        step = step + 1.0;

        if (step >= escapeStepA)
        {
            o.outXYZ = float4(pos.xy, 0.0, 0.0);
            o.outVel = float4(0.0, 0.0, step, 0.0);
            o.outRGBA = float4(0.0, 0.0, 0.0, 0.0);
            return o;
        }

        float zr = zA.x * zA.x - zA.y * zA.y + cReA;
        float zi = 2.0 * zA.x * zA.y + cImA;
        zA = float2(zr, zi);
    }

    float2 screenA = bb_complexToScreen(zA);

    o.outXYZ = float4(screenA, 0.5, 1.0);
    o.outVel = float4(cReA, cImA, step, escapeStepA);
    o.outRGBA = col;
    return o;
}

// =============================================================================
// PASS: zWrite — recompute z to current step for storage (frag_zWrite)
// =============================================================================
float4 frag_zWrite(NMVaryings i) : SV_Target
{
    int2 coord = int2(NM_FragCoord(i));
    float4 pos = xyzTex.Load(int3(coord, 0));
    float4 vel = velTex.Load(int3(coord, 0));

    // Dead agent — zero z
    if (pos.w < 0.5)
    {
        return float4(0.0, 0.0, 0.0, 0.0);
    }

    float cRe = vel.x;
    float cIm = vel.y;
    int stepI = (int)vel.z;

    // Recompute z from scratch to current step
    float2 z = float2(0.0, 0.0);
    [loop]
    for (int it = 0; it < 2048; it = it + 1)
    {
        if (it >= stepI) { break; }
        float zr = z.x * z.x - z.y * z.y + cRe;
        float zi = 2.0 * z.x * z.y + cIm;
        z = float2(zr, zi);
    }

    return float4(z.x, z.y, 0.0, 0.0);
}

// =============================================================================
// PASS: passthrough — bilinear copy of inputTex (frag_passthrough)
// =============================================================================
float4 frag_passthrough(NMVaryings i) : SV_Target
{
    float2 uv = NM_FragCoord(i) / resolution;
    return inputTex.Sample(sampler_inputTex, uv);
}

#endif // NM_EFFECT_BUDDHABROT_INCLUDED
