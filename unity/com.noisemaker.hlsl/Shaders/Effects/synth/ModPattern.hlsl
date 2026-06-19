#ifndef NM_MODPATTERN_INCLUDED
#define NM_MODPATTERN_INCLUDED

// =============================================================================
// ModPattern.hlsl — synth/modPattern, ported PIXEL-IDENTICALLY from the
// canonical WGSL source:
//   shaders/effects/synth/modPattern/wgsl/modPattern.wgsl
//
// Interference patterns from modulo operations. Single pass, no texture inputs.
//
// Helpers (glsl_mod / glsl_mod2, shape, smoothFract / smoothFract2 /
// smoothFract3) are ported VERBATIM and INLINE per PORTING-GUIDE.
// nm_mod (float-mod, floor-based) maps to glsl_mod / glsl_mod2 here.
//
// NUMERIC HAZARDS handled:
//  * glsl_mod  = x - y * floor(x/y)   (NEVER fmod — floors toward -inf)
//  * glsl_mod2 = component-wise glsl_mod for float2
//  * select(b, a, cond) in WGSL is (cond ? a : b) in HLSL — reversed!
//  * smoothing is i32(uniforms.data[3].w) — declared int uniform, matches.
//  * uv = (position.xy - res*0.5) / min(res.x, res.y)  — divides by min,
//    NOT fullResolution.y. position.xy = NM_FragCoord(i). // TODO(verify)
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
int   shape1;       // 0=plus 1=square 2=diamond    (global "shape1")
float scale1;       // [0.1, 20]   default 18.0      (global "scale1")
float repeat1;      // [0, 20]     default 5.0        (global "repeat1")
int   shape2;       // 0=plus 1=square 2=diamond    (global "shape2")
float scale2;       // [0.1, 10]   default 8.0        (global "scale2")
float repeat2;      // [0, 10]     default 8.0        (global "repeat2")
int   shape3;       // 0=plus 1=square 2=diamond    (global "shape3")
float scale3;       // [0.1, 20]   default 1.5        (global "scale3")
float repeat3;      // [0, 5]      default 1.5        (global "repeat3")
int   blend;        // 0=add 1=max 2=mix 3=rgb      (global "blend")
float smoothing;    // [0, 3]      default 0          (global "smoothing")
int   animMode;     // 0=shift 1=pan 2=phase         (global "animMode")
int   speed;        // [0, 5]      default 1          (global "speed")

static const float NMP_TAU = 6.28318530718;

// ---- glsl_mod: floor-based float mod (matches WGSL glsl_mod) ----------------
float nmp_glsl_mod(float x, float y)
{
    return x - y * floor(x / y);
}

float2 nmp_glsl_mod2(float2 x, float2 y)
{
    return x - y * floor(x / y);
}

// ---- shape: geometric distance from folded coords ---------------------------
// Verbatim from WGSL. p comes in as abs(mod(...) - 1), so components are [0,1].
float nmp_shape(int shapeIndex, float2 p)
{
    float v;
    if (shapeIndex < 1)
    {
        // plus
        v = max(p.x, p.y);
    }
    else if (shapeIndex < 2)
    {
        // square
        v = min(p.x, p.y);
    }
    else
    {
        // diamond
        v = abs(p.x - p.y);
    }
    return v;
}

// ---- smoothFract: single-component smooth fract using the smoothing uniform -
// WGSL: let smoothing = i32(uniforms.data[3].w);  (same as int uniform "smoothing")
float nmp_smoothFract(float x)
{
    float f = frac(x);
    float edgeWidth = (float)smoothing * 0.01;
    if (f > 1.0 - edgeWidth)
    {
        return smoothstep(0.0, edgeWidth, 1.0 - f);
    }
    return f;
}

float2 nmp_smoothFract2(float2 v)
{
    return float2(nmp_smoothFract(v.x), nmp_smoothFract(v.y));
}

float3 nmp_smoothFract3(float3 v)
{
    return float3(nmp_smoothFract(v.x), nmp_smoothFract(v.y), nmp_smoothFract(v.z));
}

// =============================================================================
// nm_modPattern — core per-pixel evaluation. fragCoord = NM_FragCoord(i).
// Mirrors WGSL main() exactly.
// =============================================================================
float4 nm_modPattern(float2 fragCoord)
{
    // Unpack: match WGSL's `res` guard
    float2 res = resolution;
    if (res.x < 1.0) { res = float2(1024.0, 1024.0); }

    // Normalized coordinates: centered, divided by min dimension
    float2 uv = (fragCoord - res * 0.5) / min(res.x, res.y);

    float spd = floor((float)speed);
    float anim = time * spd;

    // Layer 1
    float s1 = 20.1 - scale1;
    float2 p = abs(nmp_glsl_mod2(uv * s1, float2(2.0, 2.0)) - float2(1.0, 1.0));

    // Pan mode: layer 1 oscillates horizontally
    if (animMode == 1)
    {
        float osc1 = sin(time * NMP_TAU * spd) * 0.03;
        p += float2(osc1, 0.0);
    }

    float n1 = nmp_shape(shape1, p);

    // Phase mode: per-layer offsets (WGSL: select(0.0, anim, animMode == 2))
    float phase1 = (animMode == 2) ? anim : 0.0;
    float phase2 = (animMode == 2) ? anim : 0.0;
    float phase3 = (animMode == 2) ? anim : 0.0;

    // Layer 2 — operates on p from layer 1
    float s2 = 10.1 - scale2;
    p = abs(nmp_glsl_mod2(p * s2, float2(2.0, 2.0)) - float2(1.0, 1.0));

    // Pan mode: layer 2 oscillates vertically
    if (animMode == 1)
    {
        float osc2 = sin(time * NMP_TAU * spd) * 0.07;
        p += float2(0.0, osc2);
    }

    float n2 = nmp_shape(shape2, p);

    // Blend layers 1+2
    float val;
    if (blend < 1)
    {
        // add
        val = frac(n1 * repeat1 + phase1 + n2 * repeat2 + phase2);
    }
    else
    {
        val = nmp_smoothFract(n1 * repeat1 + phase1 + n2 * repeat2 + phase2);
    }

    // Layer 3 — operates on p from layer 2
    float s3 = 6.1 - scale3;
    p = abs(nmp_glsl_mod2(p * s3, float2(2.0, 2.0)) - float2(1.0, 1.0));

    // Pan mode: layer 3 oscillates negatively horizontal
    if (animMode == 1)
    {
        float osc3 = sin(time * NMP_TAU * spd) * 0.15;
        p += float2(-osc3, 0.0);
    }

    float n3 = nmp_shape(shape3, p);

    // Shift mode: time offset at final blend (WGSL: select(0.0, anim, animMode == 0))
    float shift = (animMode == 0) ? anim : 0.0;

    // Combine layers with selected blend mode
    float3 color;
    if (blend < 1)
    {
        // add: WGSL smoothFract3(vec3<f32>(fract(...))) — vec3 splat of scalar
        float splat = frac(val + n3 * repeat3 + phase3 + shift);
        color = nmp_smoothFract3(float3(splat, splat, splat));
    }
    else if (blend < 2)
    {
        // max
        float mv = max(val, nmp_smoothFract(n3 * repeat3 + phase3 + shift));
        color = float3(mv, mv, mv);
    }
    else if (blend < 3)
    {
        // mix
        float mx = lerp(val, nmp_smoothFract(n3 * repeat3 + phase3 + shift), 0.5);
        color = float3(mx, mx, mx);
    }
    else
    {
        // rgb
        color = nmp_smoothFract3(float3(
            n1 * repeat1 + phase1,
            n2 * repeat2 + phase2,
            n3 * repeat3 + phase3 + shift));
    }

    return float4(color, 1.0);
}

#endif // NM_MODPATTERN_INCLUDED
