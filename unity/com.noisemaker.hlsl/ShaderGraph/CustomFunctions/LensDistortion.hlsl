#ifndef NM_SG_LENSDISTORTION_INCLUDED
#define NM_SG_LENSDISTORTION_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for classicNoisedeck/lensDistortion.
//
// Single-pass filter: takes an InputTex + sampler + UV and all named params.
// UV must be the input texture's own 0..1 UV (fragCoord / resolution).
//
// Self-contained — does NOT include NMFullscreen.hlsl/NMCore.hlsl.
// Helpers prefixed `nmsg_ld_` to avoid symbol clashes with the runtime include.
//
// NOTE: `time` and `resolution` are engine globals injected by the runtime;
// they must be plumbed into the Shader Graph node as float / float2 inputs.
// TODO(verify): SS must be a clamp, non-sRGB (linear) sampler state to match
// the runtime bilinear/clamp/linear path (PORTING-GUIDE H7).
// =============================================================================

static const float NMSG_LD_PI  = 3.14159265359;
static const float NMSG_LD_TAU = 6.28318530718;

float nmsg_ld_nm_mod(float a, float b) { return a - b * floor(a / b); }

float nmsg_ld_mapVal(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

float3 nmsg_ld_hsv2rgb(float3 hsv)
{
    float h = frac(hsv.x);
    float s = hsv.y;
    float v = hsv.z;
    float c = v * s;
    float x = c * (1.0 - abs(nmsg_ld_nm_mod(h * 6.0, 2.0) - 1.0));
    float m = v - c;
    float3 rgb;
    if      (h < 1.0/6.0) { rgb = float3(c, x, 0.0); }
    else if (h < 2.0/6.0) { rgb = float3(x, c, 0.0); }
    else if (h < 3.0/6.0) { rgb = float3(0.0, c, x); }
    else if (h < 4.0/6.0) { rgb = float3(0.0, x, c); }
    else if (h < 5.0/6.0) { rgb = float3(x, 0.0, c); }
    else                   { rgb = float3(c, 0.0, x); }
    return rgb + float3(m, m, m);
}

float3 nmsg_ld_rgb2hsv(float3 rgb)
{
    float r = rgb.r; float g = rgb.g; float b = rgb.b;
    float maxC = max(r, max(g, b));
    float minC = min(r, min(g, b));
    float delta = maxC - minC;
    float h = 0.0;
    if (delta != 0.0)
    {
        if      (maxC == r) { h = nmsg_ld_nm_mod((g - b) / delta, 6.0) / 6.0; }
        else if (maxC == g) { h = ((b - r) / delta + 2.0) / 6.0; }
        else                { h = ((r - g) / delta + 4.0) / 6.0; }
    }
    if (h < 0.0) { h = h + 1.0; }
    float s = 0.0;
    if (maxC != 0.0) { s = delta / maxC; }
    return float3(h, s, maxC);
}

float3 nmsg_ld_saturateColor(float3 color, float saturation)
{
    float sat = nmsg_ld_mapVal(saturation, -100.0, 100.0, -1.0, 1.0);
    float avg = (color.r + color.g + color.b) / 3.0;
    return color - (avg - color) * sat;
}

float nmsg_ld_distance(float2 diff, float2 uv, float2 res,
                       int shape, float loopScale, float speed, float t_time)
{
    float ar = res.x / res.y;
    float uvx = uv.x * ar;
    float dist = 1.0;
    if      (shape == 0)  { dist = length(diff); }
    else if (shape == 1)  { dist = abs(uvx - 0.5 * ar) + abs(uv.y - 0.5); }
    else if (shape == 2)  { dist = max(max(abs(diff.x) - diff.y * -0.5, -1.0 * diff.y), max(abs(diff.x) - diff.y * 0.5, 1.0 * diff.y)); }
    else if (shape == 3)  { dist = max((abs(uvx - 0.5 * ar) + abs(uv.y - 0.5)) / sqrt(2.0), max(abs(uvx - 0.5 * ar), abs(uv.y - 0.5))); }
    else if (shape == 4)  { dist = max(abs(uvx - 0.5 * ar), abs(uv.y - 0.5)); }
    else if (shape == 6)  { dist = max(abs(diff.x) - diff.y * -0.5, -1.0 * diff.y); }
    else if (shape == 10) { dist = 1.0 - length(float2((cos(diff.x * NMSG_LD_TAU) + 1.0) * 0.5, (cos(diff.y * NMSG_LD_TAU) + 1.0) * 0.5)); }
    float lf = nmsg_ld_mapVal(loopScale, 1.0, 100.0, 6.0, 1.0);
    float t = (speed < 0.0) ? (dist * lf + t_time) : (dist * lf - t_time);
    return lerp(dist, (sin(t * NMSG_LD_TAU) + 1.0 * 0.5) * abs(speed) * 0.005, abs(speed) * 0.01);
}

void NM_LensDistortion_float(
    UnityTexture2D  InputTex,
    UnitySamplerState SS,
    float2          UV,
    float2          Resolution,
    float           Time,
    int             Shape,
    float           Distortion,
    int             AspectLens,
    float           LoopScale,
    float           Speed,
    int             Mode,
    float           Aberration,
    int             BlendMode,
    int             Modulate,
    float4          Tint,
    float           Alpha,
    float           HueRotation,
    float           HueRange,
    float           Saturation,
    float           Passthru,
    float           VignetteAmt,
    out float4      Out)
{
    float ar = Resolution.x / Resolution.y;
    float2 uv = UV;

    float4 color = float4(0.0, 0.0, 0.0, 1.0);

    float2 diff = float2(0.5, 0.5) - uv;
    if (AspectLens != 0)
        diff = float2(0.5 * ar, 0.5) - float2(uv.x * ar, uv.y);
    float centerDist = nmsg_ld_distance(diff, uv, Resolution, Shape, LoopScale, Speed, Time);

    float distort = 0.0;
    float zoom    = 1.0;
    if (Distortion < 0.0)
    {
        distort = nmsg_ld_mapVal(Distortion, -100.0, 0.0, -2.0, 0.0);
        zoom    = nmsg_ld_mapVal(Distortion, -100.0, 0.0, 0.04, 0.0);
    }
    else
    {
        distort = nmsg_ld_mapVal(Distortion, 0.0, 100.0, 0.0, 2.0);
        zoom    = nmsg_ld_mapVal(Distortion, 0.0, 100.0, 0.0, -1.0);
    }

    float2 lensedCoords = frac((uv - diff * zoom) - diff * centerDist * centerDist * distort);
    float aberrationOffset = nmsg_ld_mapVal(Aberration, 0.0, 100.0, 0.0, 0.05) * centerDist * NMSG_LD_PI * 0.5;

    float redOffset  = lerp(clamp(lensedCoords.x + aberrationOffset, 0.0, 1.0), lensedCoords.x, lensedCoords.x);
    float4 red   = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, float2(redOffset, lensedCoords.y));
    float4 green = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, lensedCoords);
    float blueOffset = lerp(lensedCoords.x, clamp(lensedCoords.x - aberrationOffset, 0.0, 1.0), lensedCoords.x);
    float4 blue  = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, float2(blueOffset, lensedCoords.y));

    float3 hsv = float3(1.0, 1.0, 1.0);
    float t = 0.0;
    if (Modulate != 0) t = Time;

    if (Mode == 0)
    {
        color = float4(red.r, green.g, blue.b, color.a) - green;
        color = float4(color.rgb, green.a);
        hsv = nmsg_ld_rgb2hsv(color.rgb);
        hsv = float3(frac(hsv.x + (1.0 - (HueRotation / 360.0)) + hsv.x * HueRange * 0.01 + t), 1.0, hsv.z);
    }
    else
    {
        color = float4(float3(length(float4(red.r, green.g, blue.b, color.a) - green)) * green.rgb, green.a);
        hsv = nmsg_ld_rgb2hsv(color.rgb);
        hsv = float3(frac(((hsv.x + 0.125 + (1.0 - (HueRotation / 360.0))) * (2.0 + HueRange * 0.05)) + t), 1.0, hsv.z);
    }

    float3 greenMod = nmsg_ld_saturateColor(green.rgb, Saturation) * nmsg_ld_mapVal(Passthru, 0.0, 100.0, 0.0, 2.0);

    if (BlendMode == 0)
        color = float4(min(greenMod + nmsg_ld_hsv2rgb(hsv), float3(1.0, 1.0, 1.0)), color.a);
    else if (BlendMode == 1)
        color = float4(min(max(greenMod - float3(hsv.z, hsv.z, hsv.z), float3(0.0, 0.0, 0.0)) + nmsg_ld_hsv2rgb(hsv), float3(1.0, 1.0, 1.0)), color.a);

    float3 tintResult;
    if (all(color.rgb == float3(1.0, 1.0, 1.0)))
        tintResult = color.rgb;
    else
        tintResult = min(Tint.rgb * Tint.rgb / (float3(1.0, 1.0, 1.0) - color.rgb), float3(1.0, 1.0, 1.0));
    color = float4(lerp(color.rgb, tintResult, Alpha * 0.01), max(color.a, Alpha * 0.01));

    if (VignetteAmt < 0.0)
    {
        float vigFactor = 1.0 - pow(length(float2(0.5, 0.5) - uv) * 1.125, 2.0);
        color = float4(
            lerp(color.rgb * vigFactor, color.rgb, nmsg_ld_mapVal(VignetteAmt, -100.0, 0.0, 0.0, 1.0)),
            max(color.a, length(float2(0.5, 0.5) - uv) * nmsg_ld_mapVal(VignetteAmt, -100.0, 0.0, 1.0, 0.0))
        );
    }
    else
    {
        float vigFactor = 1.0 - pow(length(float2(0.5, 0.5) - uv) * 1.125, 2.0);
        color = float4(
            lerp(color.rgb, float3(1.0, 1.0, 1.0) - (float3(1.0, 1.0, 1.0) - color.rgb * vigFactor), nmsg_ld_mapVal(VignetteAmt, 0.0, 100.0, 0.0, 1.0)),
            max(color.a, length(float2(0.5, 0.5) - uv) * nmsg_ld_mapVal(VignetteAmt, -100.0, 0.0, 1.0, 0.0))
        );
    }

    Out = color;
}

#endif // NM_SG_LENSDISTORTION_INCLUDED
