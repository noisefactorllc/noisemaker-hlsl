#ifndef NM_SG_ADJUST_INCLUDED
#define NM_SG_ADJUST_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for filter/adjust.
//
// Drops the effect into Shader Graph as a node. Each global param from
// definition.js maps to a named input:
//   mode        -> Mode (int)     0 rgb / 1 hsv / 2 oklab / 3 oklch
//   rotation    -> Rotation (float, degrees)
//   hueRange    -> HueRange (float)
//   saturation  -> Saturation (float)
//   brightness  -> Brightness (float)
//   contrast    -> Contrast (float)
// InputTex/SS/UV provide the source surface. UV must be the input texture's own
// 0..1 UV (the runtime path divides fragCoord by the input texture dimensions).
//
// Self-contained (does NOT include NMFullscreen.hlsl / NMCore.hlsl) so it is
// safe to drop into a Shader Graph Custom Function node. Helpers/core are
// mirrored VERBATIM from Shaders/Effects/filter/Adjust.hlsl, name-prefixed
// `nmsg_` to avoid symbol clashes with the runtime include.
// =============================================================================

static const float NMSG_ADJ_TAU = 6.28318530718;

float nmsg_adj_mapVal(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

float nmsg_adj_floorMod(float x, float y)
{
    return x - y * floor(x / y);
}

float3 nmsg_adj_hsv2rgb(float3 hsv)
{
    float h = frac(hsv.x);
    float s = hsv.y;
    float v = hsv.z;
    float c = v * s;
    float x = c * (1.0 - abs(nmsg_adj_floorMod(h * 6.0, 2.0) - 1.0));
    float m = v - c;
    float3 rgb;
    if (h < 1.0/6.0) { rgb = float3(c, x, 0.0); }
    else if (h < 2.0/6.0) { rgb = float3(x, c, 0.0); }
    else if (h < 3.0/6.0) { rgb = float3(0.0, c, x); }
    else if (h < 4.0/6.0) { rgb = float3(0.0, x, c); }
    else if (h < 5.0/6.0) { rgb = float3(x, 0.0, c); }
    else { rgb = float3(c, 0.0, x); }
    return rgb + m;
}

float3 nmsg_adj_rgb2hsv(float3 rgb)
{
    float r = rgb.r; float g = rgb.g; float b = rgb.b;
    float maxC = max(r, max(g, b));
    float minC = min(r, min(g, b));
    float delta = maxC - minC;

    float h = 0.0;
    if (delta != 0.0)
    {
        if (maxC == r)
        {
            h = nmsg_adj_floorMod((g - b) / delta, 6.0) / 6.0;
        }
        else if (maxC == g)
        {
            h = ((b - r) / delta + 2.0) / 6.0;
        }
        else
        {
            h = ((r - g) / delta + 4.0) / 6.0;
        }
    }
    float s = 0.0;
    if (maxC != 0.0) { s = delta / maxC; }
    return float3(h, s, maxC);
}

// OKLab -> linear sRGB. WGSL mat3x3 column-major; M*c = col0*c.x+col1*c.y+col2*c.z.
float3 nmsg_adj_linear_srgb_from_oklab(float3 c)
{
    float3 fwdA_c0 = float3(1.0, 1.0, 1.0);
    float3 fwdA_c1 = float3(0.3963377774, -0.1055613458, -0.0894841775);
    float3 fwdA_c2 = float3(0.2158037573, -0.0638541728, -1.2914855480);
    float3 lms = fwdA_c0 * c.x + fwdA_c1 * c.y + fwdA_c2 * c.z;

    float3 cubed = lms * lms * lms;

    float3 fwdB_c0 = float3(4.0767245293, -1.2681437731, -0.0041119885);
    float3 fwdB_c1 = float3(-3.3072168827, 2.6093323231, -0.7034763098);
    float3 fwdB_c2 = float3(0.2307590544, -0.3411344290, 1.7068625689);
    return fwdB_c0 * cubed.x + fwdB_c1 * cubed.y + fwdB_c2 * cubed.z;
}

float3 nmsg_adj_linearToSrgb(float3 lin)
{
    float3 srgb;
    [unroll]
    for (int i = 0; i < 3; i = i + 1)
    {
        if (lin[i] <= 0.0031308)
        {
            srgb[i] = lin[i] * 12.92;
        }
        else
        {
            srgb[i] = 1.055 * pow(lin[i], 1.0 / 2.4) - 0.055;
        }
    }
    return srgb;
}

// Core nm_adjust (param-injected), verbatim from Adjust.hlsl nm_adjust().
float4 nmsg_adjust(float4 color, int mode, float rotation, float hueRange,
                   float saturation, float brightness, float contrast)
{
    // --- Colorspace reinterpretation ---
    if (mode == 1)
    {
        color = float4(nmsg_adj_hsv2rgb(color.rgb), color.a);
    }
    else if (mode == 2)
    {
        float3 lab = color.rgb;
        lab.g = lab.g * -0.509 + 0.276;
        lab.b = lab.b * -0.509 + 0.198;
        float3 rgb = nmsg_adj_linear_srgb_from_oklab(lab);
        rgb = nmsg_adj_linearToSrgb(rgb);
        color = float4(rgb, color.a);
    }
    else if (mode == 3)
    {
        float L = color.r;
        float C = color.g * 0.4;
        float H = color.b * NMSG_ADJ_TAU;
        float a = C * cos(H);
        float b = C * sin(H);
        float3 rgb = nmsg_adj_linear_srgb_from_oklab(float3(L, a, b));
        rgb = nmsg_adj_linearToSrgb(rgb);
        color = float4(rgb, color.a);
    }

    // --- Hue / Saturation ---
    float3 hsv = nmsg_adj_rgb2hsv(color.rgb);
    hsv.x = frac(hsv.x * nmsg_adj_mapVal(hueRange, 0.0, 200.0, 0.0, 2.0) + (rotation / 360.0));
    hsv.y = hsv.y * saturation;
    color = float4(nmsg_adj_hsv2rgb(hsv), color.a);

    // --- Brightness / Contrast ---
    color = float4(color.rgb * brightness, color.a);
    float contrastFactor = contrast * 2.0;
    color = float4((color.rgb - 0.5) * contrastFactor + 0.5, color.a);

    return color;
}

// Shader Graph Custom Function entry. Samples InputTex at UV, then applies the
// full adjust chain. // TODO(verify): SS must be a clamp, non-sRGB (linear)
// sampler state so it matches the runtime's bilinear/clamp/linear path (H7).
void NM_Adjust_float(int Mode, float Rotation, float HueRange, float Saturation,
                     float Brightness, float Contrast,
                     UnityTexture2D InputTex, UnitySamplerState SS, float2 UV,
                     out float4 Out)
{
    float4 color = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, UV);
    Out = nmsg_adjust(color, Mode, Rotation, HueRange, Saturation, Brightness, Contrast);
}

#endif // NM_SG_ADJUST_INCLUDED
