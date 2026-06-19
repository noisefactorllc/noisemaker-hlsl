#ifndef NM_EFFECT_FEEDBACK_INCLUDED
#define NM_EFFECT_FEEDBACK_INCLUDED

// =============================================================================
// Feedback.hlsl — filter/feedback (func: "feedback")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL sources:
//   shaders/effects/filter/feedback/wgsl/feedback.wgsl  (progName "feedback")
//   shaders/effects/filter/feedback/wgsl/copy.wgsl       (progName "copy")
//
// MULTI-PASS / FEEDBACK effect (2 passes):
//   pass "main"     (program "feedback"): inputTex + _selfTex  -> outputTex
//   pass "feedback" (program "copy"):     outputTex            -> _selfTex
// `_selfTex` is a PERSISTENT ('_'-prefixed) feedback buffer: the "main" pass
// samples the PREVIOUS frame's feedback image from _selfTex, and the "copy"
// pass snapshots this frame's outputTex back into _selfTex for next frame. The
// C# runtime owns the ping-pong / persistence (reference 04 §10.7 — _selfTex is
// a state surface that persists across frames, NOT swapped like a display surf).
//
// This effect is multi-pass and ships as a runtime-rendered Texture2D; the C#
// runtime renders "feedback" then "copy" in definition order. No Shader Graph
// Custom Function wrapper is provided (multi-pass → runtime-rendered).
//
// PORTING-GUIDE notes / hazards handled:
//  * Ported from WGSL (top-left, canonical) — no per-effect Y flip.
//  * uv = pos.xy / resolution  →  NM_FragCoord(i) / resolution (top-left, +0.5).
//    The copy pass uses uv = pos.xy / textureDimensions(inputTex).
//  * The effect's local `map()` is identical to NMCore nm_map (verified) — used.
//  * The effect's local `floorMod(x,y)=x-y*floor(x/y)` is identical to NMCore
//    nm_mod (verified). WGSL `%` float modulo (hsv2rgb) and GLSL `mod()` are both
//    floored mod here, so we use nm_mod for both (PORTING-GUIDE H6: never fmod).
//  * Helpers blendOverlay/blendSoftLight/blend/brightnessContrast/rotate2D/
//    hsv2rgb/rgb2hsv/getImage/cloak are this effect's OWN versions — copied
//    verbatim inline (PORTING-GUIDE rule 2). Do NOT substitute generic versions.
//  * WGSL `switch` → HLSL `if/else if` chain (matches the GLSL disambiguator,
//    same branch order and bodies).
//  * WGSL `select(a, b, cond)` returns a when !cond, b when cond → HLSL `cond?b:a`.
//    rgb2hsv: `select(delta/maxC, 0.0, maxC==0.0)` → `(maxC==0.0)?0.0:delta/maxC`.
//  * `all(color == vec4(k))` → all(color == k.xxxx) componentwise equality.
//  * blendMode/resetState are int uniforms; resetState tested `!= 0` (WGSL).
//  * Linear, clamp-to-edge, non-sRGB sampler (set on SamplerState in .shader).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input textures + samplers (one SamplerState per distinct sampler) -------
// "main" pass binds inputTex (live input) and selfTex (= persistent _selfTex,
// previous-frame feedback). "copy" pass binds inputTex (= outputTex). The
// runtime rebinds the HLSL `inputTex` slot per pass.
Texture2D    inputTex;
SamplerState sampler_inputTex;
Texture2D    selfTex;
SamplerState sampler_selfTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
int   blendMode;     // globals.blendMode.uniform, default 10 (mix)
float mixAmt;        // globals.mix.uniform, [0,100] default 0
float scaleAmt;      // globals.scaleAmt.uniform, [75,200] default 100
float rotation;      // globals.rotation.uniform, [-180,180] default 0
float refractAAmt;   // globals.refractAAmt.uniform, [0,100] default 0
float refractBAmt;   // globals.refractBAmt.uniform, [0,100] default 0
float refractADir;   // globals.refractADir.uniform, [0,360] default 0
float refractBDir;   // globals.refractBDir.uniform, [0,360] default 0
float hueRotation;   // globals.hueRotation.uniform, [-180,180] default 0
float intensity;     // globals.intensity.uniform, [-100,100] default 0
float aberration;    // globals.aberration.uniform, [0,100] default 0
float distortion;    // globals.distortion.uniform, [-100,100] default 0
int   resetState;    // globals.resetState.uniform, default 0 (false)

static const float PI  = 3.14159265359;
static const float TAU = 6.28318530718;

// -----------------------------------------------------------------------------
// Effect-local helpers — verbatim from feedback.wgsl. nm_map == local map(),
// nm_mod == local floorMod() (both verified identical), so we call those.
// -----------------------------------------------------------------------------

float blendOverlay(float a, float b)
{
    if (a < 0.5) { return 2.0 * a * b; }
    else { return 1.0 - 2.0 * (1.0 - a) * (1.0 - b); }
}

float blendSoftLight(float base, float blendv)
{
    if (blendv < 0.5) {
        return 2.0 * base * blendv + base * base * (1.0 - 2.0 * blendv);
    } else {
        return sqrt(base) * (2.0 * blendv - 1.0) + 2.0 * base * (1.0 - blendv);
    }
}

float4 blend(float4 color1, float4 color2, int mode, float factor)
{
    float4 middle;
    float amt = nm_map(mixAmt, 0.0, 100.0, 0.0, 1.0);

    if (mode == 0) { // add
        middle = min(color1 + color2, float4(1.0, 1.0, 1.0, 1.0));
    } else if (mode == 2) { // color burn
        if (all(color2 == float4(0.0, 0.0, 0.0, 0.0))) {
            middle = color2;
        } else {
            middle = max(1.0 - ((1.0 - color1) / color2), float4(0.0, 0.0, 0.0, 0.0));
        }
    } else if (mode == 3) { // color dodge
        if (all(color2 == float4(1.0, 1.0, 1.0, 1.0))) {
            middle = color2;
        } else {
            middle = min(color1 / (1.0 - color2), float4(1.0, 1.0, 1.0, 1.0));
        }
    } else if (mode == 4) { // darken
        middle = min(color1, color2);
    } else if (mode == 5) { // difference
        middle = abs(color1 - color2);
        middle.a = max(color1.a, color2.a);
    } else if (mode == 6) { // exclusion
        middle = color1 + color2 - 2.0 * color1 * color2;
        middle.a = max(color1.a, color2.a);
    } else if (mode == 7) { // glow
        if (all(color2 == float4(1.0, 1.0, 1.0, 1.0))) {
            middle = color2;
        } else {
            middle = min(color1 * color1 / (1.0 - color2), float4(1.0, 1.0, 1.0, 1.0));
        }
    } else if (mode == 8) { // hard light
        middle = float4(
            blendOverlay(color2.r, color1.r),
            blendOverlay(color2.g, color1.g),
            blendOverlay(color2.b, color1.b),
            lerp(color1.a, color2.a, 0.5)
        );
    } else if (mode == 9) { // lighten
        middle = max(color1, color2);
    } else if (mode == 10) { // mix
        middle = lerp(color1, color2, 0.5);
    } else if (mode == 11) { // multiply
        middle = color1 * color2;
    } else if (mode == 12) { // negation
        middle = float4(1.0, 1.0, 1.0, 1.0) - abs(float4(1.0, 1.0, 1.0, 1.0) - color1 - color2);
        middle.a = max(color1.a, color2.a);
    } else if (mode == 13) { // overlay
        middle = float4(
            blendOverlay(color1.r, color2.r),
            blendOverlay(color1.g, color2.g),
            blendOverlay(color1.b, color2.b),
            lerp(color1.a, color2.a, 0.5)
        );
    } else if (mode == 14) { // phoenix
        middle = min(color1, color2) - max(color1, color2) + float4(1.0, 1.0, 1.0, 1.0);
    } else if (mode == 15) { // reflect
        if (all(color1 == float4(1.0, 1.0, 1.0, 1.0))) {
            middle = color1;
        } else {
            middle = min(color2 * color2 / (1.0 - color1), float4(1.0, 1.0, 1.0, 1.0));
        }
    } else if (mode == 16) { // screen
        middle = 1.0 - ((1.0 - color1) * (1.0 - color2));
    } else if (mode == 17) { // soft light
        middle = float4(
            blendSoftLight(color1.r, color2.r),
            blendSoftLight(color1.g, color2.g),
            blendSoftLight(color1.b, color2.b),
            lerp(color1.a, color2.a, 0.5)
        );
    } else if (mode == 18) { // subtract
        middle = max(color1 + color2 - 1.0, float4(0.0, 0.0, 0.0, 0.0));
    } else { // default fallback to mix
        middle = lerp(color1, color2, 0.5);
    }

    float4 color;
    if (factor == 0.5) {
        color = middle;
    } else if (factor < 0.5) {
        float f = nm_map(amt, 0.0, 0.5, 0.0, 1.0);
        color = lerp(color1, middle, f);
    } else {
        float f = nm_map(amt, 0.5, 1.0, 0.0, 1.0);
        color = lerp(middle, color2, f);
    }

    return color;
}

float3 brightnessContrast(float3 color)
{
    float bright = nm_map(intensity * 0.1, -100.0, 100.0, -0.5, 0.5);
    float cont   = nm_map(intensity * 0.1, -100.0, 100.0, 0.5, 1.5);
    return (color - 0.5) * cont + 0.5 + bright;
}

float2 rotate2D(float2 st_in, float rot)
{
    float aspect = resolution.x / resolution.y;
    float2 st = st_in;
    st.x *= aspect;
    float rotNorm = nm_map(rot, 0.0, 360.0, 0.0, 2.0);
    float angle = rotNorm * PI;
    st -= float2(0.5 * aspect, 0.5);
    float c = cos(angle);
    float s = sin(angle);
    st = float2(c * st.x - s * st.y, s * st.x + c * st.y);
    st += float2(0.5 * aspect, 0.5);
    st.x /= aspect;
    return st;
}

float3 hsv2rgb(float3 hsv)
{
    float h = frac(hsv.x);
    float s = hsv.y;
    float v = hsv.z;

    float c = v * s;
    float x = c * (1.0 - abs(nm_mod(h * 6.0, 2.0) - 1.0));
    float m = v - c;

    float3 rgb;
    if (h < 1.0 / 6.0) {
        rgb = float3(c, x, 0.0);
    } else if (h < 2.0 / 6.0) {
        rgb = float3(x, c, 0.0);
    } else if (h < 3.0 / 6.0) {
        rgb = float3(0.0, c, x);
    } else if (h < 4.0 / 6.0) {
        rgb = float3(0.0, x, c);
    } else if (h < 5.0 / 6.0) {
        rgb = float3(x, 0.0, c);
    } else {
        rgb = float3(c, 0.0, x);
    }

    return rgb + float3(m, m, m);
}

float3 rgb2hsv(float3 rgb)
{
    float maxC = max(rgb.r, max(rgb.g, rgb.b));
    float minC = min(rgb.r, min(rgb.g, rgb.b));
    float delta = maxC - minC;

    float h = 0.0;
    if (delta != 0.0) {
        if (maxC == rgb.r) {
            h = nm_mod((rgb.g - rgb.b) / delta, 6.0) / 6.0;
        } else if (maxC == rgb.g) {
            h = ((rgb.b - rgb.r) / delta + 2.0) / 6.0;
        } else {
            h = ((rgb.r - rgb.g) / delta + 4.0) / 6.0;
        }
    }

    float s = (maxC == 0.0) ? 0.0 : delta / maxC;
    float v = maxC;

    return float3(h, s, v);
}

// getImage — samples the feedback buffer (selfTex) with transform, lensing,
// distortion, scale, tiling, and chromatic aberration. Verbatim from WGSL.
float4 getImage(float2 st_in)
{
    float2 st = rotate2D(st_in, rotation);

    // aberration and lensing
    float2 diff = float2(0.5, 0.5) - st;
    float centerDist = length(diff);

    float distort = 0.0;
    float zoom = 0.0;
    if (distortion < 0.0) {
        distort = nm_map(distortion, -100.0, 0.0, -2.0, 0.0);
        zoom    = nm_map(distortion, -100.0, 0.0, 0.04, 0.0);
    } else {
        distort = nm_map(distortion, 0.0, 100.0, 0.0, 2.0);
        zoom    = nm_map(distortion, 0.0, 100.0, 0.0, -1.0);
    }

    st = (st - diff * zoom) - diff * centerDist * centerDist * distort;

    // scale
    float scale = 100.0 / scaleAmt;
    if (scale == 0.0) {
        scale = 1.0;
    }
    st *= scale;

    // center
    st.x -= (scale * 0.5) - (0.5 - (1.0 / resolution.x * scale));
    st.y += (scale * 0.5) + (0.5 - (1.0 / resolution.y * scale)) - (scale);

    // nudge
    st += 1.0 / resolution;

    // tile
    st = frac(st);

    // chromatic aberration
    float aberrationOffset = nm_map(aberration, 0.0, 100.0, 0.0, 0.1) * centerDist * PI * 0.5;

    float redOffset = lerp(clamp(st.x + aberrationOffset, 0.0, 1.0), st.x, st.x);
    float4 red = selfTex.Sample(sampler_selfTex, float2(redOffset, st.y));

    float4 green = selfTex.Sample(sampler_selfTex, st);

    float blueOffset = lerp(st.x, clamp(st.x - aberrationOffset, 0.0, 1.0), st.x);
    float4 blue = selfTex.Sample(sampler_selfTex, float2(blueOffset, st.y));

    float4 tex = float4(red.r, green.g, blue.b, 1.0);
    tex = float4(tex.rgb * tex.a, tex.a);

    return tex;
}

// cloak — blendMode == 100 special path. Verbatim from WGSL.
float4 cloak(float2 st)
{
    float m  = nm_map(mixAmt, 0.0, 100.0, 0.0, 1.0);
    float ra = nm_map(refractAAmt, 0.0, 100.0, 0.0, 0.125);
    float rb = nm_map(refractBAmt, 0.0, 100.0, 0.0, 0.125);

    float4 leftColor  = inputTex.Sample(sampler_inputTex, st);
    float4 rightColor = selfTex.Sample(sampler_selfTex, st);

    float2 leftUV = st;
    float rightLen = length(rightColor.rgb);
    leftUV.x += cos(rightLen * TAU) * ra;
    leftUV.y += sin(rightLen * TAU) * ra;
    float4 leftRefracted = inputTex.Sample(sampler_inputTex, frac(leftUV));

    float2 rightUV = st;
    float leftLen = length(leftColor.rgb);
    rightUV.x += cos(leftLen * TAU) * rb;
    rightUV.y += sin(leftLen * TAU) * rb;
    float4 rightRefracted = selfTex.Sample(sampler_selfTex, frac(rightUV));

    float4 leftReflected  = min(rightRefracted * rightColor / (1.0 - leftRefracted * leftColor), float4(1.0, 1.0, 1.0, 1.0));
    float4 rightReflected = min(leftRefracted * leftColor / (1.0 - rightRefracted * rightColor), float4(1.0, 1.0, 1.0, 1.0));

    float4 left;
    float4 right;
    if (mixAmt < 50.0) {
        left  = lerp(leftRefracted, leftReflected, nm_map(mixAmt, 0.0, 50.0, 0.0, 1.0));
        right = rightReflected;
    } else {
        left  = leftReflected;
        right = lerp(rightReflected, rightRefracted, nm_map(mixAmt, 50.0, 100.0, 0.0, 1.0));
    }

    return lerp(left, right, m);
}

// -----------------------------------------------------------------------------
// Pass "main" (program "feedback") — feedback.wgsl @fragment main().
// inputTex (live) + selfTex (previous-frame feedback _selfTex) -> outputTex.
// -----------------------------------------------------------------------------
float4 frag_feedback(NMVaryings i) : SV_Target
{
    float2 uv = NM_FragCoord(i) / resolution;

    // If resetState is true, bypass feedback and return input directly
    if (resetState != 0) {
        return inputTex.Sample(sampler_inputTex, uv);
    }

    float4 color;

    if (blendMode == 100) {
        color = cloak(uv);
    } else {
        float ra = nm_map(refractAAmt, 0.0, 100.0, 0.0, 0.125);
        float rb = nm_map(refractBAmt, 0.0, 100.0, 0.0, 0.125);

        float4 leftColor  = inputTex.Sample(sampler_inputTex, uv);
        float4 rightColor = selfTex.Sample(sampler_selfTex, uv);

        float2 leftUV = uv;
        float rightLen = length(rightColor.rgb) + refractADir / 360.0;
        leftUV.x += cos(rightLen * TAU) * ra;
        leftUV.y += sin(rightLen * TAU) * ra;

        float2 rightUV = uv;
        float leftLen = length(leftColor.rgb) + refractBDir / 360.0;
        rightUV.x += cos(leftLen * TAU) * rb;
        rightUV.y += sin(leftLen * TAU) * rb;

        color = blend(inputTex.Sample(sampler_inputTex, leftUV), getImage(rightUV), blendMode, mixAmt * 0.01);
    }

    // hue rotation
    float3 hsv = rgb2hsv(color.rgb);
    hsv.x = frac(hsv.x + nm_map(hueRotation, -180.0, 180.0, -0.05, 0.05));
    color = float4(hsv2rgb(hsv), color.a);

    // brightness/contrast
    color = float4(brightnessContrast(color.rgb), color.a);

    return color;
}

// -----------------------------------------------------------------------------
// Pass "feedback" (program "copy") — copy.wgsl @fragment main().
// Snapshots outputTex (bound as inputTex) into _selfTex for the next frame.
// uv = pos.xy / textureDimensions(inputTex) (copy.wgsl divides by the input's
// OWN size, NOT resolution).
// -----------------------------------------------------------------------------
float4 frag_copy(NMVaryings i) : SV_Target
{
    uint w, h;
    inputTex.GetDimensions(w, h);
    float2 dims = float2((float)w, (float)h);
    float2 uv = NM_FragCoord(i) / dims;
    return inputTex.Sample(sampler_inputTex, uv);
}

#endif // NM_EFFECT_FEEDBACK_INCLUDED
