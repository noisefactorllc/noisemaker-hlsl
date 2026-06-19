#ifndef NM_EFFECT_MNCA_INCLUDED
#define NM_EFFECT_MNCA_INCLUDED

// =============================================================================
// Mnca.hlsl — synth/mnca (func: "mnca") — Multi-neighbourhood cellular automata
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL sources:
//   shaders/effects/synth/mnca/wgsl/mncaFb.wgsl  (feedback/update pass, progName "mncaFb")
//   shaders/effects/synth/mnca/wgsl/mnca.wgsl    (display/render  pass, progName "mnca")
//
// MULTI-PASS + FEEDBACK. The persistent state lives in the global double-buffered
// surface `global_mnca_state` (low-res, sized screen/zoom). Pass order per
// definition.js:
//   1) "update" (program mncaFb): reads global_mnca_state (bufTex, self-feedback)
//      and the seed input (seedTex = tex), writes the next state into
//      global_mnca_state. The runtime ping-pongs the global within the frame so
//      the read texture is last frame's buffer.
//   2) "render" (program mnca): reads global_mnca_state (fbTex) and upsamples it
//      to outputTex via the selected reconstruction filter.
//
// NOTE: multi-pass + feedback effect — ships as a runtime-rendered Texture2D.
// No Shader Graph Custom Function wrapper is provided (SKIP per task).
//
// PORTING-GUIDE notes / hazards handled:
//  * Ported from WGSL (top-left, canonical) — no per-effect Y flip (H8).
//  * mncaFb samples bufTex with textureLoad (integer fetch, nearest, no
//    filtering) -> HLSL Texture2D.Load(int3(coord,0)). seedTex is sampled with
//    a linear sampler -> .Sample. base = int2(uv * texSize) (truncation).
//  * mnca (render) uses textureLoad for smoothing==0/1/2 (nearest fetch) and
//    textureSampleLevel(...,0.0) for the bicubic/catmull/bspline filters ->
//    .SampleLevel(s, uv, 0.0). All helpers copied verbatim from this effect's
//    WGSL (catmullRom3 here is the 3-control-point hermite form; do NOT swap for
//    a generic version — see golden rule 2).
//  * `i32(f32)` -> (int) truncation toward zero. Booleans tested as `> 0.5`.
//  * map()/lum()/random() copied inline (random is the sin-dot hash, NOT NMCore).
//  * Linear, clamp-to-edge, non-sRGB samplers (H7) — declared in Mnca.shader.
//  * No fmod usage; no float mod needed here (all arithmetic is plain).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
// Set by the runtime via MaterialPropertyBlock by these exact names.
float speed;        // globals.speed.uniform     default 10
int   smoothing;    // globals.smoothing.uniform  default 0 (constant)
float weight;       // globals.weight.uniform     default 0
int   seed;         // globals.seed.uniform       default 1
float resetState;   // globals.resetState.uniform default 0 (bool, tested > 0.5)
float n1v1;         // default 21
float n1r1;         // default 1
float n1v2;         // default 35
float n1r2;         // default 15
float n1v3;         // default 75
float n1r3;         // default 10
float n1v4;         // default 12
float n1r4;         // default 3
float n2v1;         // default 10
float n2r1;         // default 18
float n2v2;         // default 43
float n2r2;         // default 12
int   source;       // globals.source.uniform     default 0 (unused by shader)

// ---- Textures + samplers (one per distinct reference input sampler) ----------
// update pass: bufTex = global_mnca_state (self-feedback), seedTex = tex.
// render pass: fbTex = global_mnca_state.
// The runtime rebinds these per pass to the right physical texture.
Texture2D    bufTex;     // mncaFb @binding(2): the prev-frame state (textureLoad)
SamplerState sampler_bufTex;
Texture2D    seedTex;    // mncaFb @binding(3): seed/input texture (textureSample)
SamplerState sampler_seedTex;
Texture2D    fbTex;      // mnca   @binding(1): state buffer for the display pass
SamplerState sampler_fbTex;

// =============================================================================
// PASS 1 — "update" (program "mncaFb") — verbatim from mncaFb.wgsl
// =============================================================================

float mnca_map(float value, float inMin, float inMax, float outMin, float outMax) {
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

float mnca_lum(float3 color) {
    return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
}

float mnca_random(float2 st) {
    return frac(sin(dot(st, float2(12.9898, 78.233))) * 43758.5453123);
}

// Clamp a texel coordinate to the valid texture bounds
int2 mnca_clampCoord(int2 p, int2 size) {
    int cx = clamp(p.x, 0, size.x - 1);
    int cy = clamp(p.y, 0, size.y - 1);
    return int2(cx, cy);
}

// Fetch a single cell value using integer coordinates to avoid filtering
float mnca_cellAt(int2 base, int2 offset, int2 size) {
    int2 pc = mnca_clampCoord(base + offset, size);
    return bufTex.Load(int3(pc, 0)).r;
}

// Neighbourhood 1 = circle with r = 3.
float mnca_neighborsAvgCircle(int2 base, int2 size) {
    float total = 0.0;
    [loop]
    for (int y = -3; y <= 3; y++) {
        [loop]
        for (int x = -3; x <= 3; x++) {
            if (x == 0 && y == 0) { continue; }
            if (abs(x) == 3 && abs(y) > 1) { continue; }
            if (abs(y) == 3 && abs(x) > 1) { continue; }
            total += mnca_cellAt(base, int2(x, y), size);
        }
    }
    return total / 36.0;
}

// Neighbourhood 2 = ring with inner r = 4 and outer r = 7.
float mnca_neighborsAvgRing(int2 base, int2 size) {
    float total = 0.0;
    [loop]
    for (int y = -7; y <= 7; y++) {
        [loop]
        for (int x = -7; x <= 7; x++) {
            // ignore inner area
            if (abs(x) <= 3 && abs(y) <= 3) { continue; }
            if (abs(x) == 4 && abs(y) <= 2) { continue; }
            if (abs(y) == 4 && abs(x) <= 2) { continue; }
            // ignore outer corners
            if (abs(x) == 7 && abs(y) > 2) { continue; }
            if (abs(x) == 6 && abs(y) > 4) { continue; }
            if (abs(x) == 5 && abs(y) > 5) { continue; }
            if (abs(x) > 2 && abs(y) > 6) { continue; }
            total += mnca_cellAt(base, int2(x, y), size);
        }
    }
    return total / 108.0;
}

float mnca_getState(float avg1, float avg2, float state,
            float n1v1_, float n1r1_, float n1v2_, float n1r2_,
            float n1v3_, float n1r3_, float n1v4_, float n1r4_,
            float n2v1_, float n2r1_, float n2v2_, float n2r2_) {
    float newState = state;
    if (avg1 >= n1v1_ * 0.01 && avg1 <= n1v1_ * 0.01 + n1r1_ * 0.01) { newState = 1.0; }
    if (avg1 >= n1v2_ * 0.01 && avg1 <= n1v2_ * 0.01 + n1r2_ * 0.01) { newState = 0.0; }
    if (avg1 >= n1v3_ * 0.01 && avg1 <= n1v3_ * 0.01 + n1r3_ * 0.01) { newState = 0.0; }
    if (avg2 >= n2v1_ * 0.01 && avg2 <= n2v1_ * 0.01 + n2r1_ * 0.01) { newState = 0.0; }
    if (avg2 >= n2v2_ * 0.01 && avg2 <= n2v2_ * 0.01 + n2r2_ * 0.01) { newState = 1.0; }
    if (avg1 >= n1v4_ * 0.01 && avg1 <= n1v4_ * 0.01 + n1r4_ * 0.01) { newState = 0.0; }
    return newState;
}

float4 frag_mncaFb(NMVaryings i) : SV_Target
{
    // fragCoord (top-left, +0.5 centered) analog of WGSL @builtin(position).
    float2 fragCoord = NM_FragCoord(i);

    uint tw, th;
    bufTex.GetDimensions(tw, th);
    int2 texSizeI = int2((int)tw, (int)th);
    float2 texSize = float2((float)texSizeI.x, (float)texSizeI.y);
    float2 uv = fragCoord / texSize;

    // Slot 0: resolution, time, deltaTime
    float dt = deltaTime;

    // Slot 1: speed, smoothing, weight, seed
    float speed_ = speed;
    float weight_ = weight;
    int seed_ = seed;

    // Slot 2: resetState, n1v1, n1r1, n1v2
    bool resetState_ = resetState > 0.5;

    // Sample textures unconditionally (matches WGSL uniform control flow).
    float3 prevFrame = seedTex.Sample(sampler_seedTex, uv).rgb;
    float prevLum = mnca_lum(prevFrame);

    // Use UV-derived coordinates (not fragCoord) to handle resolution mismatch.
    int2 base = int2((int)(uv.x * texSize.x), (int)(uv.y * texSize.y));
    float4 bufState = bufTex.Load(int3(mnca_clampCoord(base, texSizeI), 0));
    float state = bufState.r;
    bool bufferIsEmpty = (bufState.r == 0.0 && bufState.g == 0.0 && bufState.b == 0.0 && bufState.a == 0.0);

    // Initialize when reset button pressed or when buffer is completely empty.
    if (resetState_ || bufferIsEmpty) {
        float r = mnca_random(uv + float2((float)seed_, (float)seed_));
        float alive = step(0.5, r);
        return float4(alive, alive, alive, 1.0);
    }

    float n1 = mnca_neighborsAvgCircle(base, texSizeI);
    float n2 = mnca_neighborsAvgRing(base, texSizeI);
    float newState = mnca_getState(n1, n2, state, n1v1, n1r1, n1v2, n1r2, n1v3, n1r3, n1v4, n1r4, n2v1, n2r1, n2v2, n2r2);

    if (weight_ > 0.0) {
        newState = lerp(newState, prevLum, weight_ * 0.01);
    }

    // Remap human-friendly speed knob to a stable integration step.
    float animSpeed = mnca_map(speed_, 1.0, 100.0, 0.1, 100.0);
    float4 currentState = float4(state, state, state, 1.0);
    float4 nextState = float4(newState, newState, newState, 1.0);
    return lerp(currentState, nextState, min(1.0, dt * animSpeed));
}

// =============================================================================
// PASS 2 — "render" (program "mnca") — verbatim from mnca.wgsl
// =============================================================================

float4 mnca_quadratic3(float4 p0, float4 p1, float4 p2, float t) {
    float t2 = t * t;
    return p0 * 0.5 * (1.0 - t) * (1.0 - t) +
           p1 * 0.5 * (-2.0 * t2 + 2.0 * t + 1.0) +
           p2 * 0.5 * t2;
}

float4 mnca_bicubic4(float4 p0, float4 p1, float4 p2, float4 p3, float t) {
    float t2 = t * t;
    float t3 = t2 * t;

    float b0 = (1.0 - t) * (1.0 - t) * (1.0 - t) / 6.0;
    float b1 = (3.0 * t3 - 6.0 * t2 + 4.0) / 6.0;
    float b2 = (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) / 6.0;
    float b3 = t3 / 6.0;

    return p0 * b0 + p1 * b1 + p2 * b2 + p3 * b3;
}

float4 mnca_catmullRom3(float4 p0, float4 p1, float4 p2, float t) {
    float t2 = t * t;
    float t3 = t2 * t;

    float4 m = 0.5 * (p2 - p0);

    return (2.0*t3 - 3.0*t2 + 1.0) * p1 +
           (t3 - 2.0*t2 + t) * m +
           (-2.0*t3 + 3.0*t2) * p2 +
           (t3 - t2) * m;
}

float4 mnca_catmullRom4(float4 p0, float4 p1, float4 p2, float4 p3, float t) {
    return p1 + 0.5 * t * (p2 - p0 + t * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 + t * (3.0 * (p1 - p2) + p3 - p0)));
}

float4 mnca_quadraticSample(float2 uv, float2 texelSize) {
    // Match GLSL: offset uv by one texel to accommodate texel centering
    float2 uv2 = uv + texelSize;
    float2 texCoord = uv2 / texelSize;
    float2 baseCoord = floor(texCoord - 0.5);
    float2 f = frac(texCoord - 0.5);

    float4 v00 = fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2(-0.5, -0.5)) * texelSize, 0.0);
    float4 v10 = fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 0.5, -0.5)) * texelSize, 0.0);
    float4 v20 = fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 1.5, -0.5)) * texelSize, 0.0);

    float4 v01 = fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2(-0.5,  0.5)) * texelSize, 0.0);
    float4 v11 = fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 0.5,  0.5)) * texelSize, 0.0);
    float4 v21 = fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 1.5,  0.5)) * texelSize, 0.0);

    float4 v02 = fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2(-0.5,  1.5)) * texelSize, 0.0);
    float4 v12 = fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 0.5,  1.5)) * texelSize, 0.0);
    float4 v22 = fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 1.5,  1.5)) * texelSize, 0.0);

    float4 y0 = mnca_quadratic3(v00, v10, v20, f.x);
    float4 y1 = mnca_quadratic3(v01, v11, v21, f.x);
    float4 y2 = mnca_quadratic3(v02, v12, v22, f.x);

    return mnca_quadratic3(y0, y1, y2, f.y);
}

float4 mnca_catmullRom3x3Sample(float2 uv, float2 texelSize) {
    float2 uv2 = uv + texelSize;
    float2 texCoord = uv2 / texelSize;
    float2 baseCoord = floor(texCoord - 1.0);
    float2 f = frac(texCoord - 1.0);

    float4 v00 = fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2(-0.5, -0.5)) * texelSize, 0.0);
    float4 v10 = fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 0.5, -0.5)) * texelSize, 0.0);
    float4 v20 = fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 1.5, -0.5)) * texelSize, 0.0);

    float4 v01 = fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2(-0.5,  0.5)) * texelSize, 0.0);
    float4 v11 = fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 0.5,  0.5)) * texelSize, 0.0);
    float4 v21 = fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 1.5,  0.5)) * texelSize, 0.0);

    float4 v02 = fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2(-0.5,  1.5)) * texelSize, 0.0);
    float4 v12 = fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 0.5,  1.5)) * texelSize, 0.0);
    float4 v22 = fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 1.5,  1.5)) * texelSize, 0.0);

    float4 y0 = mnca_catmullRom3(v00, v10, v20, f.x);
    float4 y1 = mnca_catmullRom3(v01, v11, v21, f.x);
    float4 y2 = mnca_catmullRom3(v02, v12, v22, f.x);

    return mnca_catmullRom3(y0, y1, y2, f.y);
}

float4 mnca_bicubicSample(float2 uv, float2 texelSize) {
    float2 uv2 = uv + texelSize;
    float2 texCoord = uv2 / texelSize;
    float2 baseCoord = floor(texCoord - 1.0);
    float2 f = frac(texCoord - 1.0);

    float4 row0 = mnca_bicubic4(
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2(-0.5, -0.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 0.5, -0.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 1.5, -0.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 2.5, -0.5)) * texelSize, 0.0),
        f.x
    );

    float4 row1 = mnca_bicubic4(
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2(-0.5,  0.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 0.5,  0.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 1.5,  0.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 2.5,  0.5)) * texelSize, 0.0),
        f.x
    );

    float4 row2 = mnca_bicubic4(
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2(-0.5,  1.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 0.5,  1.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 1.5,  1.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 2.5,  1.5)) * texelSize, 0.0),
        f.x
    );

    float4 row3 = mnca_bicubic4(
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2(-0.5,  2.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 0.5,  2.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 1.5,  2.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 2.5,  2.5)) * texelSize, 0.0),
        f.x
    );

    return mnca_bicubic4(row0, row1, row2, row3, f.y);
}

float4 mnca_catmullRom4x4Sample(float2 uv, float2 texelSize) {
    float2 uv2 = uv + texelSize;
    float2 texCoord = uv2 / texelSize;
    float2 baseCoord = floor(texCoord - 1.0);
    float2 f = frac(texCoord - 1.0);

    float4 row0 = mnca_catmullRom4(
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2(-0.5, -0.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 0.5, -0.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 1.5, -0.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 2.5, -0.5)) * texelSize, 0.0),
        f.x
    );

    float4 row1 = mnca_catmullRom4(
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2(-0.5,  0.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 0.5,  0.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 1.5,  0.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 2.5,  0.5)) * texelSize, 0.0),
        f.x
    );

    float4 row2 = mnca_catmullRom4(
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2(-0.5,  1.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 0.5,  1.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 1.5,  1.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 2.5,  1.5)) * texelSize, 0.0),
        f.x
    );

    float4 row3 = mnca_catmullRom4(
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2(-0.5,  2.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 0.5,  2.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 1.5,  2.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 2.5,  2.5)) * texelSize, 0.0),
        f.x
    );

    return mnca_catmullRom4(row0, row1, row2, row3, f.y);
}

float mnca_cosineMix(float a, float b, float t) {
    float amount = (1.0 - cos(t * 3.141592653589793)) * 0.5;
    return lerp(a, b, amount);
}

float4 frag_mnca(NMVaryings i) : SV_Target
{
    float2 fragCoord = NM_FragCoord(i);
    float2 resolution_ = resolution;
    int smoothing_ = smoothing;

    float state = 0.0;
    if (smoothing_ == 0) {
        // constant - use textureLoad for exact nearest-neighbor sampling
        uint tw, th;
        fbTex.GetDimensions(tw, th);
        int2 texSizeI = int2((int)tw, (int)th);
        float2 texSizeF = float2((float)texSizeI.x, (float)texSizeI.y);
        int2 pixelCoord = (int2)floor(fragCoord * texSizeF / resolution_);
        state = fbTex.Load(int3(clamp(pixelCoord, int2(0, 0), texSizeI - int2(1, 1)), 0)).g;
    } else if (smoothing_ == 3) {
        // catmull-rom 3x3 (9 taps)
        uint tw, th; fbTex.GetDimensions(tw, th);
        float2 texSize = float2((float)tw, (float)th);
        float2 texelSize = 1.0 / texSize;
        float2 scaling = resolution_ / texSize;
        float2 uv = (fragCoord - scaling * 0.5) / resolution_;
        state = mnca_catmullRom3x3Sample(uv, texelSize).g;
    } else if (smoothing_ == 4) {
        // catmull-rom 4x4 (16 taps)
        uint tw, th; fbTex.GetDimensions(tw, th);
        float2 texSize = float2((float)tw, (float)th);
        float2 texelSize = 1.0 / texSize;
        float2 scaling = resolution_ / texSize;
        float2 uv = (fragCoord - scaling * 0.5) / resolution_;
        state = mnca_catmullRom4x4Sample(uv, texelSize).g;
    } else if (smoothing_ == 5) {
        // b-spline 3x3 (9 taps)
        uint tw, th; fbTex.GetDimensions(tw, th);
        float2 texSize = float2((float)tw, (float)th);
        float2 texelSize = 1.0 / texSize;
        float2 scaling = resolution_ / texSize;
        float2 uv = (fragCoord - scaling * 0.5) / resolution_;
        state = mnca_quadraticSample(uv, texelSize).g;
    } else if (smoothing_ == 6) {
        // b-spline 4x4 (16 taps)
        uint tw, th; fbTex.GetDimensions(tw, th);
        float2 texSize = float2((float)tw, (float)th);
        float2 texelSize = 1.0 / texSize;
        float2 scaling = resolution_ / texSize;
        float2 uv = (fragCoord - scaling * 0.5) / resolution_;
        state = mnca_bicubicSample(uv, texelSize).g;
    } else {
        // linear-style smoothing — sample texel centres explicitly to avoid seams.
        uint tw, th; fbTex.GetDimensions(tw, th);
        float2 texSize = float2((float)tw, (float)th);
        float2 texelPos = (fragCoord * texSize / resolution_) - float2(0.5, 0.5);
        float2 base = floor(texelPos);
        float2 weights = frac(texelPos);
        float2 next = base + float2(1.0, 1.0);

        int2 texSizeI = int2((int)tw, (int)th);
        int2 minIdx = int2(0, 0);
        int2 maxIdx = texSizeI - int2(1, 1);
        int2 baseI = clamp((int2)base, minIdx, maxIdx);
        int2 nextI = clamp((int2)next, minIdx, maxIdx);

        float v00 = fbTex.Load(int3(baseI, 0)).g;
        float v10 = fbTex.Load(int3(int2(nextI.x, baseI.y), 0)).g;
        float v01 = fbTex.Load(int3(int2(baseI.x, nextI.y), 0)).g;
        float v11 = fbTex.Load(int3(nextI, 0)).g;

        if (smoothing_ == 1) {
            float v0 = lerp(v00, v10, weights.x);
            float v1 = lerp(v01, v11, weights.x);
            state = lerp(v0, v1, weights.y);
        } else {
            float v0 = mnca_cosineMix(v00, v10, weights.x);
            float v1 = mnca_cosineMix(v01, v11, weights.x);
            state = mnca_cosineMix(v0, v1, weights.y);
        }
    }

    return float4(state, state, state, 1.0);
}

#endif // NM_EFFECT_MNCA_INCLUDED
