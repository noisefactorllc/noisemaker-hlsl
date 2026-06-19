#ifndef NM_OSC2D_INCLUDED
#define NM_OSC2D_INCLUDED

// =============================================================================
// Osc2d.hlsl — synth/osc2d (func: "osc2d")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/synth/osc2d/wgsl/osc2d.wgsl
//
// 2D oscillator pattern generator. A scalar oscillator value (0..1) is computed
// from a phase = spatialPhase + timePhase along the (optionally rotated) y-axis,
// then written as grayscale. Seven oscillator shapes (sine, triangle, sawtooth,
// inverted sawtooth, square, noise1d scrolling, noise2d two-stage periodic).
//
// Helpers (hash11, tilingNoise1D, periodicValue, rotate2D, oscSine/Linear/
// Sawtooth/SawtoothInv/Square) are ported VERBATIM and INLINE per PORTING-GUIDE.
// This effect's hash11/tilingNoise1D/periodicValue/rotate2D are NOT the generic
// shared ones — do NOT substitute. Nothing here comes from NMCore beyond the
// nm_mod float-mod primitive (used for the WGSL float `%` wrap).
//
// NUMERIC HAZARDS handled:
//  * WGSL `(i % freq + freq) % freq` is float modulo. WGSL `%` on f32 == GLSL
//    `mod` == nm_mod (a - b*floor(a/b)). The GLSL source confirms this: it uses
//    `mod(i, freq)` / `mod(i + 1.0, freq)`. We therefore use nm_mod, NOT fmod.
//    For non-negative i (i = floor(x*freq), x in [0,1], freq >= 1) the double
//    `(i % freq + freq) % freq` is identical to a single nm_mod(i, freq); we
//    keep the literal double form to match the WGSL byte-for-byte.
//  * st divides by fullResolution (see WGSL/GLSL note below). The WGSL bakes a
//    Y-flip (res.y - position.y) to reconcile WebGPU's bottom-origin default
//    framebuffer; the GLSL (bottom-left, the disambiguator) does a straight
//    `(gl_FragCoord.xy + tileOffset) / fullResolution` with NO flip. NMFullscreen
//    already provides top-left coords (NM_GlobalCoord), so we divide straight and
//    do NOT re-apply the WGSL flip. See PORTING-GUIDE golden rule 1.
//  * `step(0.5, frac(t))` arg order copied literally (edge first).
//  * f = f*f*(3-2f) smoothstep written out literally.
//  * mix(a,b,f) -> lerp(a,b,f).  fract -> frac.
//
// TODO(verify): confirm vertical orientation against the parity harness. If the
// harness shows a vertical mirror on a given Unity graphics API, flip ONCE via
// `#define NM_FLIP_Y 1` (NMFullscreen) — never per-effect.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
// Bound by the runtime via MaterialPropertyBlock.
//   oscType   : i32 enum 0..6 (global "oscType", uniform "oscType")
//   frequency : i32 [1,32]    (global "freq",    uniform "frequency")
//   speed     : f32 [0,10]    (global "speed",   uniform "speed")
//   rotation  : f32 [-180,180](global "rotation",uniform "rotation")
//   seed      : i32 [0,1000]  (global "seed",    uniform "seed")
int    oscType;
int    frequency;
float  speed;
float  rotation;
int    seed;

// Local PI/TAU literals exactly as the WGSL declares them.
static const float NMO_PI  = 3.141592653589793;
static const float NMO_TAU = 6.283185307179586;

// ---- hash11: simple 1D hash for noise (osc2d's own variant) -----------------
// WGSL:
//   var pv = fract(p * 234.34 + s * 0.7183);
//   pv = pv + pv * (pv + 34.23);
//   return fract(pv * pv);
float nmo_hash11(float p, float s)
{
    float pv = frac(p * 234.34 + s * 0.7183);
    pv = pv + pv * (pv + 34.23);
    return frac(pv * pv);
}

// ---- tilingNoise1D: value noise that tiles at integer freq boundaries -------
// WGSL:
//   let p = x * freq; let i = floor(p); var f = fract(p);
//   f = f * f * (3.0 - 2.0 * f);                       // smoothstep
//   let i0 = (i % freq + freq) % freq;                 // float modulo wrap
//   let i1 = ((i + 1.0) % freq + freq) % freq;
//   let a = hash11(i0, s); let b = hash11(i1, s);
//   return mix(a, b, f);
float nmo_tilingNoise1D(float x, float freq, float s)
{
    // x is in [0, 1] range, scale by frequency
    float p = x * freq;
    float i = floor(p);
    float f = frac(p);
    f = f * f * (3.0 - 2.0 * f);  // smoothstep

    // Wrap indices for seamless tiling. WGSL `%` on f32 == nm_mod (GLSL `mod`).
    float i0 = nm_mod(nm_mod(i, freq) + freq, freq);
    float i1 = nm_mod(nm_mod(i + 1.0, freq) + freq, freq);

    float a = nmo_hash11(i0, s);
    float b = nmo_hash11(i1, s);

    return lerp(a, b, f);
}

// ---- periodicValue: normalized_sine((t - v) * tau) --------------------------
// WGSL: return (sin((t - v) * TAU) + 1.0) * 0.5;
float nmo_periodicValue(float t, float v)
{
    return (sin((t - v) * NMO_TAU) + 1.0) * 0.5;
}

// ---- rotate2D (osc2d's own variant) -----------------------------------------
// WGSL: vec2(p.x*c - p.y*s, p.x*s + p.y*c)  where s=sin(angle), c=cos(angle).
float2 nmo_rotate2D(float2 p, float angle)
{
    float s = sin(angle);
    float c = cos(angle);
    return float2(p.x * c - p.y * s, p.x * s + p.y * c);
}

// ---- Oscillator shapes: each returns 0->1->0 (or 0->1) over t = 0..1 --------
float nmo_oscSine(float t)        { return sin(frac(t) * NMO_PI); }            // half-cycle sine
float nmo_oscLinear(float t)      { float tf = frac(t); return 1.0 - abs(tf * 2.0 - 1.0); } // triangle
float nmo_oscSawtooth(float t)    { return frac(t); }                          // sawtooth 0->1
float nmo_oscSawtoothInv(float t) { return 1.0 - frac(t); }                    // inverted 1->0
float nmo_oscSquare(float t)      { return step(0.5, frac(t)); }               // square 0 or 1

// =============================================================================
// nm_osc2d — core per-pixel evaluation. `globalCoord` = NM_GlobalCoord(i) (the
// fragment's pixel coordinate + tileOffset). `fullRes` = fullResolution.
// `aspect` = aspectRatio (fullResolution.x / fullResolution.y). `timeVal` =
// normalized time. Returns RGBA grayscale. Mirrors WGSL main() exactly.
// =============================================================================
float4 nm_osc2d(float2 globalCoord, float2 fullRes, float aspect, float timeVal)
{
    float2 res = fullRes;
    if (res.x < 1.0) { res = float2(1024.0, 1024.0); }

    // Normalized coordinates. Port-from-WGSL is top-left; NM_GlobalCoord already
    // supplies top-left coords, so divide straight (no WGSL res.y - position.y).
    float2 st = globalCoord / res;

    // Center for rotation
    st = st - 0.5;
    st.x = st.x * aspect;

    // Apply rotation
    float rotRad = rotation * NMO_PI / 180.0;
    st = nmo_rotate2D(st, rotRad);

    // Spatial position in [0, 1] for noise sampling
    float spatialPos = st.y + 0.5;
    float freq = (float)frequency;

    // The oscillator value is based on position along y-axis.
    // frequency controls how many bands appear; speed controls animation rate.
    float spatialPhase = st.y * freq;
    float timePhase = timeVal * speed;
    float t = spatialPhase + timePhase;

    float val;
    if (oscType == 0)
    {
        // Sine
        val = nmo_oscSine(t);
    }
    else if (oscType == 1)
    {
        // Linear (triangle)
        val = nmo_oscLinear(t);
    }
    else if (oscType == 2)
    {
        // Sawtooth
        val = nmo_oscSawtooth(t);
    }
    else if (oscType == 3)
    {
        // Sawtooth inverted
        val = nmo_oscSawtoothInv(t);
    }
    else if (oscType == 4)
    {
        // Square
        val = nmo_oscSquare(t);
    }
    else if (oscType == 5)
    {
        // noise1d - scrolling version of noise2d.
        // At t=0 must match noise2d exactly, then scrolls the pattern over time.
        float scrollOffset = frac(timeVal * speed);
        float scrolledPos = frac(spatialPos + scrollOffset);

        // Same computation as noise2d at t=0
        float timeNoise = nmo_tilingNoise1D(scrolledPos, freq, (float)seed + 12345.0);
        float valueNoise = nmo_tilingNoise1D(scrolledPos, freq, (float)seed);
        float scaledTime = nmo_periodicValue(0.0, timeNoise) * speed;
        val = nmo_periodicValue(scaledTime, valueNoise);
    }
    else
    {
        // noise2d (oscType == 6) - two-stage periodic.
        // Python: scaled_time = periodic_value(time, time_noise) * speed
        //         result      = periodic_value(scaled_time, value_noise)
        float timeNoise = nmo_tilingNoise1D(spatialPos, freq, (float)seed + 12345.0);
        float valueNoise = nmo_tilingNoise1D(spatialPos, freq, (float)seed);

        // Two-stage periodic: time -> periodic -> scale -> periodic
        float scaledTime = nmo_periodicValue(timeVal, timeNoise) * speed;
        val = nmo_periodicValue(scaledTime, valueNoise);
    }

    return float4(val, val, val, 1.0);
}

// ---- Pass: "osc2d" (progName "osc2d") ---------------------------------------
float4 NMFrag_osc2d(NMVaryings i) : SV_Target
{
    // globalCoord = fragCoord + tileOffset (top-left, +0.5 centered).
    float2 globalCoord = NM_GlobalCoord(i);
    return nm_osc2d(globalCoord, fullResolution, aspectRatio, time);
}

#endif // NM_OSC2D_INCLUDED
