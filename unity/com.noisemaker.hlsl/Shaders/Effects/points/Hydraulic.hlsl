#ifndef NM_EFFECT_HYDRAULIC_INCLUDED
#define NM_EFFECT_HYDRAULIC_INCLUDED

// =============================================================================
// Hydraulic.hlsl — points/hydraulic (func: "hydraulic")
//
// Hydraulic-erosion flow agent effect (gradient descent). Common Agent
// Architecture middleware. Ported PIXEL-IDENTICALLY from the canonical WGSL
// sources (top-left origin, no per-effect Y flip):
//   wgsl/agent.wgsl        progName "agent"        (MRT: vert NMVertFullscreen,
//                                                   frag frag_agent -> 3 targets)
//   wgsl/passthrough.wgsl  progName "passthrough"  (frag_passthrough)
//
// MULTI-PASS / AGENT / MRT / FEEDBACK: 2 passes per frame in definition order:
//   1. agent  — fullscreen over the AGENT STATE texture (one texel == one
//      agent). Reads global_xyz/global_vel/global_rgba + inputTex, applies
//      gradient descent on inputTex's oklab-L luminance, writes the NEW state
//      to ALL THREE state textures via MRT (drawBuffers:3 — outXYZ@0,
//      outVel@1, outRGBA@2). Inputs and outputs are the SAME global_ keys, so
//      the runtime ping-pongs each per write (ref 04 §10.2/§10.7) and the
//      state PERSISTS frame-to-frame (isStateSurface: suffix _xyz/_vel/_rgba).
//   2. passthrough — fullscreen copy of inputTex to outputTex (2D chain
//      continuity); no state touched.
//
// STATE OWNERSHIP: this effect declares NO local textures. It reads/writes the
// SHARED persistent state surfaces global_xyz / global_vel / global_rgba that
// are ALLOCATED & SEEDED by pointsEmit upstream in the chain
// (pointsEmit().hydraulic().pointsRender()). They are rgba32f (full float) and
// double-buffered. This effect never allocates or spawns; if an agent is dead
// (xyz.w < 0.5) it passes state through unchanged.
//
// NO DEPOSIT/SCATTER PASS HERE: hydraulic is an agent-UPDATE middleware. The
// drawMode:"points" scatter/deposit lives in the separate pointsRender effect,
// not in this definition. Hence both passes are plain fullscreen
// (NMVertFullscreen); no custom SV_VertexID scatter vertex is needed.
//
// NOTE: multi-pass / agent / MRT effect → ships as a runtime-rendered
// Texture2D. NO Shader Graph Custom Function wrapper is provided (the C#
// runtime drives the 2 passes in order, rebinding global_xyz/global_vel/
// global_rgba read/write targets and MRT attachments per pass).
//
// PORTING-GUIDE / parity notes:
//  * WGSL textureLoad(t, coord, 0) → t.Load(int3(coord, 0)) — integer texel
//    fetch, point, no filtering. State (xyzTex/velTex/rgbaTex) AND inputTex
//    (in fetch_texel) are read this way. State texel coord = vec2i(fragCoord).
//  * WGSL textureSample(t, s, uv) → t.Sample(sampler_t, uv) (linear, clamp,
//    non-sRGB). Used only by passthrough.
//  * AGENT-PASS COORD: the agent pass viewport is the STATE texture
//    (stateSize x stateSize), NOT the chain resolution. WGSL fragCoord here is
//    over the state texture, so vec2i(fragCoord.xy) == int2(i.uv * stateSize)
//    (uv*stateSize at a pixel center is texel+0.5, truncates to the texel). We
//    do NOT use NM_FragCoord here (it multiplies by _NM_Resolution = chain
//    size, which differs from stateSize). Matches the Flow agent exemplar.
//  * stateSize = textureDimensions(xyzTex,0) → xyzTex.GetDimensions(w,h).
//  * agent_id: WGSL form u32(coord.x)+u32(coord.y)*u32(stateSize.x) ported
//    literally (NOT the GLSL uint(coord.x+coord.y*stateSize.x) which differs by
//    intermediate signed-int overflow semantics; harmless for the used range).
//  * width/height come from the `resolution` UNIFORM (== render-target size of
//    the bound INPUT texture / 2D chain), NOT the state texture's size. The
//    algorithm walks inputTex in pixel space at `resolution`.
//  * fract→frac, mix→lerp. modulo: wrap_float reproduces WGSL's
//    value - floor(value/size)*size with the <0 fixup; wrap_int uses HLSL `%`
//    (trunc-toward-zero like GLSL/WGSL) plus the <0 fixup — these are the
//    effect's OWN wrap helpers, NOT NMCore nm_mod/nm_positiveModulo. Ported
//    verbatim inline.
//  * cube_root: select(-1,1,value>=0) → (value >= 0.0 ? 1.0 : -1.0); WGSL
//    select(false_val, true_val, cond) reversed-arg order accounted for.
//  * pow(2.4) magic, oklab matrix constants, 1.0/3.0 reproduced literally.
//  * No PRNG from NMCore — hash2 is the effect's own PCG-style hash; ported
//    verbatim inline (state * 747796405u + 2891336453u; >> ((state>>28u)+4u)).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input textures (rebound per pass by the runtime per definition inputs{})
// agent:       xyzTex/velTex/rgbaTex (Load, rgba32f state) + inputTex (Load).
// passthrough: inputTex (Sample).
Texture2D xyzTex;    SamplerState sampler_xyzTex;
Texture2D velTex;    SamplerState sampler_velTex;
Texture2D rgbaTex;   SamplerState sampler_rgbaTex;
Texture2D inputTex;  SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
// resolution is the engine global (NMFullscreen alias) — the INPUT/chain size.
float stride;       // globals.stride       default 10   (min 1, max 1000)
float quantize;     // globals.quantize     boolean (1.0/0.0), tested > 0.5
float inverse;      // globals.inverse      boolean (1.0/0.0), tested > 0.5
float inputWeight;  // globals.inputWeight  default 100  (min 0, max 100)

// =============================================================================
// MRT output struct for the agent pass (WGSL @location 0/1/2).
// drawBuffers:3 — outXYZ→SV_Target0, outVel→SV_Target1, outRGBA→SV_Target2.
// =============================================================================
struct HydraulicAgentOut
{
    float4 xyz  : SV_Target0;
    float4 vel  : SV_Target1;
    float4 rgba : SV_Target2;
};

// =============================================================================
// ORIGINAL HFLOW HELPER FUNCTIONS (PRESERVED EXACTLY — ported verbatim)
// =============================================================================

float2 hyd_hash2(uint seed)
{
    uint state = seed * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    uint x_bits = (word >> 22u) ^ word;
    state = x_bits * 747796405u + 2891336453u;
    word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    uint y_bits = (word >> 22u) ^ word;
    return float2((float)x_bits / 4294967295.0, (float)y_bits / 4294967295.0);
}

float hyd_wrap_float(float value, float size)
{
    if (size <= 0.0) { return 0.0; }
    float scaled = floor(value / size);
    float wrapped = value - scaled * size;
    if (wrapped < 0.0) { wrapped += size; }
    return wrapped;
}

int hyd_wrap_int(int value, int size)
{
    if (size <= 0) { return 0; }
    int result = value % size;
    if (result < 0) { result += size; }
    return result;
}

float hyd_srgb_to_linear(float value)
{
    if (value <= 0.04045) { return value / 12.92; }
    return pow((value + 0.055) / 1.055, 2.4);
}

float hyd_cube_root(float value)
{
    if (value == 0.0) { return 0.0; }
    float sign_value = (value >= 0.0) ? 1.0 : -1.0;
    return sign_value * pow(abs(value), 1.0 / 3.0);
}

float hyd_oklab_l(float3 rgb)
{
    float r_lin = hyd_srgb_to_linear(clamp(rgb.x, 0.0, 1.0));
    float g_lin = hyd_srgb_to_linear(clamp(rgb.y, 0.0, 1.0));
    float b_lin = hyd_srgb_to_linear(clamp(rgb.z, 0.0, 1.0));
    float l = 0.4121656120 * r_lin + 0.5362752080 * g_lin + 0.0514575653 * b_lin;
    float m = 0.2118591070 * r_lin + 0.6807189584 * g_lin + 0.1074065790 * b_lin;
    float s = 0.0883097947 * r_lin + 0.2818474174 * g_lin + 0.6302613616 * b_lin;
    return 0.2104542553 * hyd_cube_root(l) + 0.7936177850 * hyd_cube_root(m) - 0.0040720468 * hyd_cube_root(s);
}

float4 hyd_fetch_texel(int x, int y, int width, int height)
{
    int wrapped_x = hyd_wrap_int(x, width);
    int wrapped_y = hyd_wrap_int(y, height);
    return inputTex.Load(int3(wrapped_x, wrapped_y, 0));
}

float hyd_luminance_at(int x, int y, int width, int height)
{
    float4 texel = hyd_fetch_texel(x, y, width, height);
    return hyd_oklab_l(texel.xyz);
}

// =============================================================================
// PASS: agent — gradient-descent agent update (frag_agent, MRT 3 targets)
// =============================================================================
HydraulicAgentOut frag_agent(NMVaryings i)
{
    // The agent pass viewport == the STATE texture (stateSize x stateSize),
    // NOT the chain resolution. WGSL fragCoord here is over the state texture,
    // so vec2i(fragCoord.xy) == int2(uv * stateSize) (uv*stateSize at a pixel
    // center is texel+0.5, truncates to the integer texel). Do NOT use
    // NM_FragCoord (which multiplies by _NM_Resolution, the chain size).
    uint sw, sh;
    xyzTex.GetDimensions(sw, sh);
    int2 stateSize = int2((int)sw, (int)sh);
    int2 coord = int2(i.uv * float2(stateSize));

    // Read input state from pipeline
    float4 xyz = xyzTex.Load(int3(coord, 0));
    float4 vel = velTex.Load(int3(coord, 0));
    float4 rgba = rgbaTex.Load(int3(coord, 0));

    // Extract components
    // xyz stores normalized coords [0,1], convert to pixel coords for algorithm
    float px = xyz.x;  // normalized x
    float py = xyz.y;  // normalized y
    float alive = xyz.w;

    // vel stores: [vx, vy, vz, seed] - standard velocity format
    float vx = vel.x;
    float vy = vel.y;
    float vz = vel.z;
    float seed_f = vel.w;

    int width = (int)resolution.x;
    int height = (int)resolution.y;

    uint agent_id = (uint)coord.x + (uint)coord.y * (uint)stateSize.x;

    // Convert normalized to pixel coords for the algorithm
    float x = px * resolution.x;
    float y = py * resolution.y;

    HydraulicAgentOut o;

    // If not alive, pass through unchanged
    if (alive < 0.5)
    {
        o.xyz = xyz;
        o.vel = vel;
        o.rgba = rgba;
        return o;
    }

    // Initialize seed on first spawn (when seed is 0)
    if (seed_f == 0.0)
    {
        seed_f = hyd_hash2(agent_id + 99999u).x;
    }

    // Per-agent inertia derived from seed (for gradient blending)
    float inertia = 0.7 + seed_f * 0.3;

    // Attrition is now handled by pointsEmit

    // === GRADIENT DESCENT ALGORITHM ===

    int xi = hyd_wrap_int((int)floor(x), width);
    int yi = hyd_wrap_int((int)floor(y), height);
    int x1i = hyd_wrap_int(xi + 1, width);
    int y1i = hyd_wrap_int(yi + 1, height);

    float uu = x - floor(x);
    float vv = y - floor(y);

    float c00 = hyd_luminance_at(xi, yi, width, height);
    float c10 = hyd_luminance_at(x1i, yi, width, height);
    float c01 = hyd_luminance_at(xi, y1i, width, height);
    float c11 = hyd_luminance_at(x1i, y1i, width, height);

    float gx = lerp(c01 - c00, c11 - c10, uu);
    float gy = lerp(c10 - c00, c11 - c01, vv);

    // Apply inverse if requested
    if (inverse > 0.5)
    {
        gx = -gx;
        gy = -gy;
    }

    if (quantize > 0.5)
    {
        gx = floor(gx);
        gy = floor(gy);
    }

    // Convert gradient to velocity contribution
    // Stride controls the speed (in 1/10th pixels per frame)
    float glen = length(float2(gx, gy));
    float targetVx = 0.0;
    float targetVy = 0.0;
    if (glen > 1e-6)
    {
        float scale = (stride * 0.1) / glen;
        targetVx = gx * scale;
        targetVy = gy * scale;
    }

    // inputWeight controls how much gradient influences velocity
    // 0 = keep current velocity, 100 = fully gradient-driven
    float weightBlend = clamp(inputWeight * 0.01, 0.0, 1.0);
    float blendFactor = inertia * weightBlend;

    // Blend current velocity with gradient-derived target velocity
    vx = lerp(vx, targetVx, blendFactor);
    vy = lerp(vy, targetVy, blendFactor);

    // === END GRADIENT ALGORITHM ===

    // Integrate position with velocity (in pixel space)
    x = hyd_wrap_float(x + vx, resolution.x);
    y = hyd_wrap_float(y + vy, resolution.y);

    // Convert back to normalized coords [0,1]
    float newPx = x / resolution.x;
    float newPy = y / resolution.y;

    // Output: position updated, velocity in normalized space for compatibility
    float normVx = vx / resolution.x;
    float normVy = vy / resolution.y;

    o.xyz = float4(newPx, newPy, xyz.z, alive);
    o.vel = float4(normVx, normVy, vz, seed_f);
    o.rgba = rgba;
    return o;
}

// =============================================================================
// PASS: passthrough — copy inputTex to output (2D chain continuity)
// =============================================================================
float4 frag_passthrough(NMVaryings i) : SV_Target
{
    float2 uv = NM_FragCoord(i) / resolution;
    return inputTex.Sample(sampler_inputTex, uv);
}

#endif // NM_EFFECT_HYDRAULIC_INCLUDED
