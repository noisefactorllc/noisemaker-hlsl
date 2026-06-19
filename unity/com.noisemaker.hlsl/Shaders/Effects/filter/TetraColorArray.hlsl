#ifndef NM_TETRACOLORARRAY_INCLUDED
#define NM_TETRACOLORARRAY_INCLUDED

// =============================================================================
// TetraColorArray.hlsl — filter/tetraColorArray, ported PIXEL-IDENTICALLY from:
//   shaders/effects/filter/tetraColorArray/wgsl/tetraColorArray.wgsl
//
// Applies a discrete color array gradient to the input image based on luminance.
// Supports up to 8 colors with manual or auto-positioned stops.
// Supports RGB (0), HSV (1), OkLab (2), and OKLCH (3) color modes.
//
// Single render pass, program name "tetraColorArray".
//
// Uniforms are declared per-effect named (not packed), matching definition.js
// globals[*].uniform names exactly.
//
// All helpers — hsv2rgb, rgb2hsv, linear2srgb, srgb2linear, oklab2linear,
// linear2oklab, etc. — are this effect's OWN copies, ported VERBATIM inline.
// Do NOT substitute shared color conversion helpers.
//
// UV: position.xy / textureDimensions(inputTex, 0) — divide by the INPUT
// TEXTURE's own size, not fullResolution. Matches WGSL lines 314-316.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
int    colorMode;     // default 0  (0=rgb, 1=hsv, 2=oklab, 3=oklch)
int    colorCount;    // default 6  (2..8)
int    positionMode;  // default 0  (0=auto, 1=manual)
float  repeat;        // default 1
float  offset;        // default 0
float  alpha;         // default 1
float  smoothness;    // default 1
float  rotation;      // default 0  (-1=back, 0=none, 1=fwd)
float3 color0;        // default (1, 0, 0)
float3 color1;        // default (1, 0.5, 0)
float3 color2;        // default (1, 1, 0)
float3 color3;        // default (0, 1, 0)
float3 color4;        // default (0, 0, 1)
float3 color5;        // default (0.58, 0, 0.83)
float3 color6;        // default (1, 1, 1)
float3 color7;        // default (0, 0, 0)
float  pos0;          // default 0.0
float  pos1;          // default 0.14
float  pos2;          // default 0.29
float  pos3;          // default 0.43
float  pos4;          // default 0.57
float  pos5;          // default 0.71
float  pos6;          // default 0.86
float  pos7;          // default 1.0

// =============================================================================
// Color Space Conversions — ported VERBATIM from tetraColorArray.wgsl
// =============================================================================

// --- RGB <-> HSV ---

// WGSL source: fn hsv2rgb(hsv: vec3<f32>) -> vec3<f32>
float3 nm_tca_hsv2rgb(float3 hsv)
{
    float h = hsv.x;
    float s = hsv.y;
    float v = hsv.z;

    float c  = v * s;
    float hp = h * 6.0;
    float x  = c * (1.0 - abs(nm_mod(hp, 2.0) - 1.0));
    float m  = v - c;

    float3 rgb;
    if (hp < 1.0) {
        rgb = float3(c, x, 0.0);
    } else if (hp < 2.0) {
        rgb = float3(x, c, 0.0);
    } else if (hp < 3.0) {
        rgb = float3(0.0, c, x);
    } else if (hp < 4.0) {
        rgb = float3(0.0, x, c);
    } else if (hp < 5.0) {
        rgb = float3(x, 0.0, c);
    } else {
        rgb = float3(c, 0.0, x);
    }

    return rgb + float3(m, m, m);
}

// WGSL source: fn rgb2hsv(c: vec3<f32>) -> vec3<f32>
float3 nm_tca_rgb2hsv(float3 c)
{
    float cmax = max(c.r, max(c.g, c.b));
    float cmin = min(c.r, min(c.g, c.b));
    float delta = cmax - cmin;

    float h = 0.0;
    if (delta > 0.0) {
        if (cmax == c.r) {
            h = (nm_mod((c.g - c.b) / delta, 6.0)) / 6.0;
        } else if (cmax == c.g) {
            h = ((c.b - c.r) / delta + 2.0) / 6.0;
        } else {
            h = ((c.r - c.g) / delta + 4.0) / 6.0;
        }
        h = frac(h);
    }
    // WGSL: select(0.0, delta / cmax, cmax > 0.0) — select(falseVal, trueVal, cond)
    float s = (cmax > 0.0) ? (delta / cmax) : 0.0;
    return float3(h, s, cmax);
}

// --- Gamma transfer ---

// WGSL source: fn linear2srgb(lin: vec3<f32>) -> vec3<f32>
float3 nm_tca_linear2srgb(float3 lin)
{
    float3 low  = lin * 12.92;
    float3 high = 1.055 * pow(max(lin, float3(0.0, 0.0, 0.0)), float3(1.0 / 2.4, 1.0 / 2.4, 1.0 / 2.4)) - 0.055;
    // WGSL: select(high, low, lin < 0.0031308) — select(falseVal, trueVal, cond)
    return float3(
        (lin.x < 0.0031308) ? low.x : high.x,
        (lin.y < 0.0031308) ? low.y : high.y,
        (lin.z < 0.0031308) ? low.z : high.z
    );
}

// WGSL source: fn srgb2linear(c: vec3<f32>) -> vec3<f32>
float3 nm_tca_srgb2linear(float3 c)
{
    float3 low  = c / 12.92;
    float3 high = pow((c + 0.055) / 1.055, float3(2.4, 2.4, 2.4));
    // WGSL: select(high, low, c < 0.04045)
    return float3(
        (c.x < 0.04045) ? low.x : high.x,
        (c.y < 0.04045) ? low.y : high.y,
        (c.z < 0.04045) ? low.z : high.z
    );
}

// --- OkLab core ---

// WGSL source: fn oklab2linear(lab: vec3<f32>) -> vec3<f32>
float3 nm_tca_oklab2linear(float3 lab)
{
    float l_ = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z;
    float m_ = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z;
    float s_ = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z;

    float l = l_ * l_ * l_;
    float m = m_ * m_ * m_;
    float s = s_ * s_ * s_;

    return float3(
         4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    );
}

// WGSL source: fn linear2oklab(lin: vec3<f32>) -> vec3<f32>
float3 nm_tca_linear2oklab(float3 lin)
{
    float l = 0.4122214708 * lin.r + 0.5363325363 * lin.g + 0.0514459929 * lin.b;
    float m = 0.2119034982 * lin.r + 0.6806995451 * lin.g + 0.1073969566 * lin.b;
    float s = 0.0883024619 * lin.r + 0.2817188376 * lin.g + 0.6299787005 * lin.b;

    float l_ = pow(max(l, 0.0), 1.0 / 3.0);
    float m_ = pow(max(m, 0.0), 1.0 / 3.0);
    float s_ = pow(max(s, 0.0), 1.0 / 3.0);

    return float3(
        0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
        1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
        0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
    );
}

// --- RGB <-> OkLab ---

// WGSL source: fn oklab2rgb
float3 nm_tca_oklab2rgb(float3 lab)
{
    return clamp(nm_tca_linear2srgb(nm_tca_oklab2linear(lab)), float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

// WGSL source: fn rgb2oklab
float3 nm_tca_rgb2oklab(float3 rgb)
{
    return nm_tca_linear2oklab(nm_tca_srgb2linear(rgb));
}

// --- RGB <-> OKLCH (L, C, H where H is 0-1 fractional turns) ---

static const float NM_TCA_TAU = 6.283185307179586;

// WGSL source: fn oklch2rgb
float3 nm_tca_oklch2rgb(float3 lch)
{
    float a = lch.y * cos(lch.z * NM_TCA_TAU);
    float b = lch.y * sin(lch.z * NM_TCA_TAU);
    return clamp(nm_tca_linear2srgb(nm_tca_oklab2linear(float3(lch.x, a, b))), float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

// WGSL source: fn rgb2oklch
float3 nm_tca_rgb2oklch(float3 rgb)
{
    float3 lab = nm_tca_rgb2oklab(rgb);
    float C = length(lab.yz);
    float h = atan2(lab.z, lab.y);  // WGSL: atan2(lab.z, lab.y) — arg order copied literally
    return float3(lab.x, C, frac(h / NM_TCA_TAU));
}

// --- Dispatch by mode ---

// WGSL source: fn rgbToColorSpace
float3 nm_tca_rgbToColorSpace(float3 rgb, int mode)
{
    [branch]
    if (mode == 1) { return nm_tca_rgb2hsv(rgb); }
    if (mode == 2) { return nm_tca_rgb2oklab(rgb); }
    if (mode == 3) { return nm_tca_rgb2oklch(rgb); }
    return rgb;
}

// WGSL source: fn colorSpaceToRgb
float3 nm_tca_colorSpaceToRgb(float3 c, int mode)
{
    [branch]
    if (mode == 1) { return nm_tca_hsv2rgb(c); }
    if (mode == 2) { return nm_tca_oklab2rgb(c); }
    if (mode == 3) { return nm_tca_oklch2rgb(c); }
    return c;
}

// =============================================================================
// Color Array Helpers — ported VERBATIM from tetraColorArray.wgsl
// =============================================================================

// WGSL source: fn getColor(index: i32) -> vec4<f32>
float3 nm_tca_getColor(int index)
{
    [branch]
    switch (index)
    {
        case 0:  return color0;
        case 1:  return color1;
        case 2:  return color2;
        case 3:  return color3;
        case 4:  return color4;
        case 5:  return color5;
        case 6:  return color6;
        case 7:  return color7;
        default: return color0;
    }
}

// WGSL source: fn getPosition(index, colorCount, positionMode) -> f32
float nm_tca_getPosition(int index, int cCount, int posMode)
{
    // Auto mode: evenly distribute
    if (posMode == 0) {
        if (cCount <= 1) {
            return 0.0;
        }
        return (float)index / (float)(cCount - 1);
    }

    // Manual mode: use stored positions
    [branch]
    switch (index)
    {
        case 0:  return pos0;
        case 1:  return pos1;
        case 2:  return pos2;
        case 3:  return pos3;
        case 4:  return pos4;
        case 5:  return pos5;
        case 6:  return pos6;
        case 7:  return pos7;
        default: return 0.0;
    }
}

// WGSL source: fn mixInColorSpace(a, b, f, mode) -> vec3<f32>
float3 nm_tca_mixInColorSpace(float3 a, float3 b, float f, int mode)
{
    if (mode == 1) {
        // HSV: hue is .x
        float dh = b.x - a.x;
        if (dh > 0.5)  { dh -= 1.0; }
        if (dh < -0.5) { dh += 1.0; }
        return float3(frac(a.x + dh * f), lerp(a.y, b.y, f), lerp(a.z, b.z, f));
    } else if (mode == 3) {
        // OKLCH: hue is .z
        float dh = b.z - a.z;
        if (dh > 0.5)  { dh -= 1.0; }
        if (dh < -0.5) { dh += 1.0; }
        return float3(lerp(a.x, b.x, f), lerp(a.y, b.y, f), frac(a.z + dh * f));
    }
    return lerp(a, b, f);
}

// WGSL source: fn sampleColorArray(t_in, colorCount, positionMode, colorMode, smoothAmount)
float3 nm_tca_sampleColorArray(float t_in, int cCount, int posMode, int cMode, float smoothAmount)
{
    float t = clamp(t_in, 0.0, 1.0);

    // Handle edge cases
    if (cCount <= 0) {
        return float3(0.0, 0.0, 0.0);
    }
    if (cCount == 1) {
        return nm_tca_getColor(0);
    }

    // Cascade blend: smoothstep at each transition boundary
    float3 result = nm_tca_rgbToColorSpace(nm_tca_getColor(0), cMode);

    for (int i = 1; i < cCount; i = i + 1)
    {
        float boundary;
        float bw;

        if (posMode == 0) {
            // Auto: equal-width bands, transitions at i/count
            boundary = (float)i / (float)cCount;
            bw = smoothAmount * 0.5 / (float)cCount;
        } else {
            // Manual: transition at midpoint between adjacent positions
            float pPrev = nm_tca_getPosition(i - 1, cCount, posMode);
            float pCurr = nm_tca_getPosition(i,     cCount, posMode);
            boundary = (pPrev + pCurr) * 0.5;
            bw = smoothAmount * (pCurr - pPrev) * 0.25;
        }

        float blend = smoothstep(boundary - bw, boundary + bw, t);
        float3 nextColor = nm_tca_rgbToColorSpace(nm_tca_getColor(i), cMode);
        result = nm_tca_mixInColorSpace(result, nextColor, blend, cMode);
    }

    // Wrap-around blend: smooth the seam between last and first color
    if (smoothAmount > 0.0) {
        float bw;
        if (posMode == 0) {
            bw = smoothAmount * 0.5 / (float)cCount;
        } else {
            float pLast  = nm_tca_getPosition(cCount - 1, cCount, posMode);
            float pFirst = nm_tca_getPosition(0,          cCount, posMode);
            float gap = 1.0 - pLast + pFirst;
            bw = smoothAmount * gap * 0.25;
        }

        if (bw > 0.0) {
            // Signed cyclic distance from the wrap boundary (t=0 ≡ t=1)
            // WGSL: select(t, t - 1.0, t > 0.5) — select(falseVal, trueVal, cond)
            float d = (t > 0.5) ? (t - 1.0) : t;
            // Interpolation factor: 0 = last color, 1 = first color
            float wrapFactor = smoothstep(-bw, bw, d);
            float3 lastColor  = nm_tca_rgbToColorSpace(nm_tca_getColor(cCount - 1), cMode);
            float3 firstColor = nm_tca_rgbToColorSpace(nm_tca_getColor(0), cMode);
            float3 wrapColor  = nm_tca_mixInColorSpace(lastColor, firstColor, wrapFactor, cMode);

            // Mask: 1.0 at wrap point, fading to 0.0 at edge of zone
            float wrapMask = 1.0 - smoothstep(0.0, bw, abs(d));
            result = nm_tca_mixInColorSpace(result, wrapColor, wrapMask, cMode);
        }
    }

    return nm_tca_colorSpaceToRgb(result, cMode);
}

// =============================================================================
// nm_tetraColorArray — core per-pixel evaluation.
// Pure function, takes sampled inputColor + time; reads uniforms from module scope.
// Ported VERBATIM from tetraColorArray.wgsl @fragment main().
// =============================================================================
float4 nm_tetraColorArray(float4 inputColor, float timeVal)
{
    // Extract uniforms (match WGSL uniform extraction pattern exactly)
    int   cMode    = colorMode;
    int   cCount   = colorCount;
    int   posMode  = positionMode;
    float repeatVal = repeat;
    float offsetVal = offset;
    float alphaVal  = alpha;
    float smoothness_val = smoothness;
    int   rotVal   = (int)rotation;  // WGSL: i32(data[1].w)

    // Calculate luminance as the t value
    float lum = dot(inputColor.rgb, float3(0.299, 0.587, 0.114));

    // Apply mapping: repeat, offset, and rotation (animation)
    float t = lum * (1.0 - 1e-4) * repeatVal + offsetVal;

    [branch]
    if (rotVal == -1) {
        t = t + timeVal;
    } else if (rotVal == 1) {
        t = t - timeVal;
    }

    t = frac(t);

    // Sample the color array gradient
    float3 gradientColor = nm_tca_sampleColorArray(t, cCount, posMode, cMode, smoothness_val);

    // Blend with original based on alpha
    float3 blendedColor = lerp(inputColor.rgb, gradientColor, alphaVal);

    return float4(blendedColor, inputColor.a);
}

#endif // NM_TETRACOLORARRAY_INCLUDED
