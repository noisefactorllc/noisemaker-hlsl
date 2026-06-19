#ifndef NM_BITEFFECTS_INCLUDED
#define NM_BITEFFECTS_INCLUDED

// =============================================================================
// BitEffects.hlsl — classicNoisedeck/bitEffects. Structure follows the WGSL
// source, BUT the value-noise hash (constant/randomFromLatticeWithOffset) is
// ported from the GLSL golden, which the WGSL diverges from:
//   shaders/effects/classicNoisedeck/bitEffects/glsl/bitEffects.glsl   (hash)
//   shaders/effects/classicNoisedeck/bitEffects/wgsl/bitEffects.wgsl   (rest)
//
// Bit field and bit mask generator (no texture inputs). Single render pass.
//
// COMPILE-TIME DEFINES in the reference (MODE, FORMULA, COLOR_SCHEME, INTERP,
// MASK_FORMULA, MASK_COLOR_SCHEME) are converted to int uniforms + [branch] per
// PORTING-GUIDE (they are perf-only on the reference; not correctness-relevant).
//
// VERBATIM PER-EFFECT HELPERS (do NOT substitute NMCore versions):
//  * This effect's periodicFunction uses SIN: map(sin(p*TAU),-1,1,0,1).
//    NMCore.nm_periodicFunction uses COS — DIFFERENT, so it is inlined here.
//  * The value-noise hash is the GLSL golden randomFromLatticeWithOffset (seed
//    folded into the integer lattice + floatBitsToUint(fract(seed)) jitter), NOT
//    the WGSL's simplified prng(floor(...)). be_prng/be_pcg are inlined as the
//    plain (uint3)p truncation variant (NOT the sign-fold nm_prng); be_prng is
//    retained for structural parity with the reference (now unused, as in GLSL).
//  * rotate2D references the WGSL private `resolution` (NOT fullResolution).
//    Ported from WGSL literally per golden rule 1.
//  * hsv2rgb / rgb2hsv are this effect's own versions.
//  * 8-bit masked integer ops (modi/or_i/and_i/not_i/xor_i) reproduced exactly.
//  * mod_f is the effect's own a-b*floor(a/b) (== nm_mod) — kept inline to match
//    the WGSL call sites verbatim.
//  * WGSL select(falseVal, trueVal, cond) -> HLSL (cond) ? trueVal : falseVal.
//  * f32(bool) comparisons -> (cond) ? 1.0 : 0.0.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
// Declared with the BARE reference `uniform` names so the runtime UniformBinder
// (mpb.SetFloat("speed", ...), etc.) actually binds them. Prefixing them (be_*)
// would leave every one at its 0 default -> pure-black output. None of these
// names collide with the NMFullscreen/NMCore #define aliases (resolution, time,
// fullResolution, aspectRatio, deltaTime, renderScale, NM_PI, NM_TAU).
float speed;        // uniform "speed"        default 50   [0,100]
float n;            // uniform "n"            default 1    [1,200]  (i32-valued)
float scale;        // uniform "scale"        default 75   [1,100]
float rotation;     // uniform "rotation"     default 0    [-180,180]
float tiles;        // uniform "tiles"        default 5    [1,40]   (i32-valued)
float complexity;   // uniform "complexity"   default 57   [1,100]
float baseHueRange; // uniform "baseHueRange" default 50   [0,100]
float hueRotation;  // uniform "hueRotation"  default 180  [0,360]
float hueRange;     // uniform "hueRange"     default 25   [0,100]
float seed;         // uniform "seed"         default 63   [1,100]  (i32-valued)

// Compile-time defines -> int uniforms + [branch].
int MODE;              // define "MODE"              default 1  {bitField:0,bitMask:1}
int FORMULA;           // define "FORMULA"           default 0  {alien:0,sierpinski:1}
int COLOR_SCHEME;      // define "COLOR_SCHEME"      default 20
int INTERP;            // define "INTERP"            default 0  {constant:0,linear:1}
int MASK_FORMULA;      // define "MASK_FORMULA"      default 10
int MASK_COLOR_SCHEME; // define "MASK_COLOR_SCHEME" default 1

// Local PI/TAU literals exactly as the WGSL declares them.
static const float BE_PI  = 3.14159265359;
static const float BE_TAU = 6.28318530718;

// ---- map (effect's own copy) ------------------------------------------------
float be_map(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

// ---- pcg PRNG (verbatim; this WGSL inlines its own copy) --------------------
uint3 be_pcg(uint3 v_in)
{
    uint3 v = v_in * 1664525u + 1013904223u;
    v.x = v.x + v.y * v.z;
    v.y = v.y + v.z * v.x;
    v.z = v.z + v.x * v.y;
    v.x = v.x ^ (v.x >> 16u);
    v.y = v.y ^ (v.y >> 16u);
    v.z = v.z ^ (v.z >> 16u);
    v.x = v.x + v.y * v.z;
    v.y = v.y + v.z * v.x;
    v.z = v.z + v.x * v.y;
    return v;
}

// prng(vec3 p) = vec3(pcg(uvec3(p))) / float(0xffffffffu).
// (uint3)p is float->uint TRUNCATION toward zero (NOT asuint, NOT sign-fold).
float3 be_prng(float3 p)
{
    return float3(be_pcg((uint3)p)) / 4294967295.0;
}

// ---- rotate2D (uses WGSL private `resolution`) ------------------------------
// WGSL: mat2x2<f32>(c,-s,s,c) is COLUMN-MAJOR -> m*v = (c*x + s*y, -s*x + c*y).
float2 be_rotate2D(float2 st, float rot)
{
    float2 st2 = st;
    float angle = be_map(rot, 0.0, 360.0, 0.0, 1.0) * BE_TAU;
    st2 = st2 - resolution * 0.5;
    float c = cos(angle);
    float s = sin(angle);
    st2 = float2(c * st2.x + s * st2.y, -s * st2.x + c * st2.y);
    st2 = st2 + resolution * 0.5;
    return st2;
}

// ---- periodicFunction (SIN variant — effect's own, NOT NMCore's cos) --------
float be_periodicFunction(float p)
{
    return be_map(sin(p * BE_TAU), -1.0, 1.0, 0.0, 1.0);
}

// ---- randomFromLatticeWithOffset (GLSL GOLDEN — overrides the WGSL hash) -----
// CRITICAL parity fix: the WGSL `constant` uses a SIMPLIFIED hash —
// `prng(floor(vec3(st*freq + s, 0)))` — that does NOT match the GLSL reference.
// The parity golden is rendered by the WebGL2 = GLSL backend, so this is ported
// VERBATIM from shaders/effects/classicNoisedeck/bitEffects/glsl/bitEffects.glsl
// (randomFromLatticeWithOffset). It folds the seed into the integer lattice and
// derives PCG jitter from floatBitsToUint(fract(seed)) — none of which the WGSL
// `prng(floor(...))` path does. `constant` is on the critical path for BOTH
// modes (bitMask interior cells via maskValue, bitField blendy via value), so
// this governs the whole pattern.
//   floatBitsToUint(x) -> asuint(x);  GLSL int(floor(x)) -> (int)floor(x);
//   GLSL uint(int) and ivec2(float) are bit-reinterpret / trunc-toward-zero,
//   which HLSL (uint)/(int) casts match for 32-bit.
float3 be_randomFromLatticeWithOffset(float2 st, float xFreq, float yFreq, float s, int2 offset)
{
    float2 lattice = float2(st.x * xFreq, st.y * yFreq);
    float2 baseFloor = floor(lattice);
    int2 base = (int2)baseFloor + offset;
    float2 fracL = lattice - baseFloor;

    int seedInt = (int)floor(s);
    float seedFrac = frac(s);

    float xCombined = fracL.x + seedFrac;
    int xi = base.x + seedInt + (int)floor(xCombined);
    int yi = base.y;

    uint xBits = (uint)xi;
    uint yBits = (uint)yi;
    uint seedBits = asuint(s);
    uint fracBits = asuint(seedFrac);

    uint3 jitter = uint3(
        (fracBits * 374761393u) ^ 0x9E3779B9u,
        (fracBits * 668265263u) ^ 0x7F4A7C15u,
        (fracBits * 2246822519u) ^ 0x94D049B4u
    );

    uint3 state = uint3(xBits, yBits, seedBits) ^ jitter;
    uint3 prngState = be_pcg(state);
    float denom = 4294967295.0;
    return float3(
        (float)prngState.x / denom,
        (float)prngState.y / denom,
        (float)prngState.z / denom
    );
}

// ---- constant (GLSL golden) -------------------------------------------------
float be_constant(float2 st, float xFreq, float yFreq, float s)
{
    float3 randTime = be_randomFromLatticeWithOffset(st, xFreq, yFreq, s, int2(40, 0));
    float scaledTime = be_periodicFunction(randTime.x - time) * be_map(abs(speed), 0.0, 100.0, 0.0, 0.333);

    float3 randv = be_randomFromLatticeWithOffset(st, xFreq, yFreq, s, int2(0, 0));
    return be_periodicFunction(randv.x - scaledTime);
}

// ---- value ------------------------------------------------------------------
float be_value(float2 st, float xFreq, float yFreq, float s)
{
    float x1y1 = be_constant(st, xFreq, yFreq, s);

    [branch]
    if (INTERP == 0)
    {
        return x1y1;
    }

    float ndX = 1.0 / xFreq;
    float ndY = 1.0 / yFreq;

    float x1y2 = be_constant(float2(st.x, st.y + ndY), xFreq, yFreq, s);
    float x2y1 = be_constant(float2(st.x + ndX, st.y), xFreq, yFreq, s);
    float x2y2 = be_constant(float2(st.x + ndX, st.y + ndY), xFreq, yFreq, s);

    float2 uv = float2(st.x * xFreq, st.y * yFreq);

    float a = lerp(x1y1, x2y1, frac(uv.x));
    float b = lerp(x1y2, x2y2, frac(uv.x));

    return lerp(a, b, frac(uv.y));
}

// ---- 8-bit masked integer ops -----------------------------------------------
static const uint BE_BIT_COUNT = 8u;
static const int  BE_mask = (int)((1u << BE_BIT_COUNT) - 1u);

int be_modi(int x, int y) { return (x % y) & BE_mask; }
int be_or_i(int a, int b) { return (a & BE_mask) | (b & BE_mask); }
int be_and_i(int a, int b){ return (a & BE_mask) & (b & BE_mask); }
int be_not_i(int a)       { return (~a) & BE_mask; }
int be_xor_i(int a, int b){ return (a & BE_mask) ^ (b & BE_mask); }

float be_or_f(float a, float b) { return (float)be_or_i((int)a, (int)b); }
float be_and_f(float a, float b){ return (float)be_and_i((int)a, (int)b); }
float be_not_f(float a)         { return (float)be_not_i((int)a); }
float be_xor_f(float a, float b){ return (float)be_xor_i((int)a, (int)b); }

float be_mod_f(float a, float b) { return a - b * floor(a / b); }

// ---- bitValue ---------------------------------------------------------------
float be_bitValue(float2 st, float freq, float nForColor)
{
    float blendy = nForColor + be_periodicFunction(be_value(st, freq * 0.01, freq * 0.01, nForColor) * 0.1) * 100.0;

    float v = 1.0;

    [branch]
    if (FORMULA == 0) {
        v = be_mod_f(be_xor_f(st.x * freq, st.y * freq), blendy);
    } else if (FORMULA == 1) {
        v = be_mod_f(be_or_f(st.x * freq, st.y * freq), blendy);
    } else if (FORMULA == 2) {
        v = be_mod_f((st.x * freq) * (st.y * freq), blendy);
    } else if (FORMULA == 3) {
        v = (be_xor_f(st.x * freq, st.y * freq) < blendy) ? 1.0 : 0.0;
    } else if (FORMULA == 4) {
        v = be_mod_f(st.x * freq * blendy, st.y * freq);
    } else if (FORMULA == 5) {
        v = be_mod_f(((st.x * freq - 0.5) * 0.25), st.y * freq - 0.5);
    }

    // WGSL select(1.0, 0.0, v > 1.0) -> (v > 1.0) ? 0.0 : 1.0
    return (v > 1.0) ? 0.0 : 1.0;
}

// ---- bitField ---------------------------------------------------------------
float3 be_bitField(float2 st)
{
    float2 st2 = st / scale;
    st2 = be_rotate2D(st2, rotation);

    float freq = be_map(scale, 1.0, 100.0, scale, 8.0);

    float3 color = float3(0.0, 0.0, 0.0);

    [branch]
    if (COLOR_SCHEME == 0) {
        color.z = be_bitValue(st2, freq, n);
    } else if (COLOR_SCHEME == 1) {
        float v1 = be_bitValue(st2, freq, n);
        color.y = v1;
        color.z = v1;
    } else if (COLOR_SCHEME == 2) {
        color.y = be_bitValue(st2, freq, n);
    } else if (COLOR_SCHEME == 3) {
        float v2 = be_bitValue(st2, freq, n);
        color.x = v2;
        color.z = v2;
    } else if (COLOR_SCHEME == 4) {
        color.x = be_bitValue(st2, freq, n);
    } else if (COLOR_SCHEME == 5) {
        color = (float3)be_bitValue(st2, freq, n);
    } else if (COLOR_SCHEME == 6) {
        float v3 = be_bitValue(st2, freq, n);
        color.x = v3;
        color.y = v3;
    } else if (COLOR_SCHEME == 10) {
        color.z = be_bitValue(st2, freq, n);
        color.y = be_bitValue(st2, freq, n + 1.0);
    } else if (COLOR_SCHEME == 11) {
        color.z = be_bitValue(st2, freq, n);
        color.x = be_bitValue(st2, freq, n + 1.0);
    } else if (COLOR_SCHEME == 12) {
        color.z = be_bitValue(st2, freq, n);
        float v4 = be_bitValue(st2, freq, n + 1.0);
        color.x = v4;
        color.y = v4;
    } else if (COLOR_SCHEME == 13) {
        color.y = be_bitValue(st2, freq, n);
        float v5 = be_bitValue(st2, freq, n + 1.0);
        color.x = v5;
        color.z = v5;
    } else if (COLOR_SCHEME == 14) {
        color.y = be_bitValue(st2, freq, n);
        color.x = be_bitValue(st2, freq, n + 1.0);
    } else if (COLOR_SCHEME == 15) {
        color.x = be_bitValue(st2, freq, n);
        float v6 = be_bitValue(st2, freq, n + 1.0);
        color.z = v6;
        color.y = v6;
    } else if (COLOR_SCHEME == 20) {
        color.x = be_bitValue(st2, freq, n);
        color.y = be_bitValue(st2, freq, n + 1.0);
        color.z = be_bitValue(st2, freq, n + 2.0);
    }

    return color;
}

// ---- hsv2rgb (effect's own version) -----------------------------------------
float3 be_hsv2rgb(float3 hsv)
{
    float h = frac(hsv.x);
    float s = hsv.y;
    float v = hsv.z;

    float c = v * s;
    float x = c * (1.0 - abs(be_mod_f(h * 6.0, 2.0) - 1.0));
    float m = v - c;

    float3 rgb = float3(0.0, 0.0, 0.0);

    if (0.0 <= h && h < 1.0/6.0) {
        rgb = float3(c, x, 0.0);
    } else if (1.0/6.0 <= h && h < 2.0/6.0) {
        rgb = float3(x, c, 0.0);
    } else if (2.0/6.0 <= h && h < 3.0/6.0) {
        rgb = float3(0.0, c, x);
    } else if (3.0/6.0 <= h && h < 4.0/6.0) {
        rgb = float3(0.0, x, c);
    } else if (4.0/6.0 <= h && h < 5.0/6.0) {
        rgb = float3(x, 0.0, c);
    } else if (5.0/6.0 <= h && h < 1.0) {
        rgb = float3(c, 0.0, x);
    } else {
        rgb = float3(0.0, 0.0, 0.0);
    }

    return rgb + float3(m, m, m);
}

// ---- rgb2hsv (effect's own version; declared in WGSL, kept for parity) ------
float3 be_rgb2hsv(float3 rgb)
{
    float r = rgb.r;
    float g = rgb.g;
    float b = rgb.b;

    float maxc = max(r, max(g, b));
    float minc = min(r, min(g, b));
    float delta = maxc - minc;

    float h = 0.0;
    if (delta != 0.0) {
        if (maxc == r) {
            h = be_mod_f((g - b) / delta, 6.0) / 6.0;
        } else if (maxc == g) {
            h = ((b - r) / delta + 2.0) / 6.0;
        } else if (maxc == b) {
            h = ((r - g) / delta + 4.0) / 6.0;
        }
    }

    // WGSL select(0.0, delta/maxc, maxc != 0.0) -> (maxc != 0.0) ? delta/maxc : 0.0
    float s = (maxc != 0.0) ? delta / maxc : 0.0;
    float v = maxc;

    return float3(h, s, v);
}

// ---- mask value helpers -----------------------------------------------------
float be_maskValueXY(float2 st, float xFreq, float yFreq, float s)
{
    return be_constant(st, xFreq, yFreq, s);
}

float be_maskValue(float2 st, float freq, float s)
{
    return be_maskValueXY(st, freq, freq, s);
}

float be_arecibo(float2 st, float xFreq, float yFreq, int _seed)
{
    float xMod = be_mod_f(floor(st.x * xFreq), xFreq);
    float yMod = be_mod_f(floor(st.y * yFreq), yFreq);

    float v = 1.0;

    if (xMod == 0.0 || yMod == 0.0 || xMod == (xFreq - 1.0) || yMod == (yFreq - 1.0)) {
        v = 0.0;
    } else if (yMod == 1.0) {
        // WGSL select(0.0, 1.0, xMod == 1.0)
        v = (xMod == 1.0) ? 1.0 : 0.0;
    } else {
        v = be_maskValueXY(st, xFreq, yFreq, (float)_seed);
    }

    return v;
}

float be_areciboNum(float2 st, float freq, int _seed)
{
    return be_arecibo(st, floor(freq * 0.5) + 1.0, floor(freq), _seed);
}

float be_glyphs(float2 st, float freq, int _seed)
{
    float xFreq = floor(freq * 0.75);

    float xMod = be_mod_f(floor(st.x * xFreq), xFreq);
    float yMod = be_mod_f(floor(st.y * freq), freq);

    float v = 1.0;

    if (xMod == 0.0 || yMod == 0.0 || xMod == (xFreq - 1.0) || yMod == (freq - 1.0)) {
        v = 0.0;
    } else {
        v = be_maskValueXY(st, xFreq, freq, (float)_seed);
    }

    return v;
}

float be_invaders(float2 st, float freq, int _seed)
{
    float xMod = be_mod_f(floor(st.x * freq), freq);
    float yMod = be_mod_f(floor(st.y * freq), freq);

    float v = 1.0;

    if (xMod == 0.0 || yMod == 0.0 || xMod == (freq - 1.0) || yMod == (freq - 1.0)) {
        v = 0.0;
    } else if (xMod >= freq * 0.5) {
        v = be_maskValue(float2(floor(st.x) + (1.0 - frac(st.x)), st.y), freq, (float)_seed);
    } else {
        v = be_maskValue(st, freq, (float)_seed);
    }

    return v;
}

float be_bitMaskValue(float2 st, float freq, int _seed)
{
    float v = 1.0;

    [branch]
    if (MASK_FORMULA == 10 || MASK_FORMULA == 11) {
        v = be_invaders(st, freq, _seed);
    } else if (MASK_FORMULA == 20) {
        v = be_glyphs(st, freq, _seed);
    } else if (MASK_FORMULA == 30) {
        v = be_areciboNum(st, freq, _seed);
    }

    return v;
}

float3 be_bitMask(float2 st)
{
    float3 color = float3(0.0, 0.0, 0.0);

    float2 st2 = st;
    float aspectRatioLocal = resolution.x / resolution.y;
    st2 = st2 - float2(0.5 * aspectRatioLocal, 0.5);
    st2 = st2 * tiles;
    st2 = st2 + float2(0.5 * aspectRatioLocal, 0.5);

    st2.x = st2.x - 0.5 * aspectRatioLocal;

    [branch]
    if (MASK_FORMULA == 11) {
        st2.y = st2.y * 2.0;
    }

    float freq = floor(be_map(complexity, 1.0, 100.0, 5.0, 12.0));

    // WGSL select(0.0, 1.0, bitMaskValue(...) > 0.5)
    float maskV = (be_bitMaskValue(st2, freq, -100) > 0.5) ? 1.0 : 0.0;

    [branch]
    if (MASK_COLOR_SCHEME == 0) {
        color = (float3)maskV;
    } else {
        float baseHue = 0.01 + be_maskValue(st2, 1.0, -100.0) * baseHueRange * 0.01;

        color.x = frac(baseHue + be_bitMaskValue(st2, freq, 0) * hueRange * 0.01 + (1.0 - (hueRotation / 360.0))) * maskV;

        if (MASK_COLOR_SCHEME == 3) {
            color.y = maskV;
        } else {
            color.y = be_bitMaskValue(st2, freq, 25) * maskV;
        }

        if (MASK_COLOR_SCHEME == 2 || MASK_COLOR_SCHEME == 3) {
            color.z = maskV;
        } else {
            color.z = be_bitMaskValue(st2, freq, 50) * maskV;
        }

        color = be_hsv2rgb(color);
    }
    return color;
}

// =============================================================================
// nm_bitEffects — core per-pixel evaluation. `globalCoord` is the fragment's
// pixel coordinate plus tileOffset (i.e. NM_GlobalCoord(i)). Returns RGBA.
// Mirrors WGSL main() exactly.
//   MODE==0 (bitField): st = pos.xy + tileOffset (raw pixel coords).
//   MODE==1 (bitMask):  st = (pos.xy + tileOffset) / fullResolution.y, then
//                       st += float(seed) + 1000.0.
// (resolution/time/fullResolution are the engine-provided NMFullscreen aliases;
// the Shader Graph wrapper, if present, would override them. Multi-uniform set
// so seed-driven branch must read seed for MODE==1.)
// =============================================================================
float4 nm_bitEffects(float2 globalCoord, float2 res, float2 fullRes, float timeVal)
{
    float4 color = float4(0.0, 0.0, 0.0, 1.0);
    float2 st = globalCoord;

    [branch]
    if (MODE == 0) {
        color = float4(be_bitField(st), color.a);
    } else {
        st = globalCoord / fullRes.y;
        st = st + (float)seed + 1000.0;
        color = float4(be_bitMask(st), color.a);
    }

    return color;
}

#endif // NM_BITEFFECTS_INCLUDED
