#ifndef NM_SG_CLASSICNOISEDECK_EFFECTS_INCLUDED
#define NM_SG_CLASSICNOISEDECK_EFFECTS_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for classicNoisedeck/effects.
//
// Single render pass, single input (inputTex) — so it ships as a Custom Function
// node. Each definition.js global maps to a named input:
//   effect     -> Effect     (int, reference define EFFECT)   default 0
//   flip       -> Flip       (int, reference define FLIP)      default 0
//   effectAmt  -> EffectAmt  (float; WGSL uses Uniforms.effectAmt as f32)
//   scaleAmt   -> ScaleAmt   (float) default 100
//   rotation   -> Rotation   (float) default 0
//   offsetX    -> OffsetX    (float) default 0
//   offsetY    -> OffsetY    (float) default 0
//   intensity  -> Intensity  (float) default 0
//   saturation -> Saturation (float) default 0
// InputTex/SS/UV provide the source surface; Resolution is the render target
// size the WGSL calls `u.resolution` (the effect divides fragCoord by it and
// uses it for texel steps / cga sizing). Pass the runtime resolution so the
// kernel offsets and cga grid match the runtime path exactly.
//
// Self-contained (does NOT include NMFullscreen.hlsl / NMCore.hlsl) so it is
// safe to drop into a Shader Graph Custom Function node. Helpers/core are
// mirrored VERBATIM from Shaders/Effects/classicNoisedeck/Effects.hlsl,
// name-prefixed `nmsg_cnd_`. PCG is inlined here (the runtime path uses NMCore
// nm_prng, whose sign-fold is a no-op for the single all-positive prng call).
// =============================================================================

static const float NMSG_CND_PI  = 3.14159265359;
static const float NMSG_CND_TAU = 6.28318530718;

// PCG 3D (riccardoscalco, MIT) — inlined for the self-contained node.
uint3 nmsg_cnd_pcg(uint3 v)
{
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return v;
}

// prng matches NMCore nm_prng (sign-fold). The only call uses all-positive args,
// so the fold is a no-op and this is bit-identical to the WGSL prng there.
float3 nmsg_cnd_prng(float3 p)
{
    p.x = p.x >= 0.0 ? p.x * 2.0 : -p.x * 2.0 + 1.0;
    p.y = p.y >= 0.0 ? p.y * 2.0 : -p.y * 2.0 + 1.0;
    p.z = p.z >= 0.0 ? p.z * 2.0 : -p.z * 2.0 + 1.0;
    return float3(nmsg_cnd_pcg((uint3)p)) / 4294967295.0;
}

float nmsg_cnd_mapRange(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

float nmsg_cnd_aspectRatio(float2 res)
{
    return res.x / res.y;
}

float2 nmsg_cnd_rotate2D(float2 st_in, float rot, float2 res)
{
    float ar = nmsg_cnd_aspectRatio(res);
    float2 st = st_in;
    st.x *= ar;
    float r = nmsg_cnd_mapRange(rot, 0.0, 360.0, 0.0, 2.0);
    float angle = r * NMSG_CND_PI;
    st -= float2(0.5 * ar, 0.5);
    float c = cos(angle);
    float s = sin(angle);
    st = float2(c * st.x - s * st.y, s * st.x + c * st.y);
    st += float2(0.5 * ar, 0.5);
    st.x /= ar;
    return st;
}

float3 nmsg_cnd_brightnessContrast(float3 color, float intensity)
{
    float bright = nmsg_cnd_mapRange(intensity, -100.0, 100.0, -0.4, 0.4);
    float cont = 1.0;
    if (intensity < 0.0) { cont = nmsg_cnd_mapRange(intensity, -100.0, 0.0, 0.5, 1.0); }
    else                 { cont = nmsg_cnd_mapRange(intensity, 0.0, 100.0, 1.0, 1.5); }
    return (color - 0.5) * cont + 0.5 + bright;
}

float3 nmsg_cnd_saturateFn(float3 color, float saturation)
{
    float sat = nmsg_cnd_mapRange(saturation, -100.0, 100.0, -1.0, 1.0);
    float avg = (color.r + color.g + color.b) / 3.0;
    return color - (avg - color) * sat;
}

float3 nmsg_cnd_hsv2rgb(float3 hsv)
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

float3 nmsg_cnd_rgb2hsv(float3 rgb)
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

float3 nmsg_cnd_posterize(float3 color, float lev)
{
    if (lev == 0.0) { return color; }
    else if (lev == 1.0) { return step(float3(0.5, 0.5, 0.5), color); }
    float gamma = 0.65;
    float3 c = pow(color, float3(gamma, gamma, gamma));
    c = floor(c * lev) / lev;
    return pow(c, float3(1.0 / gamma, 1.0 / gamma, 1.0 / gamma));
}

float3 nmsg_cnd_pixellate(UnityTexture2D tex, UnitySamplerState ss, float2 uv_in, float sizeIn, float2 res)
{
    float size = sizeIn;
    if (size < 1.0) { return SAMPLE_TEXTURE2D(tex.tex, ss.samplerstate, uv_in).rgb; }
    size *= 4.0;
    float dx = size / res.x;
    float dy = size / res.y;
    float2 uv = uv_in - 0.5;
    float2 coord = float2(dx * floor(uv.x / dx), dy * floor(uv.y / dy)) + 0.5;
    return SAMPLE_TEXTURE2D(tex.tex, ss.samplerstate, coord).rgb;
}

float3 nmsg_cnd_convolve(UnityTexture2D tex, UnitySamplerState ss, float2 uv, float kernel[9], bool divide, float effectAmt, float2 res)
{
    float2 steps = 1.0 / res;
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
        float3 color = SAMPLE_TEXTURE2D(tex.tex, ss.samplerstate, uv + offsets[i] * effectAmt).rgb;
        conv += color * kernel[i];
        kernelWeight += kernel[i];
    }
    if (divide && kernelWeight != 0.0) { conv /= kernelWeight; }
    return clamp(conv, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

float3 nmsg_cnd_derivatives(UnityTexture2D tex, UnitySamplerState ss, float3 color, float2 uv, bool divide, float effectAmt, float2 res)
{
    float deriv_x[9] = { 0.0, 0.0, 0.0, 0.0, 1.0, -1.0, 0.0, 0.0, 0.0 };
    float deriv_y[9] = { 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, -1.0, 0.0 };
    float3 s1 = nmsg_cnd_convolve(tex, ss, uv, deriv_x, divide, effectAmt, res);
    float3 s2 = nmsg_cnd_convolve(tex, ss, uv, deriv_y, divide, effectAmt, res);
    return color * distance(s1, s2);
}

float3 nmsg_cnd_sobel(UnityTexture2D tex, UnitySamplerState ss, float3 color, float2 uv, float effectAmt, float2 res)
{
    float sobel_x[9] = { 1.0, 0.0, -1.0, 2.0, 0.0, -2.0, 1.0, 0.0, -1.0 };
    float sobel_y[9] = { 1.0, 2.0, 1.0, 0.0, 0.0, 0.0, -1.0, -2.0, -1.0 };
    float3 s1 = nmsg_cnd_convolve(tex, ss, uv, sobel_x, false, effectAmt, res);
    float3 s2 = nmsg_cnd_convolve(tex, ss, uv, sobel_y, false, effectAmt, res);
    return color * distance(s1, s2);
}

float3 nmsg_cnd_outline(UnityTexture2D tex, UnitySamplerState ss, float3 color, float2 uv, float effectAmt, float2 res)
{
    float sobel_x[9] = { 1.0, 0.0, -1.0, 2.0, 0.0, -2.0, 1.0, 0.0, -1.0 };
    float sobel_y[9] = { 1.0, 2.0, 1.0, 0.0, 0.0, 0.0, -1.0, -2.0, -1.0 };
    float3 s1 = nmsg_cnd_convolve(tex, ss, uv, sobel_x, false, effectAmt, res);
    float3 s2 = nmsg_cnd_convolve(tex, ss, uv, sobel_y, false, effectAmt, res);
    return max(color - distance(s1, s2), float3(0.0, 0.0, 0.0));
}

float3 nmsg_cnd_shadow(UnityTexture2D tex, UnitySamplerState ss, float3 color_in, float2 uv, float effectAmt, float2 res)
{
    float sobel_x[9] = { 1.0, 0.0, -1.0, 2.0, 0.0, -2.0, 1.0, 0.0, -1.0 };
    float sobel_y[9] = { 1.0, 2.0, 1.0, 0.0, 0.0, 0.0, -1.0, -2.0, -1.0 };
    float3 color = nmsg_cnd_rgb2hsv(color_in);
    float3 x = nmsg_cnd_convolve(tex, ss, uv, sobel_x, false, effectAmt, res);
    float3 y = nmsg_cnd_convolve(tex, ss, uv, sobel_y, false, effectAmt, res);
    float shade_dist = distance(x, y);
    float highlight = shade_dist * shade_dist;
    float shade = (1.0 - ((1.0 - color.z) * (1.0 - highlight))) * shade_dist;
    color = float3(color.x, color.y, lerp(color.z, shade, 0.75));
    return nmsg_cnd_hsv2rgb(color);
}

float3 nmsg_cnd_convolutionEffect(UnityTexture2D tex, UnitySamplerState ss, float3 color, float2 uv, int EFFECT, float effectAmt, float2 res)
{
    float emboss[9]      = { -2.0, -1.0, 0.0, -1.0, 1.0, 1.0, 0.0, 1.0, 2.0 };
    float sharpen[9]     = { -1.0, 0.0, -1.0, 0.0, 5.0, 0.0, -1.0, 0.0, -1.0 };
    float blur[9]        = { 1.0, 2.0, 1.0, 2.0, 4.0, 2.0, 1.0, 2.0, 1.0 };
    float edge2[9]       = { -1.0, 0.0, -1.0, 0.0, 4.0, 0.0, -1.0, 0.0, -1.0 };
    float edge3[9]       = { -0.875, -0.75, -0.875, -0.75, 5.0, -0.75, -0.875, -0.75, -0.875 };
    float sharpenBlur[9] = { -2.0, 2.0, -2.0, 2.0, 1.0, 2.0, -2.0, 2.0, -2.0 };

    [branch]
    if (EFFECT == 1)        { return nmsg_cnd_convolve(tex, ss, uv, blur, true, effectAmt, res); }
    else if (EFFECT == 2)   { return nmsg_cnd_derivatives(tex, ss, color, uv, true, effectAmt, res); }
    else if (EFFECT == 120) { return clamp(nmsg_cnd_derivatives(tex, ss, color, uv, false, effectAmt, res) * 2.5, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0)); }
    else if (EFFECT == 3)   { return color * nmsg_cnd_convolve(tex, ss, uv, edge2, true, effectAmt, res); }
    else if (EFFECT == 4)   { return nmsg_cnd_convolve(tex, ss, uv, emboss, false, effectAmt, res); }
    else if (EFFECT == 5)   { return nmsg_cnd_outline(tex, ss, color, uv, effectAmt, res); }
    else if (EFFECT == 6)   { return nmsg_cnd_shadow(tex, ss, color, uv, effectAmt, res); }
    else if (EFFECT == 7)   { return nmsg_cnd_convolve(tex, ss, uv, sharpen, false, effectAmt, res); }
    else if (EFFECT == 8)   { return nmsg_cnd_sobel(tex, ss, color, uv, effectAmt, res); }
    else if (EFFECT == 9)   { return max(color, nmsg_cnd_convolve(tex, ss, uv, edge2, true, effectAmt, res)); }
    else if (EFFECT == 300) { return nmsg_cnd_convolve(tex, ss, uv, sharpenBlur, true, effectAmt, res); }
    else if (EFFECT == 301) { return nmsg_cnd_convolve(tex, ss, uv, edge3, true, effectAmt, res); }
    return color;
}

float3 nmsg_cnd_cga(UnityTexture2D tex, UnitySamplerState ss, float4 color, float2 st, float effectAmt, float2 res)
{
    float amt = nmsg_cnd_mapRange(effectAmt, 0.0, 20.0, 0.0, 5.0);
    if (amt < 0.01) { return color.rgb; }
    float pixelDensity = amt;
    float size = 2.0 * pixelDensity;
    float dSize = 2.0 * size;
    float amount = res.x / size;
    float d = 1.0 / amount;
    float ar = res.x / res.y;
    float sx = floor(st.x / d) * d;
    d = ar / amount;
    float sy = floor(st.y / d) * d;
    float4 base = SAMPLE_TEXTURE2D(tex.tex, ss.samplerstate, float2(sx, sy));
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
    float fx = st.x * res.x;
    float fy = st.y * res.y;
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

float3 nmsg_cnd_subpixel(UnityTexture2D tex, UnitySamplerState ss, float2 st, float scaleIn, float2 res)
{
    float scale = nmsg_cnd_mapRange(scaleIn, 0.0, 100.0, 0.0, 10.0);
    float3 orig = nmsg_cnd_pixellate(tex, ss, st, scale, res);
    float3 color = orig;
    float2 coord = floor(st * res);
    float m = fmod(coord.x, 4.0 * scale);
    if (fmod(coord.y, 4.0 * scale) <= scale)        { color *= float3(0.0, 0.0, 0.0); }
    else if (m <= scale)                            { color *= float3(1.0, 0.0, 0.0); }
    else if (m <= 2.0 * scale)                      { color *= float3(0.0, 1.0, 0.0); }
    else if (m <= 3.0 * scale)                      { color *= float3(0.0, 0.0, 1.0); }
    else                                            { color *= float3(0.0, 0.0, 0.0); }
    float factor = clamp(scale * 0.25, 0.0, 1.0);
    return lerp(orig, color, factor);
}

float3 nmsg_cnd_bloom(UnityTexture2D tex, UnitySamplerState ss, float2 st, float effectAmt)
{
    float3 sum = float3(0.0, 0.0, 0.0);
    float3 orig = SAMPLE_TEXTURE2D(tex.tex, ss.samplerstate, st).rgb;
    float strength = nmsg_cnd_mapRange(effectAmt, 0.0, 20.0, 0.0, 0.25);
    for (int i = -4; i < 4; i++)
    {
        for (int j = -3; j < 3; j++)
        {
            sum += SAMPLE_TEXTURE2D(tex.tex, ss.samplerstate, st + float2((float)j, (float)i) * 0.004).rgb * strength;
        }
    }
    float3 color;
    if (orig.r < 0.3)      { color = sum * sum * 0.012 + orig; }
    else if (orig.r < 0.5) { color = sum * sum * 0.009 + orig; }
    else                   { color = sum * sum * 0.0075 + orig; }
    return clamp(color, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

float3 nmsg_cnd_zoomBlur(UnityTexture2D tex, UnitySamplerState ss, float2 st, float effectAmt)
{
    float3 color = float3(0.0, 0.0, 0.0);
    float total = 0.0;
    float2 toCenter = st - 0.5;
    float offset = nmsg_cnd_prng(float3(12.9898, 78.233, 151.7182)).x;
    for (float t = 0.0; t <= 40.0; t += 1.0)
    {
        float percent = (t + offset) / 40.0;
        float weight = 4.0 * (percent - percent * percent);
        float strength = nmsg_cnd_mapRange(effectAmt, 0.0, 20.0, 0.0, 1.0);
        float4 texv = SAMPLE_TEXTURE2D(tex.tex, ss.samplerstate, st + toCenter * percent * strength);
        color += texv.rgb * weight;
        total += weight;
    }
    return color / total;
}

// Shader Graph Custom Function entry. UV is the fullscreen 0..1 coord that the
// runtime computes as fragCoord/resolution; Resolution is `u.resolution`.
// TODO(verify): SS must be a clamp, non-sRGB (linear) sampler state to match the
// runtime's bilinear/clamp/linear path (H7).
void NM_Effects_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float2            Resolution,
    int               Effect,
    int               Flip,
    float             EffectAmt,
    float             ScaleAmt,
    float             Rotation,
    float             OffsetX,
    float             OffsetY,
    float             Intensity,
    float             Saturation,
    out float4        Out)
{
    float2 res = Resolution;
    float2 uv = UV;

    float scale = 100.0 / ScaleAmt;
    if (scale == 0.0) { scale = 1.0; }

    uv = nmsg_cnd_rotate2D(uv, Rotation, res);
    uv -= 0.5;
    uv *= scale;
    uv += 0.5;

    float2 imageSize = res;
    uv.x -= ceil((res.x / imageSize.x * scale * 0.5) - (0.5 - (1.0 / imageSize.x * scale)));
    uv.y += ceil((res.y / imageSize.y * scale * 0.5) + (0.5 - (1.0 / imageSize.y * scale)) - scale);
    uv.x -= nmsg_cnd_mapRange(OffsetX, -100.0, 100.0, -res.x / imageSize.x * scale, res.x / imageSize.x * scale) * 1.5;
    uv.y -= nmsg_cnd_mapRange(OffsetY, -100.0, 100.0, -res.y / imageSize.y * scale, res.y / imageSize.y * scale) * 1.5;
    uv = frac(uv);

    [branch]
    if (Flip == 1)       { uv = 1.0 - uv; }
    else if (Flip == 2)  { uv.x = 1.0 - uv.x; }
    else if (Flip == 3)  { uv.y = 1.0 - uv.y; }
    else if (Flip == 11) { if (uv.x > 0.5) { uv.x = 1.0 - uv.x; } }
    else if (Flip == 12) { if (uv.x < 0.5) { uv.x = 1.0 - uv.x; } }
    else if (Flip == 13) { if (uv.y > 0.5) { uv.y = 1.0 - uv.y; } }
    else if (Flip == 14) { if (uv.y < 0.5) { uv.y = 1.0 - uv.y; } }
    else if (Flip == 15) { if (uv.x > 0.5) { uv.x = 1.0 - uv.x; } if (uv.y > 0.5) { uv.y = 1.0 - uv.y; } }
    else if (Flip == 16) { if (uv.x > 0.5) { uv.x = 1.0 - uv.x; } if (uv.y < 0.5) { uv.y = 1.0 - uv.y; } }
    else if (Flip == 17) { if (uv.x < 0.5) { uv.x = 1.0 - uv.x; } if (uv.y > 0.5) { uv.y = 1.0 - uv.y; } }
    else if (Flip == 18) { if (uv.x < 0.5) { uv.x = 1.0 - uv.x; } if (uv.y < 0.5) { uv.y = 1.0 - uv.y; } }

    float4 color = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv);

    if (EffectAmt != 0.0 && Effect != 0)
    {
        [branch]
        if (Effect == 100)      { color = float4(nmsg_cnd_pixellate(InputTex, SS, uv, EffectAmt, res), color.a); }
        else if (Effect == 110) { color = float4(nmsg_cnd_posterize(color.rgb, EffectAmt), color.a); }
        else if (Effect == 200) { color = float4(nmsg_cnd_cga(InputTex, SS, color, uv, EffectAmt, res), color.a); }
        else if (Effect == 210) { color = float4(nmsg_cnd_subpixel(InputTex, SS, uv, EffectAmt, res), color.a); }
        else if (Effect == 220) { color = float4(nmsg_cnd_bloom(InputTex, SS, uv, EffectAmt), color.a); }
        else if (Effect == 230) { color = float4(nmsg_cnd_zoomBlur(InputTex, SS, uv, EffectAmt), color.a); }
        else                    { color = float4(nmsg_cnd_convolutionEffect(InputTex, SS, color.rgb, uv, Effect, EffectAmt, res), color.a); }
    }

    float3 c = nmsg_cnd_brightnessContrast(color.rgb, Intensity);
    c = nmsg_cnd_saturateFn(c, Saturation);

    Out = float4(c, color.a);
}

#endif // NM_SG_CLASSICNOISEDECK_EFFECTS_INCLUDED
