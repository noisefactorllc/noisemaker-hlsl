#ifndef NM_EFFECT_ROLL_INCLUDED
#define NM_EFFECT_ROLL_INCLUDED

// =============================================================================
// Roll.hlsl — synth/roll (func: "roll") — MIDI piano roll visualizer
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL sources:
//   shaders/effects/synth/roll/wgsl/roll.wgsl  (progName "roll",  pass "scroll")
//   shaders/effects/synth/roll/wgsl/copy.wgsl  (progName "copy",  pass "feedback")
//
// MULTI-PASS + FEEDBACK. Per definition.js the runtime drives two passes/frame:
//   1. "scroll" (program "roll"):  inputs feedbackTex=_rollFb, noteGridTex=
//      midiNoteGrid -> outputs fragColor=outputTex. Scrolls the persistent
//      feedback right, samples the engine-uploaded MIDI note grid, writes new
//      notes at the left edge, draws lane separators.
//   2. "feedback" (program "copy"): inputs inputTex=outputTex -> outputs
//      fragColor=_rollFb. Copies this frame's output back into the persistent
//      feedback target so the next frame's "scroll" can read it.
//
// `_rollFb` is the PERSISTENT (leading-'_') feedback texture (rgba16f, full res).
// `midiNoteGrid` is an ENGINE-PROVIDED data texture (128x16 RGBA float), uploaded
// each frame by the runtime (reference/04 §step-flow MIDI). `outputTex` is the
// transient pass output. NO repeat:, NO MRT, NO blend (both passes Blend Off).
//
// SHADER GRAPH: this effect is multi-pass + feedback, so it ships as a runtime-
// rendered Texture2D. No Shader Graph Custom Function wrapper is provided.
//
// PORTING-GUIDE notes / hazards handled:
//  * Ported from WGSL (top-left, canonical). roll.wgsl uses `uv = pos.xy /
//    resolution` (per-tile resolution, NO tileOffset). The GLSL variant instead
//    uses globalCoord = gl_FragCoord + tileOffset over fullResolution AND a
//    dynamic neighbour spread (`spread = ceil(keysPerPixel)`, loop -spread..spread).
//    Per Golden Rule 1 we port the WGSL: NM_FragCoord(i)/resolution and the FIXED
//    spread loop dk = -2..2. // TODO(verify) parity vs GLSL when tiled (tileOffset
//    != 0) or when renderScale changes the lane-pixel density.
//  * copy.wgsl: uv = pos.xy / textureDimensions(inputTex) (the input texture's own
//    size). Mirrored as NM_FragCoord(i)/inputTex size.
//  * step(0.0, x) -> HLSL step(0.0, x) (1 if x>=0 else 0); matches WGSL.
//  * i32(floor(..)) -> (int)floor(..) truncation; clamp(int,0,127) maps 1:1.
//  * Linear, clamp-to-edge, non-sRGB samplers (H7) — set in Roll.shader.
//  * No nm_mod / random / pcg usage in this effect (no NMCore helpers needed
//    beyond the engine globals provided by NMFullscreen.hlsl).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Persistent feedback input (pass "scroll": feedbackTex = _rollFb) --------
Texture2D    feedbackTex;
SamplerState sampler_feedbackTex;

// ---- Engine MIDI note grid (pass "scroll": noteGridTex = midiNoteGrid) -------
// 128 (keys) x 16 (channels), RGBA float: .r = velocity, .g = gate (>0.5 = on).
Texture2D    noteGridTex;
SamplerState sampler_noteGridTex;

// ---- Copy-pass input (pass "feedback": inputTex = outputTex) -----------------
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
float3 lineColor; // globals.color.uniform="lineColor", default (0,1,0)
float  gain;      // globals.gain.uniform="gain",       default 1.0  [0.1,5.0]
float  speed;     // globals.speed.uniform="speed",     default 1.0  [0.5,5.0]

// -----------------------------------------------------------------------------
// frag_roll — verbatim port of roll.wgsl main() (pass "scroll", program "roll").
//
// WGSL:
//   let uv = pos.xy / resolution;
//   let scrollAmount = speed * deltaTime * 0.5;
//   let scrollUv = vec2<f32>(max(uv.x - scrollAmount, 0.0), uv.y);
//   var prev = textureSample(feedbackTex, feedbackSampler, scrollUv) * 0.997;
//   prev *= step(0.0, uv.x - scrollAmount);
//   ... 16 lanes, keys 36-84, fixed spread -2..2, edge write, lane separators ...
//   return vec4<f32>(lineColor * brightness, 1.0);
// -----------------------------------------------------------------------------
float4 frag_roll(NMVaryings i) : SV_Target
{
    float2 uv = NM_FragCoord(i) / resolution;

    // Scroll feedback right (notes enter at left)
    float scrollAmount = speed * deltaTime * 0.5;
    float2 scrollUv = float2(max(uv.x - scrollAmount, 0.0), uv.y);
    float4 prev = feedbackTex.Sample(sampler_feedbackTex, scrollUv) * 0.997;
    prev *= step(0.0, uv.x - scrollAmount);

    // 16 MIDI channels as horizontal swim lanes
    float laneF = uv.y * 16.0;
    int channel = (int)floor(laneF);
    float laneLocal = frac(laneF);

    // Each lane maps to MIDI keys 36-84 (C2-C6, 4 octaves)
    int keyLow = 36;
    int keyRange = 48;
    float keyExact = (float)keyLow + laneLocal * (float)keyRange;
    int key = (int)floor(keyExact);

    // Sample note grid with fixed spread for visibility
    float maxVel = 0.0;
    [loop]
    for (int dk = -2; dk <= 2; dk++)
    {
        int k = clamp(key + dk, 0, 127);
        float2 gridUv = float2(((float)k + 0.5) / 128.0, ((float)channel + 0.5) / 16.0);
        float4 noteData = noteGridTex.Sample(sampler_noteGridTex, gridUv);
        if (noteData.g > 0.5)
        {
            maxVel = max(maxVel, noteData.r);
        }
    }

    // Write new note data at the left edge
    float edgeWidth = 4.0 / resolution.x;
    float noteVal = 0.0;
    if (uv.x < edgeWidth && maxVel > 0.0)
    {
        noteVal = maxVel * gain;
    }

    // Lane separator lines
    float laneSep = 0.0;
    float laneEdge = frac(uv.y * 16.0);
    if (laneEdge < 0.02 || laneEdge > 0.98)
    {
        laneSep = 0.2;
    }

    float prevBright = max(prev.r, max(prev.g, prev.b));
    float brightness = max(prevBright, max(noteVal, laneSep));
    float3 col = lineColor * brightness;

    return float4(col, 1.0);
}

// -----------------------------------------------------------------------------
// frag_copy — verbatim port of copy.wgsl main() (pass "feedback", program "copy").
//
// WGSL:
//   let dims = vec2<f32>(textureDimensions(inputTex, 0));
//   let uv = pos.xy / dims;
//   return textureSample(inputTex, inputSampler, uv);
// -----------------------------------------------------------------------------
float4 frag_copy(NMVaryings i) : SV_Target
{
    uint w, h;
    inputTex.GetDimensions(w, h);
    float2 dims = float2((float)w, (float)h);
    float2 uv = NM_FragCoord(i) / dims;
    return inputTex.Sample(sampler_inputTex, uv);
}

#endif // NM_EFFECT_ROLL_INCLUDED
