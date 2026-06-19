#ifndef NM_EFFECT_CELLULARAUTOMATA_INCLUDED
#define NM_EFFECT_CELLULARAUTOMATA_INCLUDED

// =============================================================================
// CellularAutomata.hlsl — synth/cellularAutomata (func: "cellularAutomata")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL sources:
//   shaders/effects/synth/cellularAutomata/wgsl/caFb.wgsl (progName "caFb")
//   shaders/effects/synth/cellularAutomata/wgsl/ca.wgsl   (progName "ca")
//
// MULTI-PASS / FEEDBACK effect. Two passes per frame, in definition order:
//   1. "update"  (program caFb): advances the cellular-automata grid. Reads the
//      PERSISTENT state texture `global_ca_state` (as bufTex) AND its OWN output
//      target is `global_ca_state` — this is the feedback / ping-pong path.
//      Also samples the input surface `tex` for luminance perturbation.
//   2. "render"  (program ca): upsamples/reconstructs the grid into outputTex.
//
// This effect is multi-pass and ships as a runtime-rendered Texture2D. The C#
// runtime drives the two passes in order, ping-ponging the persistent
// `global_ca_state` surface (state survives across frames; never auto-swapped
// like a display surface — it is a state/feedback surface). NO Shader Graph
// Custom Function wrapper is provided.
//
// PORTING-GUIDE notes / hazards handled:
//  * Ported from WGSL (top-left, canonical) — no per-effect Y flip (Golden #1).
//  * caFb reads bufTex via textureLoad (INTEGER pixel fetch, no filtering) ->
//    HLSL Texture2D.Load(int3(x,y,0)). It reads `tex` (input surface) via
//    textureSample -> .Sample(). Two DISTINCT sampling semantics; preserved.
//  * The caFb render target IS the state grid (default 32x32 via screenDivide
//    'zoom'). So `resolution`/`_NM_Resolution` == grid size and
//    NM_FragCoord(i) gives the pixel-centered grid coordinate. WGSL does
//    `i32(fragCoord.x)` = truncation -> (int)NM_FragCoord(i).x.
//  * ca render pass uses WGSL `fragCoord.xy` directly (NO tileOffset). The GLSL
//    adds tileOffset; we follow the WGSL canonically -> NM_FragCoord(i).
//  * `random()` here is the sin-hash variant (NOT NMCore's PCG nm_random); it
//    MUST be inlined verbatim. `map()` == nm_map exactly -> use nm_map (allowed).
//  * nm_mod NOT used here (no float mod in source). Full 32-bit float only.
//  * `useCustom` and the custom born/survive masks are NOT declared in
//    definition.js globals, so the runtime never sets them; they remain 0.0
//    (=> useCustom=false, custom path never taken). Declared for binding parity
//    with uniformLayouts.caFb but default-zero. // TODO(verify) custom path
//    unreachable unless a future UI wires these masks.
//  * Linear, clamp-to-edge, non-sRGB samplers (set in CellularAutomata.shader).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// =============================================================================
// Shared input surface `tex` (the effect's optional input image; "none" => black).
// Bound in BOTH passes (caFb samples it for luminance; ca declares it for parity
// but the ca WGSL body does not sample it). Same HLSL name across passes.
// =============================================================================
Texture2D    tex;
SamplerState sampler_tex;

// =============================================================================
// State / feedback grid texture. In the caFb pass this is `bufTex`; in the ca
// pass this is `fbTex` (both bound to the persistent surface global_ca_state).
// Distinct HLSL names per pass so each frag entry mirrors its WGSL binding.
// =============================================================================
Texture2D    bufTex;        // caFb: previous grid state (textureLoad / Sample)
SamplerState sampler_bufTex;
Texture2D    fbTex;         // ca: grid state for reconstruction
SamplerState sampler_fbTex;

// ---- Per-effect named uniforms (match definition.js uniformLayouts.* names) --
// caFb program (uniformLayouts.caFb):
// NOTE: `deltaTime` (slot0.y), `time` (caFb slot0.x via resolution? no — caFb has
//   no resolution; deltaTime=slot0.y) and `resolution`/`time` for ca are all
//   ENGINE globals provided by NMFullscreen aliases. We do NOT redeclare them.
int   seed;          // slot0.z  globals.seed.uniform, [1,100], default 1
float resetState;    // slot0.w  globals.resetState (boolean -> 1/0), default 0
int   ruleIndex;     // slot1.x  globals.ruleIndex, default 0 (classicLife)
float speed;         // slot1.y  globals.speed, [1,100], default 10
float weight;        // slot1.z  globals.weight, [0,100], default 0
float useCustom;     // slot1.w  NOT in globals -> always 0 (custom path off)
float4 bornMask0;    // slot2.xyzw  NOT in globals -> 0
float4 bornMask1;    // slot3.xyzw  NOT in globals -> 0
float  bornMask2;    // slot4.x     NOT in globals -> 0
float3 surviveMask0; // slot4.yzw   NOT in globals -> 0
float4 surviveMask1; // slot5.xyzw  NOT in globals -> 0
float2 surviveMask2; // slot6.xy    NOT in globals -> 0
int   source;        // slot6.z  globals.source.uniform, [0,7], default 0

// ca program (uniformLayouts.ca):
//   resolution -> slot0.xy (engine global, aliased), time -> slot0.z (engine),
//   smoothing  -> slot1.y
int   smoothing;     // globals.smoothing.uniform, default 0 (constant)

// =============================================================================
// caFb helpers — ported verbatim from caFb.wgsl
// =============================================================================

// lum(color) — luminance weights, verbatim.
float ca_lum(float3 color)
{
    return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
}

// random(st) — sin-hash variant from caFb.wgsl (NOT PCG). Inlined verbatim.
float ca_random(float2 st)
{
    return frac(sin(dot(st, float2(12.9898, 78.233))) * 43758.5453123);
}

// shouldBeBorn(n, ruleIndex) — curated born table, verbatim from caFb.wgsl.
bool ca_shouldBeBorn(int n, int ruleIndex)
{
    bool should = false;

    if (ruleIndex == 0 || ruleIndex == 5 || ruleIndex == 8) {
        should = n == 3;                                        // Classic Life, Life w/o Death, Maze: B3
    } else if (ruleIndex == 1 || ruleIndex == 11 || ruleIndex == 16) {
        should = n == 3 || n == 6;                              // Highlife, 2x2, Waffles: B36
    } else if (ruleIndex == 2) {
        should = n == 2;                                        // Seeds: B2
    } else if (ruleIndex == 3) {
        should = n == 3 || n == 8;                              // Coral: B38
    } else if (ruleIndex == 4) {
        should = n == 3 || n == 6 || n == 7 || n == 8;          // Day & Night: B3678
    } else if (ruleIndex == 6) {
        should = n == 1 || n == 3 || n == 5 || n == 7;          // Replicator: B1357
    } else if (ruleIndex == 7) {
        should = n == 3 || n == 5 || n == 7;                    // Amoeba: B357
    } else if (ruleIndex == 9) {
        should = n == 2 || n == 5;                              // Glider Walk: B25
    } else if (ruleIndex == 10) {
        should = n == 3 || n >= 5;                              // Diamoeba: B35678
    } else if (ruleIndex == 12) {
        should = n == 3 || n == 6 || n == 8;                    // Morley: B368
    } else if (ruleIndex == 13) {
        should = n == 4 || n == 6 || n == 7 || n == 8;          // Anneal: B4678
    } else if (ruleIndex == 14) {
        should = n == 3 || n == 4;                              // 34 Life: B34
    } else if (ruleIndex == 15) {
        should = n == 3 || n == 6 || n == 8;                    // Simple Replicator: B368
    } else if (ruleIndex == 17) {
        should = n == 3 || n == 7;                              // Pond Life: B37
    }

    return should;
}

// shouldSurvive(n, current, ruleIndex) — curated survive table, verbatim.
bool ca_shouldSurvive(int n, float current, int ruleIndex)
{
    bool should = false;

    if (ruleIndex == 0 || ruleIndex == 1 || ruleIndex == 3 || ruleIndex == 17) {
        should = n == 2 || n == 3;                              // Classic Life, Highlife, Coral, Pond Life: S23
    } else if (ruleIndex == 2) {
        should = false;                                         // Seeds: no survival
    } else if (ruleIndex == 4) {
        should = n == 3 || n == 4 || n == 6 || n == 7 || n == 8;  // Day & Night: S34678
    } else if (ruleIndex == 5) {
        should = true;                                          // Life w/o Death: S012345678
    } else if (ruleIndex == 6) {
        should = n == 1 || n == 3 || n == 5 || n == 7;          // Replicator: S1357
    } else if (ruleIndex == 7) {
        should = n == 1 || n == 3 || n == 5 || n == 8;          // Amoeba: S1358
    } else if (ruleIndex == 8) {
        should = n >= 1 && n <= 5;                              // Maze: S12345
    } else if (ruleIndex == 9) {
        should = n == 4;                                        // Glider Walk: S4
    } else if (ruleIndex == 10) {
        should = n >= 5;                                        // Diamoeba: S5678
    } else if (ruleIndex == 11) {
        should = n == 1 || n == 2 || n == 5;                    // 2x2: S125
    } else if (ruleIndex == 12 || ruleIndex == 16) {
        should = n == 2 || n == 4 || n == 5;                    // Morley, Waffles: S245
    } else if (ruleIndex == 13) {
        should = n == 3 || n >= 5;                              // Anneal: S35678
    } else if (ruleIndex == 14) {
        should = n == 3 || n == 4;                              // 34 Life: S34
    } else if (ruleIndex == 15) {
        should = n == 1 || n == 2 || n == 5 || n >= 7;          // Simple Replicator: S12578
    }

    if (current < 0.5) { should = false; }

    return should;
}

// shouldBeBornCustom — custom born mask lookup, verbatim from caFb.wgsl.
bool ca_shouldBeBornCustom(int n, float4 bornMask0, float4 bornMask1, float bornMask2)
{
    if (n == 0) { return bornMask0.x > 0.5; }
    else if (n == 1) { return bornMask0.y > 0.5; }
    else if (n == 2) { return bornMask0.z > 0.5; }
    else if (n == 3) { return bornMask0.w > 0.5; }
    else if (n == 4) { return bornMask1.x > 0.5; }
    else if (n == 5) { return bornMask1.y > 0.5; }
    else if (n == 6) { return bornMask1.z > 0.5; }
    else if (n == 7) { return bornMask1.w > 0.5; }
    else if (n == 8) { return bornMask2 > 0.5; }
    return false;
}

// shouldSurviveCustom — custom survive mask lookup, verbatim from caFb.wgsl.
bool ca_shouldSurviveCustom(int n, float current, float3 surviveMask0, float4 surviveMask1, float2 surviveMask2)
{
    bool should = false;
    if (n == 0) { should = surviveMask0.x > 0.5; }
    else if (n == 1) { should = surviveMask0.y > 0.5; }
    else if (n == 2) { should = surviveMask0.z > 0.5; }
    else if (n == 3) { should = surviveMask1.x > 0.5; }
    else if (n == 4) { should = surviveMask1.y > 0.5; }
    else if (n == 5) { should = surviveMask1.z > 0.5; }
    else if (n == 6) { should = surviveMask1.w > 0.5; }
    else if (n == 7) { should = surviveMask2.x > 0.5; }
    else if (n == 8) { should = surviveMask2.y > 0.5; }

    if (current < 0.5) { should = false; }
    return should;
}

// clampCoord(p, size) — clamp integer texel coord into [0, size-1], verbatim.
int2 ca_clampCoord(int2 p, int2 size)
{
    int cx = clamp(p.x, 0, size.x - 1);
    int cy = clamp(p.y, 0, size.y - 1);
    return int2(cx, cy);
}

// cellAt(p, size) — integer fetch of the .r channel from bufTex (textureLoad).
float ca_cellAt(int2 p, int2 size)
{
    int2 pc = ca_clampCoord(p, size);
    return bufTex.Load(int3(pc, 0)).r;
}

// countNeighbors(base, size) — Moore-neighbourhood alive count, verbatim.
int ca_countNeighbors(int2 base, int2 size)
{
    int count = 0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) { continue; }
            float n = ca_cellAt(base + int2(dx, dy), size);
            count += (int)(n > 0.5);
        }
    }
    return count;
}

// =============================================================================
// Pass "update" (program "caFb") — advance the CA grid. Output -> global_ca_state.
// WGSL: @fragment fn main(@builtin(position) fragCoord) -> @location(0) vec4
// =============================================================================
float4 frag_caFb(NMVaryings i) : SV_Target
{
    // fragCoord (top-left, +0.5-centered). The render target is the state grid,
    // so resolution == grid size == textureDimensions(bufTex).
    float2 fragCoord = NM_FragCoord(i);

    uint bw, bh;
    bufTex.GetDimensions(bw, bh);
    float2 texSize  = float2((float)bw, (float)bh);
    int2   texSizeI = int2((int)bw, (int)bh);
    float2 uv = fragCoord / texSize;

    // Parameter extraction mirrors the WGSL slot mapping. `deltaTime` here is the
    // engine-provided alias from NMFullscreen (data[0].y in the WGSL UBO).
    bool resetStateB = resetState > 0.5;
    bool useCustomB  = useCustom > 0.5;

    // Sample all 4 channels to check if buffer is truly empty (textureLoad).
    int2  base = int2((int)fragCoord.x, (int)fragCoord.y);
    float4 bufState = bufTex.Load(int3(ca_clampCoord(base, texSizeI), 0));
    float state = bufState.r;
    bool bufferIsEmpty = (bufState.r == 0.0 && bufState.g == 0.0 && bufState.b == 0.0 && bufState.a == 0.0);

    // Sample previous frame for luminance perturbation (before early return for
    // uniform control flow), via filtered sampler on the input surface `tex`.
    float3 prevFrame = tex.Sample(sampler_tex, uv).rgb;
    float  prevLum   = ca_lum(prevFrame);

    // Initialize when reset pressed or buffer empty (first load).
    if (resetStateB || bufferIsEmpty) {
        float r = ca_random(uv + float2((float)seed, (float)seed));
        float alive = step(0.5, r);
        return float4(alive, alive, alive, 1.0);
    }

    int neighbors = ca_countNeighbors(base, texSizeI);

    float newState = state;

    if (useCustomB) {
        if (ca_shouldBeBornCustom(neighbors, bornMask0, bornMask1, bornMask2)) {
            newState = 1.0;
        } else if (ca_shouldSurviveCustom(neighbors, state, surviveMask0, surviveMask1, surviveMask2)) {
            newState = 1.0;
        } else {
            newState = 0.0;
        }
    } else {
        if (ca_shouldBeBorn(neighbors, ruleIndex)) {
            newState = 1.0;
        } else if (ca_shouldSurvive(neighbors, state, ruleIndex)) {
            newState = 1.0;
        } else {
            newState = 0.0;
        }
    }

    if (weight > 0.0) {
        newState = lerp(newState, prevLum, weight * 0.01);
    }

    // BPM-style speed remap to a stable integration step (map == nm_map).
    float animSpeed = nm_map(speed, 1.0, 100.0, 0.1, 100.0);
    float4 currentState = float4(state, state, state, 1.0);
    float4 nextState    = float4(newState, newState, newState, 1.0);
    return lerp(currentState, nextState, min(1.0, deltaTime * animSpeed));
}

// =============================================================================
// ca display helpers — ported verbatim from ca.wgsl
// =============================================================================

float4 ca_quadratic3(float4 p0, float4 p1, float4 p2, float t)
{
    float t2 = t * t;

    return p0 * 0.5 * (1.0 - t) * (1.0 - t) +
           p1 * 0.5 * (-2.0 * t2 + 2.0 * t + 1.0) +
           p2 * 0.5 * t2;
}

float4 ca_bicubic4(float4 p0, float4 p1, float4 p2, float4 p3, float t)
{
    float t2 = t * t;
    float t3 = t2 * t;

    float b0 = (1.0 - t) * (1.0 - t) * (1.0 - t) / 6.0;
    float b1 = (3.0 * t3 - 6.0 * t2 + 4.0) / 6.0;
    float b2 = (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) / 6.0;
    float b3 = t3 / 6.0;

    return p0 * b0 + p1 * b1 + p2 * b2 + p3 * b3;
}

// catmullRom3 — verbatim from ca.wgsl (note: uses local `m = 0.5*(p2-p0)` form,
// distinct from the GLSL's expanded redundant form; we follow the WGSL Golden #1).
float4 ca_catmullRom3(float4 p0, float4 p1, float4 p2, float t)
{
    float t2 = t * t;
    float t3 = t2 * t;

    float4 m = 0.5 * (p2 - p0);

    return (2.0*t3 - 3.0*t2 + 1.0) * p1 +
           (t3 - 2.0*t2 + t) * m +
           (-2.0*t3 + 3.0*t2) * p2 +
           (t3 - t2) * m;
}

float4 ca_catmullRom4(float4 p0, float4 p1, float4 p2, float4 p3, float t)
{
    return p1 + 0.5 * t * (p2 - p0 + t * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 + t * (3.0 * (p1 - p2) + p3 - p0)));
}

// quadraticSample (b-spline 3x3) — filtered taps via textureSampleLevel(0).
float4 ca_quadraticSample(float2 uv, float2 texelSize)
{
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

    float4 y0 = ca_quadratic3(v00, v10, v20, f.x);
    float4 y1 = ca_quadratic3(v01, v11, v21, f.x);
    float4 y2 = ca_quadratic3(v02, v12, v22, f.x);

    return ca_quadratic3(y0, y1, y2, f.y);
}

// catmullRom3x3Sample — 9-tap Catmull-Rom.
float4 ca_catmullRom3x3Sample(float2 uv, float2 texelSize)
{
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

    float4 y0 = ca_catmullRom3(v00, v10, v20, f.x);
    float4 y1 = ca_catmullRom3(v01, v11, v21, f.x);
    float4 y2 = ca_catmullRom3(v02, v12, v22, f.x);

    return ca_catmullRom3(y0, y1, y2, f.y);
}

// bicubicSample (b-spline 4x4) — 16-tap.
float4 ca_bicubicSample(float2 uv, float2 texelSize)
{
    float2 uv2 = uv + texelSize;
    float2 texCoord = uv2 / texelSize;
    float2 baseCoord = floor(texCoord - 1.0);
    float2 f = frac(texCoord - 1.0);

    float4 row0 = ca_bicubic4(
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2(-0.5, -0.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 0.5, -0.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 1.5, -0.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 2.5, -0.5)) * texelSize, 0.0),
        f.x
    );

    float4 row1 = ca_bicubic4(
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2(-0.5,  0.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 0.5,  0.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 1.5,  0.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 2.5,  0.5)) * texelSize, 0.0),
        f.x
    );

    float4 row2 = ca_bicubic4(
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2(-0.5,  1.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 0.5,  1.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 1.5,  1.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 2.5,  1.5)) * texelSize, 0.0),
        f.x
    );

    float4 row3 = ca_bicubic4(
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2(-0.5,  2.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 0.5,  2.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 1.5,  2.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 2.5,  2.5)) * texelSize, 0.0),
        f.x
    );

    return ca_bicubic4(row0, row1, row2, row3, f.y);
}

// catmullRom4x4Sample — 16-tap Catmull-Rom.
float4 ca_catmullRom4x4Sample(float2 uv, float2 texelSize)
{
    float2 uv2 = uv + texelSize;
    float2 texCoord = uv2 / texelSize;
    float2 baseCoord = floor(texCoord - 1.0);
    float2 f = frac(texCoord - 1.0);

    float4 row0 = ca_catmullRom4(
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2(-0.5, -0.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 0.5, -0.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 1.5, -0.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 2.5, -0.5)) * texelSize, 0.0),
        f.x
    );

    float4 row1 = ca_catmullRom4(
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2(-0.5,  0.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 0.5,  0.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 1.5,  0.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 2.5,  0.5)) * texelSize, 0.0),
        f.x
    );

    float4 row2 = ca_catmullRom4(
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2(-0.5,  1.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 0.5,  1.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 1.5,  1.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 2.5,  1.5)) * texelSize, 0.0),
        f.x
    );

    float4 row3 = ca_catmullRom4(
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2(-0.5,  2.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 0.5,  2.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 1.5,  2.5)) * texelSize, 0.0),
        fbTex.SampleLevel(sampler_fbTex, (baseCoord + float2( 2.5,  2.5)) * texelSize, 0.0),
        f.x
    );

    return ca_catmullRom4(row0, row1, row2, row3, f.y);
}

float ca_cosineMix(float a, float b, float t)
{
    float amount = (1.0 - cos(t * 3.141592653589793)) * 0.5;
    return lerp(a, b, amount);
}

// =============================================================================
// Pass "render" (program "ca") — reconstruct/upsample the grid into outputTex.
// WGSL: @fragment fn main(@builtin(position) fragCoord) -> @location(0) vec4
//   resolution = uniforms.data[0].xy (engine resolution), smoothing = data[1].y.
// WGSL uses fragCoord.xy directly (NO tileOffset) -> NM_FragCoord(i).
// =============================================================================
float4 frag_ca(NMVaryings i) : SV_Target
{
    float2 fragCoord = NM_FragCoord(i);
    // `resolution` is the engine-provided alias (render-target size).
    float2 res = resolution;

    float state = 0.0;
    if (smoothing == 0) {
        // constant - textureLoad for exact nearest-neighbour sampling
        uint fw, fh;
        fbTex.GetDimensions(fw, fh);
        int2  texSizeI = int2((int)fw, (int)fh);
        float2 texSizeF = float2((float)texSizeI.x, (float)texSizeI.y);
        int2  pixelCoord = int2(floor(fragCoord * texSizeF / res));
        state = fbTex.Load(int3(clamp(pixelCoord, int2(0, 0), texSizeI - int2(1, 1)), 0)).g;
    } else if (smoothing == 3) {
        uint fw, fh; fbTex.GetDimensions(fw, fh);
        float2 texSize = float2((float)fw, (float)fh);
        float2 texelSize = 1.0 / texSize;
        float2 scaling = res / texSize;
        float2 uv = (fragCoord - scaling * 0.5) / res;
        state = ca_catmullRom3x3Sample(uv, texelSize).g;
    } else if (smoothing == 4) {
        uint fw, fh; fbTex.GetDimensions(fw, fh);
        float2 texSize = float2((float)fw, (float)fh);
        float2 texelSize = 1.0 / texSize;
        float2 scaling = res / texSize;
        float2 uv = (fragCoord - scaling * 0.5) / res;
        state = ca_catmullRom4x4Sample(uv, texelSize).g;
    } else if (smoothing == 5) {
        uint fw, fh; fbTex.GetDimensions(fw, fh);
        float2 texSize = float2((float)fw, (float)fh);
        float2 texelSize = 1.0 / texSize;
        float2 scaling = res / texSize;
        float2 uv = (fragCoord - scaling * 0.5) / res;
        state = ca_quadraticSample(uv, texelSize).g;
    } else if (smoothing == 6) {
        uint fw, fh; fbTex.GetDimensions(fw, fh);
        float2 texSize = float2((float)fw, (float)fh);
        float2 texelSize = 1.0 / texSize;
        float2 scaling = res / texSize;
        float2 uv = (fragCoord - scaling * 0.5) / res;
        state = ca_bicubicSample(uv, texelSize).g;
    } else {
        // linear-style smoothing — sample texel centres explicitly (textureLoad).
        uint fw, fh; fbTex.GetDimensions(fw, fh);
        float2 texSize = float2((float)fw, (float)fh);
        float2 texelPos = (fragCoord * texSize / res) - float2(0.5, 0.5);
        float2 base = floor(texelPos);
        float2 weights = frac(texelPos);
        float2 next = base + float2(1.0, 1.0);

        int2 texSizeI = int2((int)fw, (int)fh);
        int2 minIdx = int2(0, 0);
        int2 maxIdx = texSizeI - int2(1, 1);
        int2 baseI = clamp((int2)base, minIdx, maxIdx);
        int2 nextI = clamp((int2)next, minIdx, maxIdx);

        float v00 = fbTex.Load(int3(baseI, 0)).g;
        float v10 = fbTex.Load(int3(int2(nextI.x, baseI.y), 0)).g;
        float v01 = fbTex.Load(int3(int2(baseI.x, nextI.y), 0)).g;
        float v11 = fbTex.Load(int3(nextI, 0)).g;

        if (smoothing == 1) {
            float v0 = lerp(v00, v10, weights.x);
            float v1 = lerp(v01, v11, weights.x);
            state = lerp(v0, v1, weights.y);
        } else {
            float v0 = ca_cosineMix(v00, v10, weights.x);
            float v1 = ca_cosineMix(v01, v11, weights.x);
            state = ca_cosineMix(v0, v1, weights.y);
        }
    }

    // Mono output only
    float intensity = clamp(state, 0.0, 1.0);
    return float4(intensity, intensity, intensity, 1.0);
}

#endif // NM_EFFECT_CELLULARAUTOMATA_INCLUDED
