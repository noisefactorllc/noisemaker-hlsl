#ifndef NM_SG_REFRACT_INCLUDED
#define NM_SG_REFRACT_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for classicNoisedeck/refract.
//
// Drops the effect into Shader Graph as a single-input filter node.
// Each global param from definition.js maps to a named input:
//   Mode       (int,   0=refract 1=reflect)  default 0
//   Amount     (float, [0,100])               default 50
//   Direction  (float, [0,360])               default 0
//   BlendMode  (int,   enum 0..18)            default 10
//   MixAmt     (float, [0,100])               default 50
//   Wrap       (int,   0=mirror 1=repeat 2=clamp) default 0
//
// Self-contained: does NOT include NMFullscreen.hlsl / NMCore.hlsl.
// Helpers are verbatim from Refract.hlsl, prefixed `nmsg_refract_`.
// TODO(verify): sampler_inputTex must be a mirror-wrap, non-sRGB (linear)
// sampler so wrap==0 matches the runtime path.
// =============================================================================

static const float NM_SG_REFRACT_TAU = 6.28318530718;

float nmsg_refract_map_range(float value, float inMin, float inMax,
                             float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

float nmsg_refract_desaturate(float3 color)
{
    return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
}

float3 nmsg_refract_convolve_kernel(UnityTexture2D inputTex,
                                    UnitySamplerState SS,
                                    float2 uv, float kernel[9],
                                    bool divide, float amount)
{
    float texW, texH;
    inputTex.GetDimensions(texW, texH);
    float2 dims  = float2(texW, texH);
    float2 steps = 1.0 / dims;

    float2 offsets[9];
    offsets[0] = float2(-steps.x, -steps.y);
    offsets[1] = float2( 0.0,     -steps.y);
    offsets[2] = float2( steps.x, -steps.y);
    offsets[3] = float2(-steps.x,  0.0    );
    offsets[4] = float2( 0.0,      0.0    );
    offsets[5] = float2( steps.x,  0.0    );
    offsets[6] = float2(-steps.x,  steps.y);
    offsets[7] = float2( 0.0,      steps.y);
    offsets[8] = float2( steps.x,  steps.y);

    float  kernelWeight = 0.0;
    float3 conv         = float3(0.0, 0.0, 0.0);
    float  scale        = floor(nmsg_refract_map_range(amount, 0.0, 100.0, 0.0, 20.0));

    [unroll]
    for (int i = 0; i < 9; i = i + 1)
    {
        float3 color = SAMPLE_TEXTURE2D(inputTex.tex, SS.samplerstate,
                                        uv + offsets[i] * scale).rgb;
        conv         = conv + color * kernel[i];
        kernelWeight = kernelWeight + kernel[i];
    }

    if (divide && kernelWeight != 0.0)
        conv = conv / kernelWeight;

    return clamp(conv, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

float3 nmsg_refract_derivX(UnityTexture2D inputTex, UnitySamplerState SS,
                            float2 uv, bool divide, float amount)
{
    float kernel[9];
    kernel[0] = 0.0; kernel[1] = 0.0; kernel[2] = 0.0;
    kernel[3] = 0.0; kernel[4] = 1.0; kernel[5] = -1.0;
    kernel[6] = 0.0; kernel[7] = 0.0; kernel[8] = 0.0;
    return nmsg_refract_convolve_kernel(inputTex, SS, uv, kernel, divide, amount);
}

float3 nmsg_refract_derivY(UnityTexture2D inputTex, UnitySamplerState SS,
                            float2 uv, bool divide, float amount)
{
    float kernel[9];
    kernel[0] = 0.0; kernel[1] = 0.0;  kernel[2] = 0.0;
    kernel[3] = 0.0; kernel[4] = 1.0;  kernel[5] = 0.0;
    kernel[6] = 0.0; kernel[7] = -1.0; kernel[8] = 0.0;
    return nmsg_refract_convolve_kernel(inputTex, SS, uv, kernel, divide, amount);
}

float nmsg_refract_blendOverlay(float a, float b)
{
    if (a < 0.5) return 2.0 * a * b;
    return 1.0 - 2.0 * (1.0 - a) * (1.0 - b);
}

float nmsg_refract_blendSoftLight(float base, float blend)
{
    if (blend < 0.5)
        return 2.0 * base * blend + base * base * (1.0 - 2.0 * blend);
    return sqrt(base) * (2.0 * blend - 1.0) + 2.0 * base * (1.0 - blend);
}

bool nmsg_refract_vec4_eq(float4 a, float4 b) { return all(a == b); }

float3 nmsg_refract_blend_colors(float4 color1, float4 color2,
                                  int blendMode, float mixAmt)
{
    float4 color;
    float4 middle;
    float  amt = nmsg_refract_map_range(mixAmt, 0.0, 100.0, 0.0, 1.0);

    [branch]
    if (blendMode == 0)
        middle = min(color1 + color2, float4(1.0, 1.0, 1.0, 1.0));
    else if (blendMode == 2)
        middle = nmsg_refract_vec4_eq(color2, float4(0,0,0,0))
                 ? color2
                 : max((1.0 - ((1.0 - color1) / color2)), float4(0,0,0,0));
    else if (blendMode == 3)
        middle = nmsg_refract_vec4_eq(color2, float4(1,1,1,1))
                 ? color2
                 : min(color1 / (1.0 - color2), float4(1,1,1,1));
    else if (blendMode == 4)
        middle = min(color1, color2);
    else if (blendMode == 5)
        middle = abs(color1 - color2);
    else if (blendMode == 6)
        middle = color1 + color2 - 2.0 * color1 * color2;
    else if (blendMode == 7)
        middle = nmsg_refract_vec4_eq(color2, float4(1,1,1,1))
                 ? color2
                 : min(color1 * color1 / (1.0 - color2), float4(1,1,1,1));
    else if (blendMode == 8)
        middle = float4(nmsg_refract_blendOverlay(color2.r, color1.r),
                        nmsg_refract_blendOverlay(color2.g, color1.g),
                        nmsg_refract_blendOverlay(color2.b, color1.b),
                        lerp(color1.a, color2.a, 0.5));
    else if (blendMode == 9)
        middle = max(color1, color2);
    else if (blendMode == 10)
        middle = lerp(color1, color2, 0.5);
    else if (blendMode == 11)
        middle = color1 * color2;
    else if (blendMode == 12)
        middle = float4(1,1,1,1) - abs(float4(1,1,1,1) - color1 - color2);
    else if (blendMode == 13)
        middle = float4(nmsg_refract_blendOverlay(color1.r, color2.r),
                        nmsg_refract_blendOverlay(color1.g, color2.g),
                        nmsg_refract_blendOverlay(color1.b, color2.b),
                        lerp(color1.a, color2.a, 0.5));
    else if (blendMode == 14)
        middle = min(color1, color2) - max(color1, color2) + float4(1,1,1,1);
    else if (blendMode == 15)
        middle = nmsg_refract_vec4_eq(color1, float4(1,1,1,1))
                 ? color1
                 : min(color2 * color2 / (1.0 - color1), float4(1,1,1,1));
    else if (blendMode == 16)
        middle = 1.0 - ((1.0 - color1) * (1.0 - color2));
    else if (blendMode == 17)
        middle = float4(nmsg_refract_blendSoftLight(color1.r, color2.r),
                        nmsg_refract_blendSoftLight(color1.g, color2.g),
                        nmsg_refract_blendSoftLight(color1.b, color2.b),
                        lerp(color1.a, color2.a, 0.5));
    else
        middle = max(color1 + color2 - 1.0, float4(0,0,0,0));

    if (amt == 0.5)
        color = middle;
    else if (amt < 0.5)
    {
        amt   = nmsg_refract_map_range(amt, 0.0, 0.5, 0.0, 1.0);
        color = lerp(color1, middle, amt);
    }
    else
    {
        amt   = nmsg_refract_map_range(amt, 0.5, 1.0, 0.0, 1.0);
        color = lerp(middle, color2, amt);
    }

    return color.rgb;
}

// Shader Graph Custom Function entry.
// TODO(verify): SS must be a mirror-wrap, non-sRGB (linear) sampler to match
// the runtime's default mirror/bilinear/linear path for wrap==0.
void NM_Refract_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    int               Mode,
    float             Amount,
    float             Direction,
    int               BlendMode,
    float             MixAmt,
    int               Wrap,
    out float4        Out)
{
    float texW, texH;
    InputTex.GetDimensions(texW, texH);
    float2 dims = float2(texW, texH);

    float2 uv = UV;

    float4 inputColor = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv);
    float  brightness = nmsg_refract_desaturate(inputColor.rgb) + Direction / 360.0;

    [branch]
    if (Mode == 0)
    {
        uv.x = uv.x + cos(brightness * NM_SG_REFRACT_TAU) * Amount * 0.01;
        uv.y = uv.y + sin(brightness * NM_SG_REFRACT_TAU) * Amount * 0.01;
    }
    else if (Mode == 1)
    {
        uv.y = uv.y + nmsg_refract_desaturate(
                          nmsg_refract_derivX(InputTex, SS, uv, false, Amount)) * Amount * 0.01;
        uv.x = uv.x + nmsg_refract_desaturate(
                          nmsg_refract_derivY(InputTex, SS, uv, false, Amount)) * Amount * 0.01;
    }

    [branch]
    if (Wrap == 1)
        uv = frac(uv);
    else if (Wrap == 2)
        uv = clamp(uv, float2(0.0, 0.0), float2(1.0, 1.0));
    // Wrap==0 (mirror): rely on sampler address mode.

    float4 color = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv);
    Out = float4(nmsg_refract_blend_colors(inputColor, color, BlendMode, MixAmt), color.a);
}

#endif // NM_SG_REFRACT_INCLUDED
