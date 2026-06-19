#ifndef NM_EFFECT_CLASSICNOISEDECK_EFFECTS_INCLUDED
#define NM_EFFECT_CLASSICNOISEDECK_EFFECTS_INCLUDED

// =============================================================================
// Effects.hlsl — classicNoisedeck/effects (func: "effects")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/classicNoisedeck/effects/wgsl/effects.wgsl
//
// Multi-effect processor: a single render pass that (1) zooms/rotates/offsets/
// flips the sampling UV, (2) optionally applies one of ~20 leaf effects
// (convolution kernels, pixellate, posterize, cga, subpixel, bloom, zoomBlur,
// derivatives, sobel, outline, shadow, …) and (3) applies brightness/contrast
// and saturation. Single input (inputTex), single pass ("effects").
//
// COMPILE-TIME DEFINES -> INT UNIFORMS (PORTING-GUIDE §"Uniform binding model"):
//   The reference injects EFFECT and FLIP as compile-time consts purely to let
//   ANGLE/Dawn dead-code-eliminate the unreachable cascade arms (a perf
//   workaround, NOT correctness). In HLSL we declare them as `int` uniforms and
//   branch with [branch]; the WGSL path keeps every arm and relies on const
//   folding, so the runtime numeric result is identical.
//
// CANONICAL-SOURCE (WGSL) HAZARDS handled here:
//  * WGSL uses `u.resolution` (its own packed uniform) throughout — NOT a
//    separate fullResolution. We map that to the engine `resolution` alias
//    (_NM_Resolution.xy). The effect's own `aspectRatio()` is
//    `u.resolution.x / u.resolution.y` — we replicate it as a LOCAL helper
//    `nm_cnd_aspectRatio()` over `resolution`, NOT the NMFullscreen
//    `aspectRatio` macro (which uses fullResolution). Follow the WGSL literally.
//  * Main UV: `uv = fragCoord.xy / u.resolution` => NM_FragCoord(i) / resolution.
//    Top-left, +0.5 centered (WGSL @builtin(position) analog) — no per-effect
//    Y flip (H8). All internal samples re-sample inputTex at the derived uv,
//    same as the WGSL (which divides by u.resolution, NOT input dims).
//  * WGSL float `%` is truncated (sign of dividend, == HLSL `fmod`). GLSL `mod`
//    is floored (sign of divisor, == nm_mod). For the ONE place this matters —
//    rgb2hsv's `((rgb.g - rgb.b) / delta) % 6.0` where the dividend can be
//    negative — we use `fmod` to match the CANONICAL WGSL. cga/subpixel `%`
//    operate on non-negative floored coords where fmod==nm_mod==same result;
//    we still use `fmod` there to mirror the WGSL `%` operator literally.
//  * `select(0.0, delta/maxC, maxC != 0.0)` -> ternary `maxC != 0.0 ? d/m : 0`.
//  * prng()/random(): this effect's WGSL prng does `vec3f(pcg(vec3u(p)))` WITHOUT
//    the sign-fold present in some other effects (Variant B, 08-§1.2). NMCore
//    nm_prng is Variant A and folds positives as p*=2, which is NOT identity:
//    for the ONLY prng call (zoomBlur) vec3u(12.9898,78.233,151.7182) truncates
//    to (12,78,151) in WGSL but nm_prng would seed pcg with (25,156,303),
//    giving a DIFFERENT offset. We therefore inline a local no-fold prng over
//    nm_pcg (the pcg core IS shared/identical). random() is unused by this effect.
//  * `distance(a,b)` == length(a-b); `mix` -> lerp; `step`, `floor`, `clamp`,
//    `pow`, `abs`, `fract` map 1:1 (fract -> frac).
//  * effectAmt is a definition.js int uniform; the WGSL Uniforms struct stores
//    it as f32 and the body always uses it as a float. We declare it `float`
//    to match the WGSL arithmetic exactly (e.g. offsets[i] * u.effectAmt).
//  * Sampler: bilinear, clamp-to-edge, NON-sRGB (H7) — set in Effects.shader.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (reference binding: sampler@0, inputTex@1) ------
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Compile-time defines -> int uniforms (branched with [branch]) -----------
int EFFECT;   // globals.effect.define  (default 0; choices map in effects.json)
int FLIP;     // globals.flip.define    (default 0)

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
// effectAmt is declared float to match the WGSL Uniforms.effectAmt: f32 usage.
float effectAmt;   // globals.effectAmt.uniform   default 1
float scaleAmt;    // globals.scaleAmt.uniform     default 100
float rotation;    // globals.rotation.uniform     default 0
float offsetX;     // globals.offsetX.uniform      default 0
float offsetY;     // globals.offsetY.uniform      default 0
float intensity;   // globals.intensity.uniform    default 0
float saturation;  // globals.saturation.uniform   default 0

// ---- Effect-local constants (WGSL `const PI`, `const TAU`) -------------------
static const float NM_CND_PI  = 3.14159265359;
static const float NM_CND_TAU = 6.28318530718;

// aspectRatio() — WGSL: u.resolution.x / u.resolution.y (NOT fullResolution).
float nm_cnd_aspectRatio()
{
    return resolution.x / resolution.y;
}

// prng() — WGSL Variant B (NO sign-fold). Reuses the shared nm_pcg core (which
// IS bit-identical across all effects) but skips nm_prng's p*=2 fold so that
// vec3u(p) truncates the raw input. Divisor 4294967295.0 (= 0xffffffff).
float3 nm_cnd_prng(float3 p)
{
    return float3(nm_pcg((uint3)p)) / 4294967295.0;
}

// mapRange — WGSL mapRange(value,inMin,inMax,outMin,outMax)
float nm_cnd_mapRange(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

// rotate2D — WGSL verbatim. NOTE: uses nm_cnd_aspectRatio() (= u.resolution
// aspect) and mapRange(rot, 0, 360, 0, 2) BEFORE multiplying by PI.
float2 nm_cnd_rotate2D(float2 st_in, float rot)
{
    float2 st = st_in;
    st.x *= nm_cnd_aspectRatio();
    float r = nm_cnd_mapRange(rot, 0.0, 360.0, 0.0, 2.0);
    float angle = r * NM_CND_PI;
    st -= float2(0.5 * nm_cnd_aspectRatio(), 0.5);
    float c = cos(angle);
    float s = sin(angle);
    st = float2(c * st.x - s * st.y, s * st.x + c * st.y);
    st += float2(0.5 * nm_cnd_aspectRatio(), 0.5);
    st.x /= nm_cnd_aspectRatio();
    return st;
}

// brightnessContrast — WGSL verbatim (uses u.intensity).
float3 nm_cnd_brightnessContrast(float3 color)
{
    float bright = nm_cnd_mapRange(intensity, -100.0, 100.0, -0.4, 0.4);
    float cont = 1.0;
    if (intensity < 0.0)
    {
        cont = nm_cnd_mapRange(intensity, -100.0, 0.0, 0.5, 1.0);
    }
    else
    {
        cont = nm_cnd_mapRange(intensity, 0.0, 100.0, 1.0, 1.5);
    }
    return (color - 0.5) * cont + 0.5 + bright;
}

// saturateFn — WGSL verbatim (uses u.saturation).
float3 nm_cnd_saturateFn(float3 color)
{
    float sat = nm_cnd_mapRange(saturation, -100.0, 100.0, -1.0, 1.0);
    float avg = (color.r + color.g + color.b) / 3.0;
    return color - (avg - color) * sat;
}

// hsv2rgb — WGSL verbatim.
float3 nm_cnd_hsv2rgb(float3 hsv)
{
    float h = frac(hsv.x);
    float s = hsv.y;
    float v = hsv.z;
    float c = v * s;
    float x = c * (1.0 - abs(frac(h * 6.0) * 2.0 - 1.0));
    float m = v - c;
    float3 rgb;
    if (h < 1.0 / 6.0)      { rgb = float3(c, x, 0.0); }
    else if (h < 2.0 / 6.0) { rgb = float3(x, c, 0.0); }
    else if (h < 3.0 / 6.0) { rgb = float3(0.0, c, x); }
    else if (h < 4.0 / 6.0) { rgb = float3(0.0, x, c); }
    else if (h < 5.0 / 6.0) { rgb = float3(x, 0.0, c); }
    else                    { rgb = float3(c, 0.0, x); }
    return rgb + float3(m, m, m);
}

// rgb2hsv — WGSL verbatim. The `% 6.0` here can have a NEGATIVE dividend, so it
// must use WGSL truncated-remainder semantics (== HLSL fmod), NOT nm_mod.
float3 nm_cnd_rgb2hsv(float3 rgb)
{
    float maxC = max(rgb.r, max(rgb.g, rgb.b));
    float minC = min(rgb.r, min(rgb.g, rgb.b));
    float delta = maxC - minC;
    float h = 0.0;
    if (delta != 0.0)
    {
        if (maxC == rgb.r)      { h = fmod((rgb.g - rgb.b) / delta, 6.0) / 6.0; }
        else if (maxC == rgb.g) { h = ((rgb.b - rgb.r) / delta + 2.0) / 6.0; }
        else                    { h = ((rgb.r - rgb.g) / delta + 4.0) / 6.0; }
    }
    float s = (maxC != 0.0) ? (delta / maxC) : 0.0;
    return float3(h, s, maxC);
}

// posterize — WGSL verbatim.
float3 nm_cnd_posterize(float3 color, float levIn)
{
    float lev = levIn;
    if (lev == 0.0) { return color; }
    else if (lev == 1.0) { return step(float3(0.5, 0.5, 0.5), color); }
    float gamma = 0.65;
    float3 c = pow(color, float3(gamma, gamma, gamma));
    c = floor(c * lev) / lev;
    return pow(c, float3(1.0 / gamma, 1.0 / gamma, 1.0 / gamma));
}

// pixellate — WGSL verbatim. Samples inputTex at the floored coord (no flip).
float3 nm_cnd_pixellate(float2 uv_in, float sizeIn)
{
    float size = sizeIn;
    if (size < 1.0) { return inputTex.Sample(sampler_inputTex, uv_in).rgb; }
    size *= 4.0;
    float dx = size / resolution.x;
    float dy = size / resolution.y;
    float2 uv = uv_in - 0.5;
    float2 coord = float2(dx * floor(uv.x / dx), dy * floor(uv.y / dy)) + 0.5;
    return inputTex.Sample(sampler_inputTex, coord).rgb;
}

// desaturate — WGSL verbatim.
float3 nm_cnd_desaturate(float3 color)
{
    float avg = 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
    return float3(avg, avg, avg);
}

// convolve — WGSL verbatim. offsets * u.effectAmt; sample inputTex at uv+offset.
float3 nm_cnd_convolve(float2 uv, float kernel[9], bool divide)
{
    float2 steps = 1.0 / resolution;
    float2 offsets[9] = {
        float2(-steps.x, -steps.y), float2(0.0, -steps.y), float2(steps.x, -steps.y),
        float2(-steps.x, 0.0),      float2(0.0, 0.0),      float2(steps.x, 0.0),
        float2(-steps.x, steps.y),  float2(0.0, steps.y),  float2(steps.x, steps.y)
    };
    float kernelWeight = 0.0;
    float3 conv = float3(0.0, 0.0, 0.0);
    [unroll]
    for (int i = 0; i < 9; i++)
    {
        float3 color = inputTex.Sample(sampler_inputTex, uv + offsets[i] * effectAmt).rgb;
        conv += color * kernel[i];
        kernelWeight += kernel[i];
    }
    if (divide && kernelWeight != 0.0) { conv /= kernelWeight; }
    return clamp(conv, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

// derivatives — WGSL verbatim.
float3 nm_cnd_derivatives(float3 color, float2 uv, bool divide)
{
    float deriv_x[9] = { 0.0, 0.0, 0.0, 0.0, 1.0, -1.0, 0.0, 0.0, 0.0 };
    float deriv_y[9] = { 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, -1.0, 0.0 };
    float3 s1 = nm_cnd_convolve(uv, deriv_x, divide);
    float3 s2 = nm_cnd_convolve(uv, deriv_y, divide);
    return color * distance(s1, s2);
}

// sobel — WGSL verbatim.
float3 nm_cnd_sobel(float3 color, float2 uv)
{
    float sobel_x[9] = { 1.0, 0.0, -1.0, 2.0, 0.0, -2.0, 1.0, 0.0, -1.0 };
    float sobel_y[9] = { 1.0, 2.0, 1.0, 0.0, 0.0, 0.0, -1.0, -2.0, -1.0 };
    float3 s1 = nm_cnd_convolve(uv, sobel_x, false);
    float3 s2 = nm_cnd_convolve(uv, sobel_y, false);
    return color * distance(s1, s2);
}

// outline — WGSL verbatim.
float3 nm_cnd_outline(float3 color, float2 uv)
{
    float sobel_x[9] = { 1.0, 0.0, -1.0, 2.0, 0.0, -2.0, 1.0, 0.0, -1.0 };
    float sobel_y[9] = { 1.0, 2.0, 1.0, 0.0, 0.0, 0.0, -1.0, -2.0, -1.0 };
    float3 s1 = nm_cnd_convolve(uv, sobel_x, false);
    float3 s2 = nm_cnd_convolve(uv, sobel_y, false);
    return max(color - distance(s1, s2), float3(0.0, 0.0, 0.0));
}

// shadow — WGSL verbatim.
float3 nm_cnd_shadow(float3 color_in, float2 uv)
{
    float sobel_x[9] = { 1.0, 0.0, -1.0, 2.0, 0.0, -2.0, 1.0, 0.0, -1.0 };
    float sobel_y[9] = { 1.0, 2.0, 1.0, 0.0, 0.0, 0.0, -1.0, -2.0, -1.0 };
    float3 color = nm_cnd_rgb2hsv(color_in);
    float3 x = nm_cnd_convolve(uv, sobel_x, false);
    float3 y = nm_cnd_convolve(uv, sobel_y, false);
    float shade_dist = distance(x, y);
    float highlight = shade_dist * shade_dist;
    float shade = (1.0 - ((1.0 - color.z) * (1.0 - highlight))) * shade_dist;
    color = float3(color.x, color.y, lerp(color.z, shade, 0.75));
    return nm_cnd_hsv2rgb(color);
}

// convolutionEffect — WGSL verbatim cascade. EFFECT branched at runtime.
float3 nm_cnd_convolutionEffect(float3 color, float2 uv)
{
    float emboss[9]      = { -2.0, -1.0, 0.0, -1.0, 1.0, 1.0, 0.0, 1.0, 2.0 };
    float sharpen[9]     = { -1.0, 0.0, -1.0, 0.0, 5.0, 0.0, -1.0, 0.0, -1.0 };
    float blur[9]        = { 1.0, 2.0, 1.0, 2.0, 4.0, 2.0, 1.0, 2.0, 1.0 };
    float edge2[9]       = { -1.0, 0.0, -1.0, 0.0, 4.0, 0.0, -1.0, 0.0, -1.0 };
    float edge3[9]       = { -0.875, -0.75, -0.875, -0.75, 5.0, -0.75, -0.875, -0.75, -0.875 };
    float sharpenBlur[9] = { -2.0, 2.0, -2.0, 2.0, 1.0, 2.0, -2.0, 2.0, -2.0 };

    [branch]
    if (EFFECT == 1)        { return nm_cnd_convolve(uv, blur, true); }
    else if (EFFECT == 2)   { return nm_cnd_derivatives(color, uv, true); }
    else if (EFFECT == 120) { return clamp(nm_cnd_derivatives(color, uv, false) * 2.5, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0)); }
    else if (EFFECT == 3)   { return color * nm_cnd_convolve(uv, edge2, true); }
    else if (EFFECT == 4)   { return nm_cnd_convolve(uv, emboss, false); }
    else if (EFFECT == 5)   { return nm_cnd_outline(color, uv); }
    else if (EFFECT == 6)   { return nm_cnd_shadow(color, uv); }
    else if (EFFECT == 7)   { return nm_cnd_convolve(uv, sharpen, false); }
    else if (EFFECT == 8)   { return nm_cnd_sobel(color, uv); }
    else if (EFFECT == 9)   { return max(color, nm_cnd_convolve(uv, edge2, true)); }
    else if (EFFECT == 300) { return nm_cnd_convolve(uv, sharpenBlur, true); }
    else if (EFFECT == 301) { return nm_cnd_convolve(uv, edge3, true); }
    return color;
}

// cga — WGSL verbatim. Uses fmod for WGSL `%` (operands non-negative here).
float3 nm_cnd_cga(float4 color, float2 st)
{
    float amt = nm_cnd_mapRange(effectAmt, 0.0, 20.0, 0.0, 5.0);
    if (amt < 0.01) { return color.rgb; }
    float pixelDensity = amt;
    float size = 2.0 * pixelDensity;
    float dSize = 2.0 * size;
    float amount = resolution.x / size;
    float d = 1.0 / amount;
    float ar = resolution.x / resolution.y;
    float sx = floor(st.x / d) * d;
    d = ar / amount;
    float sy = floor(st.y / d) * d;
    float4 base = inputTex.Sample(sampler_inputTex, float2(sx, sy));
    float lum = 0.2126 * base.r + 0.7152 * base.g + 0.0722 * base.b;
    float o = floor(6.0 * lum);
    float3 black = float3(0.0, 0.0, 0.0);
    float3 light = float3(85.0, 255.0, 255.0) / 255.0;
    float3 dark = float3(254.0, 84.0, 255.0) / 255.0;
    float3 white = float3(1.0, 1.0, 1.0);
    float3 c1 = black;
    float3 c2 = black;
    if (o == 0.0)      { c1 = black; c2 = black; }
    else if (o == 1.0) { c1 = black; c2 = dark; }
    else if (o == 2.0) { c1 = dark;  c2 = dark; }
    else if (o == 3.0) { c1 = dark;  c2 = light; }
    else if (o == 4.0) { c1 = light; c2 = light; }
    else if (o == 5.0) { c1 = light; c2 = white; }
    else               { c1 = white; c2 = white; }
    float fx = st.x * resolution.x;
    float fy = st.y * resolution.y;
    float3 result = c1;
    if (fmod(fx, dSize) > size)
    {
        if (fmod(fy, dSize) > size) { result = c1; } else { result = c2; }
    }
    else
    {
        if (fmod(fy, dSize) > size) { result = c2; } else { result = c1; }
    }
    return result;
}

// subpixel — WGSL verbatim. fmod for WGSL `%`.
float3 nm_cnd_subpixel(float2 st, float scaleIn)
{
    float scale = nm_cnd_mapRange(scaleIn, 0.0, 100.0, 0.0, 10.0);
    float3 orig = nm_cnd_pixellate(st, scale);
    float3 color = orig;
    float2 coord = floor(st * resolution);
    float m = fmod(coord.x, 4.0 * scale);
    if (fmod(coord.y, 4.0 * scale) <= scale)
    {
        color *= float3(0.0, 0.0, 0.0);
    }
    else if (m <= scale)
    {
        color *= float3(1.0, 0.0, 0.0);
    }
    else if (m <= 2.0 * scale)
    {
        color *= float3(0.0, 1.0, 0.0);
    }
    else if (m <= 3.0 * scale)
    {
        color *= float3(0.0, 0.0, 1.0);
    }
    else
    {
        color *= float3(0.0, 0.0, 0.0);
    }
    float factor = clamp(scale * 0.25, 0.0, 1.0);
    return lerp(orig, color, factor);
}

// bloom — WGSL verbatim. Inclusive/exclusive loop bounds preserved: i in [-4,4),
// j in [-3,3).
float3 nm_cnd_bloom(float2 st)
{
    float3 sum = float3(0.0, 0.0, 0.0);
    float3 orig = inputTex.Sample(sampler_inputTex, st).rgb;
    float strength = nm_cnd_mapRange(effectAmt, 0.0, 20.0, 0.0, 0.25);
    for (int i = -4; i < 4; i++)
    {
        for (int j = -3; j < 3; j++)
        {
            sum += inputTex.Sample(sampler_inputTex, st + float2((float)j, (float)i) * 0.004).rgb * strength;
        }
    }
    float3 color;
    if (orig.r < 0.3)      { color = sum * sum * 0.012 + orig; }
    else if (orig.r < 0.5) { color = sum * sum * 0.009 + orig; }
    else                   { color = sum * sum * 0.0075 + orig; }
    return clamp(color, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

// zoomBlur — WGSL verbatim. offset = prng(vec3f(12.9898,78.233,151.7182)).x.
// Uses nm_cnd_prng (no-fold Variant B) — nm_prng would double the inputs.
float3 nm_cnd_zoomBlur(float2 st)
{
    float3 color = float3(0.0, 0.0, 0.0);
    float total = 0.0;
    float2 toCenter = st - 0.5;
    float offset = nm_cnd_prng(float3(12.9898, 78.233, 151.7182)).x;
    for (float t = 0.0; t <= 40.0; t += 1.0)
    {
        float percent = (t + offset) / 40.0;
        float weight = 4.0 * (percent - percent * percent);
        float strength = nm_cnd_mapRange(effectAmt, 0.0, 20.0, 0.0, 1.0);
        float4 tex = inputTex.Sample(sampler_inputTex, st + toCenter * percent * strength);
        color += tex.rgb * weight;
        total += weight;
    }
    return color / total;
}

// periodicFunction / offsets — WGSL verbatim (unused by main but ported for
// completeness/parity of the translation unit).
float nm_cnd_periodicFunction(float p)
{
    return nm_cnd_mapRange(sin(p * NM_CND_TAU), -1.0, 1.0, 0.0, 1.0);
}

float nm_cnd_offsets(float2 st)
{
    return distance(st, float2(0.5, 0.5));
}

// =============================================================================
// Pass: "effects" (progName "effects"). Mirrors WGSL main().
// =============================================================================
float4 NMFrag_effects(NMVaryings i) : SV_Target
{
    // WGSL: uv = fragCoord.xy / u.resolution
    float2 uv = NM_FragCoord(i) / resolution;

    float scale = 100.0 / scaleAmt;
    if (scale == 0.0) { scale = 1.0; }

    uv = nm_cnd_rotate2D(uv, rotation);
    uv -= 0.5;
    uv *= scale;
    uv += 0.5;

    float2 imageSize = resolution;
    uv.x -= ceil((resolution.x / imageSize.x * scale * 0.5) - (0.5 - (1.0 / imageSize.x * scale)));
    uv.y += ceil((resolution.y / imageSize.y * scale * 0.5) + (0.5 - (1.0 / imageSize.y * scale)) - scale);
    uv.x -= nm_cnd_mapRange(offsetX, -100.0, 100.0, -resolution.x / imageSize.x * scale, resolution.x / imageSize.x * scale) * 1.5;
    uv.y -= nm_cnd_mapRange(offsetY, -100.0, 100.0, -resolution.y / imageSize.y * scale, resolution.y / imageSize.y * scale) * 1.5;
    uv = frac(uv);

    // flip/mirror — runtime branch on FLIP (compile-time const in reference).
    [branch]
    if (FLIP == 1)       { uv = 1.0 - uv; }
    else if (FLIP == 2)  { uv.x = 1.0 - uv.x; }
    else if (FLIP == 3)  { uv.y = 1.0 - uv.y; }
    else if (FLIP == 11) { if (uv.x > 0.5) { uv.x = 1.0 - uv.x; } }
    else if (FLIP == 12) { if (uv.x < 0.5) { uv.x = 1.0 - uv.x; } }
    else if (FLIP == 13) { if (uv.y > 0.5) { uv.y = 1.0 - uv.y; } }
    else if (FLIP == 14) { if (uv.y < 0.5) { uv.y = 1.0 - uv.y; } }
    else if (FLIP == 15) { if (uv.x > 0.5) { uv.x = 1.0 - uv.x; } if (uv.y > 0.5) { uv.y = 1.0 - uv.y; } }
    else if (FLIP == 16) { if (uv.x > 0.5) { uv.x = 1.0 - uv.x; } if (uv.y < 0.5) { uv.y = 1.0 - uv.y; } }
    else if (FLIP == 17) { if (uv.x < 0.5) { uv.x = 1.0 - uv.x; } if (uv.y > 0.5) { uv.y = 1.0 - uv.y; } }
    else if (FLIP == 18) { if (uv.x < 0.5) { uv.x = 1.0 - uv.x; } if (uv.y < 0.5) { uv.y = 1.0 - uv.y; } }

    float4 color = inputTex.Sample(sampler_inputTex, uv);

    if (effectAmt != 0.0 && EFFECT != 0)
    {
        [branch]
        if (EFFECT == 100)      { color = float4(nm_cnd_pixellate(uv, effectAmt), color.a); }
        else if (EFFECT == 110) { color = float4(nm_cnd_posterize(color.rgb, effectAmt), color.a); }
        else if (EFFECT == 200) { color = float4(nm_cnd_cga(color, uv), color.a); }
        else if (EFFECT == 210) { color = float4(nm_cnd_subpixel(uv, effectAmt), color.a); }
        else if (EFFECT == 220) { color = float4(nm_cnd_bloom(uv), color.a); }
        else if (EFFECT == 230) { color = float4(nm_cnd_zoomBlur(uv), color.a); }
        else                    { color = float4(nm_cnd_convolutionEffect(color.rgb, uv), color.a); }
    }

    float3 c = nm_cnd_brightnessContrast(color.rgb);
    c = nm_cnd_saturateFn(c);

    return float4(c, color.a);
}

#endif // NM_EFFECT_CLASSICNOISEDECK_EFFECTS_INCLUDED
