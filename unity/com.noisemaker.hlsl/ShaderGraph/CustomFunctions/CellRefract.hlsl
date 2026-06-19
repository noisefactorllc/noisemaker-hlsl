#ifndef NM_SG_CELLREFRACT_INCLUDED
#define NM_SG_CELLREFRACT_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for classicNoisedeck/cellRefract.
//
// Single-input filter, single render pass. Each global param from definition.js
// maps to a named input; SHAPE/KERNEL are exposed as int inputs (compile-time
// defines in the reference, branched at runtime here). Time/Resolution are
// exposed because the core references `time` and `aspectRatio`; the input
// texture's own dimensions provide the convolve/pixellate texel size.
//
// Self-contained (does NOT include NMFullscreen.hlsl / NMCore.hlsl) so it is
// safe in a Shader Graph Custom Function node. Helpers/PCG are mirrored VERBATIM
// from Shaders/Effects/classicNoisedeck/CellRefract.hlsl, prefixed `nmsg_` to
// avoid symbol clashes.
//
// PRNG note: this effect uses PLAIN (uint3)p truncation, NO sign-fold (unlike
// the shared NMCore nm_prng). Ported inline below.
// TODO(verify): SS must be a clamp, non-sRGB (linear) sampler state matching the
// runtime bilinear/clamp/linear path (H7). UV must be the input texture's 0..1
// UV. Single-pass; this wrapper is provided.
// =============================================================================

#define NMSG_CR_PI  3.14159265359
#define NMSG_CR_TAU 6.28318530718

uint3 nmsg_cr_pcg(uint3 v)
{
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return v;
}

float3 nmsg_cr_prng(float3 p)
{
    return float3(nmsg_cr_pcg((uint3)p)) / 4294967295.0;
}

float nmsg_cr_map(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

float nmsg_cr_mod(float a, float b) { return a - b * floor(a / b); }

float3 nmsg_cr_hsv2rgb(float3 hsv)
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

float3 nmsg_cr_rgb2hsv(float3 rgb)
{
    float maxC = max(rgb.r, max(rgb.g, rgb.b));
    float minC = min(rgb.r, min(rgb.g, rgb.b));
    float delta = maxC - minC;
    float h = 0.0;
    if (delta != 0.0)
    {
        if (maxC == rgb.r)      { h = nmsg_cr_mod((rgb.g - rgb.b) / delta, 6.0) / 6.0; }
        else if (maxC == rgb.g) { h = ((rgb.b - rgb.r) / delta + 2.0) / 6.0; }
        else                    { h = ((rgb.r - rgb.g) / delta + 4.0) / 6.0; }
    }
    float s = (maxC != 0.0) ? (delta / maxC) : 0.0;
    return float3(h, s, maxC);
}

float3 nmsg_cr_convolve(UnityTexture2D InputTex, UnitySamplerState SS, float2 uv,
                        float kernel[9], bool divide, float2 texSize, float effectWidth)
{
    float2 steps = 1.0 / texSize;
    float2 offsets[9] =
    {
        float2(-steps.x, -steps.y), float2(0.0, -steps.y), float2(steps.x, -steps.y),
        float2(-steps.x, 0.0),      float2(0.0, 0.0),      float2(steps.x, 0.0),
        float2(-steps.x, steps.y),  float2(0.0, steps.y),  float2(steps.x, steps.y)
    };
    float kernelWeight = 0.0;
    float3 conv = float3(0.0, 0.0, 0.0);
    [unroll]
    for (int i = 0; i < 9; i++)
    {
        float3 color = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv + offsets[i] * effectWidth).rgb;
        conv += color * kernel[i];
        kernelWeight += kernel[i];
    }
    if (divide && kernelWeight != 0.0) { conv /= kernelWeight; }
    return clamp(conv, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

float3 nmsg_cr_derivatives(UnityTexture2D InputTex, UnitySamplerState SS, float3 color,
                           float2 uv, bool divide, float2 texSize, float effectWidth)
{
    float deriv_x[9] = { 0.0, 0.0, 0.0, 0.0, 1.0, -1.0, 0.0, 0.0, 0.0 };
    float deriv_y[9] = { 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, -1.0, 0.0 };
    float3 s1 = nmsg_cr_convolve(InputTex, SS, uv, deriv_x, divide, texSize, effectWidth);
    float3 s2 = nmsg_cr_convolve(InputTex, SS, uv, deriv_y, divide, texSize, effectWidth);
    float dist = distance(s1, s2);
    return color * dist;
}

float3 nmsg_cr_sobel(UnityTexture2D InputTex, UnitySamplerState SS, float3 color,
                     float2 uv, float2 texSize, float effectWidth)
{
    float sobel_x[9] = { 1.0, 0.0, -1.0, 2.0, 0.0, -2.0, 1.0, 0.0, -1.0 };
    float sobel_y[9] = { 1.0, 2.0, 1.0, 0.0, 0.0, 0.0, -1.0, -2.0, -1.0 };
    float3 s1 = nmsg_cr_convolve(InputTex, SS, uv, sobel_x, false, texSize, effectWidth);
    float3 s2 = nmsg_cr_convolve(InputTex, SS, uv, sobel_y, false, texSize, effectWidth);
    float dist = distance(s1, s2);
    return color * dist;
}

float3 nmsg_cr_shadow(UnityTexture2D InputTex, UnitySamplerState SS, float3 color_in,
                      float2 uv, float2 texSize, float effectWidth)
{
    float sobel_x[9] = { 1.0, 0.0, -1.0, 2.0, 0.0, -2.0, 1.0, 0.0, -1.0 };
    float sobel_y[9] = { 1.0, 2.0, 1.0, 0.0, 0.0, 0.0, -1.0, -2.0, -1.0 };
    float3 color = nmsg_cr_rgb2hsv(color_in);
    float3 x = nmsg_cr_convolve(InputTex, SS, uv, sobel_x, false, texSize, effectWidth);
    float3 y = nmsg_cr_convolve(InputTex, SS, uv, sobel_y, false, texSize, effectWidth);
    float shade_dist = distance(x, y);
    float highlight = shade_dist * shade_dist;
    float shade = (1.0 - ((1.0 - color.z) * (1.0 - highlight))) * shade_dist;
    float alpha = 0.75;
    color = float3(color.x, color.y, lerp(color.z, shade, alpha));
    return nmsg_cr_hsv2rgb(color);
}

float3 nmsg_cr_outline(UnityTexture2D InputTex, UnitySamplerState SS, float3 color,
                       float2 uv, float2 texSize, float effectWidth)
{
    float sobel_x[9] = { 1.0, 0.0, -1.0, 2.0, 0.0, -2.0, 1.0, 0.0, -1.0 };
    float sobel_y[9] = { 1.0, 2.0, 1.0, 0.0, 0.0, 0.0, -1.0, -2.0, -1.0 };
    float3 s1 = nmsg_cr_convolve(InputTex, SS, uv, sobel_x, false, texSize, effectWidth);
    float3 s2 = nmsg_cr_convolve(InputTex, SS, uv, sobel_y, false, texSize, effectWidth);
    float dist = distance(s1, s2);
    return max(color - dist, float3(0.0, 0.0, 0.0));
}

float3 nmsg_cr_convolutionKernel(UnityTexture2D InputTex, UnitySamplerState SS, float3 color,
                                 float2 uv, float2 texSize, float effectWidth, int KERNEL)
{
    float emboss[9]  = { -2.0, -1.0, 0.0, -1.0, 1.0, 1.0, 0.0, 1.0, 2.0 };
    float sharpen[9] = { -1.0, 0.0, -1.0, 0.0, 5.0, 0.0, -1.0, 0.0, -1.0 };
    float blur[9]    = { 1.0, 2.0, 1.0, 2.0, 4.0, 2.0, 1.0, 2.0, 1.0 };
    float edge2[9]   = { -1.0, 0.0, -1.0, 0.0, 4.0, 0.0, -1.0, 0.0, -1.0 };

    [branch]
    if (KERNEL == 1)        { return nmsg_cr_convolve(InputTex, SS, uv, blur, true, texSize, effectWidth); }
    else if (KERNEL == 2)   { return nmsg_cr_derivatives(InputTex, SS, color, uv, true, texSize, effectWidth); }
    else if (KERNEL == 120) { return clamp(nmsg_cr_derivatives(InputTex, SS, color, uv, false, texSize, effectWidth) * 2.5, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0)); }
    else if (KERNEL == 3)   { return color * nmsg_cr_convolve(InputTex, SS, uv, edge2, true, texSize, effectWidth); }
    else if (KERNEL == 4)   { return nmsg_cr_convolve(InputTex, SS, uv, emboss, false, texSize, effectWidth); }
    else if (KERNEL == 5)   { return nmsg_cr_outline(InputTex, SS, color, uv, texSize, effectWidth); }
    else if (KERNEL == 6)   { return nmsg_cr_shadow(InputTex, SS, color, uv, texSize, effectWidth); }
    else if (KERNEL == 7)   { return nmsg_cr_convolve(InputTex, SS, uv, sharpen, false, texSize, effectWidth); }
    else if (KERNEL == 8)   { return nmsg_cr_sobel(InputTex, SS, color, uv, texSize, effectWidth); }
    else if (KERNEL == 9)   { return max(color, nmsg_cr_convolve(InputTex, SS, uv, edge2, true, texSize, effectWidth)); }
    return color;
}

float nmsg_cr_polarShape(float2 st, int sides)
{
    float a = atan2(st.x, st.y) + NMSG_CR_PI;
    float r = NMSG_CR_TAU / (float)sides;
    return cos(floor(0.5 + a / r) * r - a) * length(st);
}

float nmsg_cr_shapeFn(float2 st_in, float2 offset, float scaleArg, int SHAPE)
{
    float2 st = st_in + offset;
    float d = 1.0;
    [branch]
    if (SHAPE == 0)      { d = length(st * 1.2); }
    else if (SHAPE == 2) { d = nmsg_cr_polarShape(st * 1.2, 6); }
    else if (SHAPE == 3) { d = nmsg_cr_polarShape(st * 1.2, 8); }
    else if (SHAPE == 4) { d = nmsg_cr_polarShape(st * 1.5, 4); }
    else if (SHAPE == 6) { d = nmsg_cr_polarShape(float2(st.x, st.y + 0.05) * 1.5, 3); }
    return d * scaleArg;
}

float nmsg_cr_smin(float a, float b, float k)
{
    if (k == 0.0) { return min(a, b); }
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

float nmsg_cr_cells(float2 st_in, float freq, float cellSize, int seed, float speed,
                    float time, float variation, float cellSmooth, int SHAPE)
{
    float2 st = st_in * freq;
    st += nmsg_cr_prng(float3((float)seed, (float)seed, (float)seed)).xy;
    float2 i = floor(st);
    float2 f = frac(st);
    float d = 1.0;
    [unroll]
    for (int y = -2; y <= 2; y++)
    {
        [unroll]
        for (int x = -2; x <= 2; x++)
        {
            float2 n = float2((float)x, (float)y);
            float2 wrap_coord = i + n;
            float2 point = nmsg_cr_prng(float3(wrap_coord, (float)seed)).xy;
            float3 r1 = nmsg_cr_prng(float3((float)seed, wrap_coord)) * 0.5 - 0.25;
            float3 r2 = nmsg_cr_prng(float3(wrap_coord, (float)seed)) * 2.0 - 1.0;
            float spd = floor(speed);
            point += float2(sin(time * NMSG_CR_TAU * spd + r2.x) * r1.x, cos(time * NMSG_CR_TAU * spd + r2.y) * r1.y);
            float2 diff = n + point - f;
            float dist;
            [branch]
            if (SHAPE == 1)
            {
                dist = (abs(n.x + point.x - f.x) + abs(n.y + point.y - f.y)) * cellSize;
            }
            else
            {
                dist = nmsg_cr_shapeFn(float2(diff.x, -diff.y), float2(0.0, 0.0), cellSize, SHAPE);
            }
            dist += r1.z * (variation * 0.01);
            d = nmsg_cr_smin(d, dist, cellSmooth * 0.01);
        }
    }
    return d;
}

float3 nmsg_cr_posterize(float3 color, float levIn)
{
    float lev = levIn;
    if (lev == 0.0) { return color; }
    else if (lev == 1.0) { lev = 2.0; }
    float3 c = clamp(color, float3(0.0, 0.0, 0.0), float3(0.99, 0.99, 0.99));
    return (floor(c * lev) + 0.5) / lev;
}

float3 nmsg_cr_pixellate(UnityTexture2D InputTex, UnitySamplerState SS, float2 uv,
                         float size, float2 texSize)
{
    if (size <= 1.0) { return SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv).rgb; }
    float dx = size / texSize.x;
    float dy = size / texSize.y;
    float2 coord = float2(dx * floor(uv.x / dx), dy * floor(uv.y / dy));
    return SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, coord).rgb;
}

// Shader Graph Custom Function entry.
//   UV         — input texture's 0..1 UV (= reference `st = globalCoord/fullRes`)
//   Resolution — full render resolution (for aspectRatio); dims for convolve/
//                pixellate come from the bound texture.
void NM_CellRefract_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float2            Resolution,
    float             Time,
    float             RefractAmt,
    float             Direction,
    int               Wrap,
    float             Speed,
    int               Shape,
    float             Scale,
    float             CellScale,
    float             CellSmooth,
    float             Variation,
    int               Seed,
    int               Kernel,
    float             EffectWidth,
    out float4        Out)
{
    float texW, texH;
    InputTex.GetDimensions(texW, texH);
    float2 texSize = float2(texW, texH);

    float aspectRatio = Resolution.x / Resolution.y;

    float2 st = UV;
    float freq = nmsg_cr_map(Scale, 1.0, 100.0, 20.0, 1.0);
    float cellSize = nmsg_cr_map(CellScale, 1.0, 100.0, 3.0, 0.75);
    float d = nmsg_cr_cells(st * float2(aspectRatio, 1.0), freq, cellSize,
                            Seed, Speed, Time, Variation, CellSmooth, Shape);
    float refAmt = nmsg_cr_map(RefractAmt, 0.0, 100.0, 0.0, 0.125);
    float refLen = d + Direction / 360.0;
    st.x += cos(refLen * NMSG_CR_TAU) * refAmt;
    st.y += sin(refLen * NMSG_CR_TAU) * refAmt;

    if (Wrap == 1)
    {
        st = frac(st);
    }

    float2 localUV = st;
    float4 color = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, localUV);

    float ew = EffectWidth;
    [branch]
    if (ew != 0.0 && Kernel != 0)
    {
        if (Kernel == 100)
        {
            color = float4(nmsg_cr_pixellate(InputTex, SS, localUV, ew * 4.0, texSize), color.a);
        }
        else if (Kernel == 110)
        {
            color = float4(nmsg_cr_posterize(color.rgb, floor(nmsg_cr_map(ew, 0.0, 10.0, 0.0, 20.0))), color.a);
        }
        else
        {
            color = float4(nmsg_cr_convolutionKernel(InputTex, SS, color.rgb, localUV, texSize, ew, Kernel), color.a);
        }
    }

    Out = color;
}

#endif // NM_SG_CELLREFRACT_INCLUDED
