#ifndef NM_SG_KALEIDO_INCLUDED
#define NM_SG_KALEIDO_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for classicNoisedeck/kaleido.
//
// Single-input filter, single render pass — this wrapper IS provided.
// Each global param from definition.js maps to a named input; METRIC,
// LOOP_OFFSET, DIRECTION, KERNEL are exposed as int inputs (compile-time defines
// in the reference, branched at runtime here). Time/Resolution are exposed
// because the core references `time`, `aspectRatio` (= Resolution.x/Resolution.y)
// and uses `Resolution` for the convolve/pixellate texel size.
//
// Self-contained (does NOT include NMFullscreen.hlsl / NMCore.hlsl) so it is
// safe in a Shader Graph Custom Function node. Helpers/PCG are mirrored VERBATIM
// from Shaders/Effects/classicNoisedeck/Kaleido.hlsl, prefixed `nmsg_kl_` to
// avoid symbol clashes.
//
// PRNG note: this effect uses PLAIN (uint3)p truncation, NO sign-fold (unlike
// the shared NMCore nm_prng). Ported inline below.
//
// periodicFunction note: SIN-based (this effect's own), NOT the cos-based
// NMCore version. Mirrored inline.
//
// TODO(verify): SS must be a clamp, non-sRGB (linear) sampler state matching the
// runtime bilinear/clamp/linear path (H7). UV here is the aspect-preserving
// kaleido domain coordinate (fragCoord / Resolution.y), not the raw 0..1 UV;
// the node must feed UV = (pixel coord)/Resolution.y. Single-pass; provided.
// =============================================================================

#define NMSG_KL_PI  3.14159265359
#define NMSG_KL_TAU 6.28318530718

uint3 nmsg_kl_pcg(uint3 v)
{
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return v;
}

float3 nmsg_kl_prng(float3 p)
{
    return float3(nmsg_kl_pcg((uint3)p)) / 4294967295.0;
}

float nmsg_kl_map(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

float nmsg_kl_periodicFunction(float p)
{
    return nmsg_kl_map(sin(p * NMSG_KL_TAU), -1.0, 1.0, 0.0, 1.0);
}

int nmsg_kl_positiveModulo(int value, int modulus)
{
    if (modulus == 0) { return 0; }
    int r = value % modulus;
    if (r < 0) { r += modulus; }
    return r;
}

float3 nmsg_kl_randomFromLatticeWithOffset(float2 st, float freq, int2 offset, int seed, int wrap)
{
    float2 lattice = st * freq;
    float2 baseFloor = floor(lattice);
    int2 base = (int2)baseFloor + offset;
    float2 frac_ = lattice - baseFloor;
    int seedInt = (int)floor((float)seed);
    float seedFrac = frac((float)seed);
    float xCombined = frac_.x + seedFrac;
    int xi = base.x + seedInt + (int)floor(xCombined);
    int yi = base.y;
    if (wrap != 0)
    {
        int freqInt = (int)(freq + 0.5);
        if (freqInt > 0)
        {
            xi = nmsg_kl_positiveModulo(xi, freqInt);
            yi = nmsg_kl_positiveModulo(yi, freqInt);
        }
    }
    uint xBits = (uint)xi;
    uint yBits = (uint)yi;
    uint seedBits = asuint((float)seed);
    uint fracBits = asuint(seedFrac);
    uint3 jitter = uint3(
        (fracBits * 374761393u) ^ 0x9E3779B9u,
        (fracBits * 668265263u) ^ 0x7F4A7C15u,
        (fracBits * 2246822519u) ^ 0x94D049B4u
    );
    uint3 state = uint3(xBits, yBits, seedBits) ^ jitter;
    uint3 prngState = nmsg_kl_pcg(state);
    float denom = 4294967295.0;
    return float3((float)prngState.x / denom, (float)prngState.y / denom, (float)prngState.z / denom);
}

float nmsg_kl_constant(float2 st, float freq, int seed, int wrap, float speed, float time)
{
    float3 randTime = nmsg_kl_randomFromLatticeWithOffset(st, freq, int2(40, 0), seed, wrap);
    float scaledTime = nmsg_kl_periodicFunction(randTime.x - time) * nmsg_kl_map(abs(speed), 0.0, 100.0, 0.0, 0.333);
    float3 rand = nmsg_kl_randomFromLatticeWithOffset(st, freq, int2(0, 0), seed, wrap);
    return nmsg_kl_periodicFunction(rand.y - scaledTime);
}

float nmsg_kl_quadratic3(float p0, float p1, float p2, float t)
{
    float t2 = t * t;
    float B0 = 0.5 * (1.0 - t) * (1.0 - t);
    float B1 = 0.5 * (-2.0 * t2 + 2.0 * t + 1.0);
    float B2 = 0.5 * t2;
    return p0 * B0 + p1 * B1 + p2 * B2;
}

float nmsg_kl_catmullRom3(float p0, float p1, float p2, float t)
{
    float t2 = t * t;
    float t3 = t2 * t;
    return p1 + 0.5 * t * (p2 - p0) + 0.5 * t2 * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p0) + 0.5 * t3 * (-p0 + 3.0 * p1 - 3.0 * p2 + p0);
}

float nmsg_kl_quadratic3x3Value(float2 st, float freq, int seed, int wrap, float speed, float time)
{
    float2 f = frac(st * freq);
    float nd = 1.0 / freq;
    float v00 = nmsg_kl_constant(st + float2(-nd, -nd), freq, seed, wrap, speed, time);
    float v10 = nmsg_kl_constant(st + float2(0.0, -nd), freq, seed, wrap, speed, time);
    float v20 = nmsg_kl_constant(st + float2(nd, -nd), freq, seed, wrap, speed, time);
    float v01 = nmsg_kl_constant(st + float2(-nd, 0.0), freq, seed, wrap, speed, time);
    float v11 = nmsg_kl_constant(st, freq, seed, wrap, speed, time);
    float v21 = nmsg_kl_constant(st + float2(nd, 0.0), freq, seed, wrap, speed, time);
    float v02 = nmsg_kl_constant(st + float2(-nd, nd), freq, seed, wrap, speed, time);
    float v12 = nmsg_kl_constant(st + float2(0.0, nd), freq, seed, wrap, speed, time);
    float v22 = nmsg_kl_constant(st + float2(nd, nd), freq, seed, wrap, speed, time);
    float y0 = nmsg_kl_quadratic3(v00, v10, v20, f.x);
    float y1 = nmsg_kl_quadratic3(v01, v11, v21, f.x);
    float y2 = nmsg_kl_quadratic3(v02, v12, v22, f.x);
    return nmsg_kl_quadratic3(y0, y1, y2, f.y);
}

float nmsg_kl_catmullRom3x3Value(float2 st, float freq, int seed, int wrap, float speed, float time)
{
    float2 f = frac(st * freq);
    float nd = 1.0 / freq;
    float v00 = nmsg_kl_constant(st + float2(-nd, -nd), freq, seed, wrap, speed, time);
    float v10 = nmsg_kl_constant(st + float2(0.0, -nd), freq, seed, wrap, speed, time);
    float v20 = nmsg_kl_constant(st + float2(nd, -nd), freq, seed, wrap, speed, time);
    float v01 = nmsg_kl_constant(st + float2(-nd, 0.0), freq, seed, wrap, speed, time);
    float v11 = nmsg_kl_constant(st, freq, seed, wrap, speed, time);
    float v21 = nmsg_kl_constant(st + float2(nd, 0.0), freq, seed, wrap, speed, time);
    float v02 = nmsg_kl_constant(st + float2(-nd, nd), freq, seed, wrap, speed, time);
    float v12 = nmsg_kl_constant(st + float2(0.0, nd), freq, seed, wrap, speed, time);
    float v22 = nmsg_kl_constant(st + float2(nd, nd), freq, seed, wrap, speed, time);
    float y0 = nmsg_kl_catmullRom3(v00, v10, v20, f.x);
    float y1 = nmsg_kl_catmullRom3(v01, v11, v21, f.x);
    float y2 = nmsg_kl_catmullRom3(v02, v12, v22, f.x);
    return nmsg_kl_catmullRom3(y0, y1, y2, f.y);
}

float nmsg_kl_blendBicubic(float p0, float p1, float p2, float p3, float t)
{
    float t2 = t * t;
    float t3 = t2 * t;
    float B0 = (1.0 - t) * (1.0 - t) * (1.0 - t) / 6.0;
    float B1 = (3.0 * t3 - 6.0 * t2 + 4.0) / 6.0;
    float B2 = (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) / 6.0;
    float B3 = t3 / 6.0;
    return p0 * B0 + p1 * B1 + p2 * B2 + p3 * B3;
}

float nmsg_kl_catmullRom4(float p0, float p1, float p2, float p3, float t)
{
    return p1 + 0.5 * t * (p2 - p0 + t * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 + t * (3.0 * (p1 - p2) + p3 - p0)));
}

float nmsg_kl_blendLinearOrCosine(float a, float b, float amount, int interp)
{
    if (interp == 1) { return lerp(a, b, amount); }
    return lerp(a, b, smoothstep(0.0, 1.0, amount));
}

float3 nmsg_kl_mod289_3(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float2 nmsg_kl_mod289_2(float2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float3 nmsg_kl_permute3(float3 x) { return nmsg_kl_mod289_3(((x * 34.0) + 1.0) * x); }

float nmsg_kl_simplexValue(float2 v)
{
    float4 C = float4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
    float2 i = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12 = float4(x12.xy - i1, x12.zw);
    i = nmsg_kl_mod289_2(i);
    float3 p = nmsg_kl_permute3(nmsg_kl_permute3(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));
    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), float3(0.0, 0.0, 0.0));
    m = m * m;
    m = m * m;
    float3 x = 2.0 * frac(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.y = a0.y * x12.x + h.y * x12.y;
    g.z = a0.z * x12.z + h.z * x12.w;
    return 130.0 * dot(m, g);
}

float nmsg_kl_sineNoise(float2 st_in, float freq, float aspect, int seed, int wrap, float speed, float time)
{
    float2 st = st_in - float2(0.5 * aspect, 0.5);
    float3 rand = nmsg_kl_randomFromLatticeWithOffset(st, freq, int2(20, 0), seed, wrap);
    float waveFreq = rand.x * 50.0;
    float waveAmp = rand.y;
    float wavePhase = rand.z * NMSG_KL_TAU;
    float3 randTime = nmsg_kl_randomFromLatticeWithOffset(st, freq, int2(40, 0), seed, wrap);
    float phaseOffset = nmsg_kl_periodicFunction(randTime.x - time) * nmsg_kl_map(abs(speed), 0.0, 100.0, 0.0, 0.333);
    float dist = length(st);
    float sineWave = sin(dist * waveFreq + wavePhase - phaseOffset) * waveAmp;
    return nmsg_kl_periodicFunction(sineWave);
}

float nmsg_kl_bicubicValue(float2 st, float freq, int seed, int wrap, float speed, float time)
{
    float ndX = 1.0 / freq;
    float ndY = 1.0 / freq;
    float u0 = st.x - ndX; float u1 = st.x; float u2 = st.x + ndX; float u3 = st.x + ndX + ndX;
    float v0 = st.y - ndY; float v1 = st.y; float v2 = st.y + ndY; float v3 = st.y + ndY + ndY;
    float x0y0 = nmsg_kl_constant(float2(u0, v0), freq, seed, wrap, speed, time); float x0y1 = nmsg_kl_constant(float2(u0, v1), freq, seed, wrap, speed, time);
    float x0y2 = nmsg_kl_constant(float2(u0, v2), freq, seed, wrap, speed, time); float x0y3 = nmsg_kl_constant(float2(u0, v3), freq, seed, wrap, speed, time);
    float x1y0 = nmsg_kl_constant(float2(u1, v0), freq, seed, wrap, speed, time); float x1y1 = nmsg_kl_constant(st, freq, seed, wrap, speed, time);
    float x1y2 = nmsg_kl_constant(float2(u1, v2), freq, seed, wrap, speed, time); float x1y3 = nmsg_kl_constant(float2(u1, v3), freq, seed, wrap, speed, time);
    float x2y0 = nmsg_kl_constant(float2(u2, v0), freq, seed, wrap, speed, time); float x2y1 = nmsg_kl_constant(float2(u2, v1), freq, seed, wrap, speed, time);
    float x2y2 = nmsg_kl_constant(float2(u2, v2), freq, seed, wrap, speed, time); float x2y3 = nmsg_kl_constant(float2(u2, v3), freq, seed, wrap, speed, time);
    float x3y0 = nmsg_kl_constant(float2(u3, v0), freq, seed, wrap, speed, time); float x3y1 = nmsg_kl_constant(float2(u3, v1), freq, seed, wrap, speed, time);
    float x3y2 = nmsg_kl_constant(float2(u3, v2), freq, seed, wrap, speed, time); float x3y3 = nmsg_kl_constant(float2(u3, v3), freq, seed, wrap, speed, time);
    float2 uv = st * freq;
    float y0 = nmsg_kl_blendBicubic(x0y0, x1y0, x2y0, x3y0, frac(uv.x));
    float y1 = nmsg_kl_blendBicubic(x0y1, x1y1, x2y1, x3y1, frac(uv.x));
    float y2 = nmsg_kl_blendBicubic(x0y2, x1y2, x2y2, x3y2, frac(uv.x));
    float y3 = nmsg_kl_blendBicubic(x0y3, x1y3, x2y3, x3y3, frac(uv.x));
    return nmsg_kl_blendBicubic(y0, y1, y2, y3, frac(uv.y));
}

float nmsg_kl_catmullRom4x4Value(float2 st, float freq, int seed, int wrap, float speed, float time)
{
    float ndX = 1.0 / freq; float ndY = 1.0 / freq;
    float u0 = st.x - ndX; float u1 = st.x; float u2 = st.x + ndX; float u3 = st.x + ndX + ndX;
    float v0 = st.y - ndY; float v1 = st.y; float v2 = st.y + ndY; float v3 = st.y + ndY + ndY;
    float x0y0 = nmsg_kl_constant(float2(u0, v0), freq, seed, wrap, speed, time); float x0y1 = nmsg_kl_constant(float2(u0, v1), freq, seed, wrap, speed, time);
    float x0y2 = nmsg_kl_constant(float2(u0, v2), freq, seed, wrap, speed, time); float x0y3 = nmsg_kl_constant(float2(u0, v3), freq, seed, wrap, speed, time);
    float x1y0 = nmsg_kl_constant(float2(u1, v0), freq, seed, wrap, speed, time); float x1y1 = nmsg_kl_constant(st, freq, seed, wrap, speed, time);
    float x1y2 = nmsg_kl_constant(float2(u1, v2), freq, seed, wrap, speed, time); float x1y3 = nmsg_kl_constant(float2(u1, v3), freq, seed, wrap, speed, time);
    float x2y0 = nmsg_kl_constant(float2(u2, v0), freq, seed, wrap, speed, time); float x2y1 = nmsg_kl_constant(float2(u2, v1), freq, seed, wrap, speed, time);
    float x2y2 = nmsg_kl_constant(float2(u2, v2), freq, seed, wrap, speed, time); float x2y3 = nmsg_kl_constant(float2(u2, v3), freq, seed, wrap, speed, time);
    float x3y0 = nmsg_kl_constant(float2(u3, v0), freq, seed, wrap, speed, time); float x3y1 = nmsg_kl_constant(float2(u3, v1), freq, seed, wrap, speed, time);
    float x3y2 = nmsg_kl_constant(float2(u3, v2), freq, seed, wrap, speed, time); float x3y3 = nmsg_kl_constant(float2(u3, v3), freq, seed, wrap, speed, time);
    float2 uv = st * freq;
    float y0 = nmsg_kl_catmullRom4(x0y0, x1y0, x2y0, x3y0, frac(uv.x));
    float y1 = nmsg_kl_catmullRom4(x0y1, x1y1, x2y1, x3y1, frac(uv.x));
    float y2 = nmsg_kl_catmullRom4(x0y2, x1y2, x2y2, x3y2, frac(uv.x));
    float y3 = nmsg_kl_catmullRom4(x0y3, x1y3, x2y3, x3y3, frac(uv.x));
    return nmsg_kl_catmullRom4(y0, y1, y2, y3, frac(uv.y));
}

float nmsg_kl_value(float2 st_in, float freq, int interp, float aspect, int seed, int wrap, float speed, float time)
{
    float2 st = st_in - float2(0.5 * aspect, 0.5);
    if (interp == 3) { return nmsg_kl_catmullRom3x3Value(st, freq, seed, wrap, speed, time); }
    else if (interp == 4) { return nmsg_kl_catmullRom4x4Value(st, freq, seed, wrap, speed, time); }
    else if (interp == 5) { return nmsg_kl_quadratic3x3Value(st, freq, seed, wrap, speed, time); }
    else if (interp == 6) { return nmsg_kl_bicubicValue(st, freq, seed, wrap, speed, time); }
    else if (interp == 10) { return nmsg_kl_periodicFunction(nmsg_kl_simplexValue(st * freq + float2((float)seed, (float)seed))); }
    else if (interp == 11) { return nmsg_kl_sineNoise(st, freq, aspect, seed, wrap, speed, time); }
    float x1y1 = nmsg_kl_constant(st, freq, seed, wrap, speed, time);
    if (interp == 0) { return x1y1; }
    float ndX = 1.0 / freq; float ndY = 1.0 / freq;
    float x1y2 = nmsg_kl_constant(float2(st.x, st.y + ndY), freq, seed, wrap, speed, time);
    float x2y1 = nmsg_kl_constant(float2(st.x + ndX, st.y), freq, seed, wrap, speed, time);
    float x2y2 = nmsg_kl_constant(float2(st.x + ndX, st.y + ndY), freq, seed, wrap, speed, time);
    float2 uv = st * freq;
    float a = nmsg_kl_blendLinearOrCosine(x1y1, x2y1, frac(uv.x), interp);
    float b = nmsg_kl_blendLinearOrCosine(x1y2, x2y2, frac(uv.x), interp);
    return nmsg_kl_blendLinearOrCosine(a, b, frac(uv.y), interp);
}

float3 nmsg_kl_hsv2rgb(float3 hsv)
{
    float h = frac(hsv.x); float s = hsv.y; float v = hsv.z;
    float c = v * s; float x = c * (1.0 - abs(frac(h * 6.0) * 2.0 - 1.0)); float m = v - c;
    float3 rgb;
    if (h < 1.0 / 6.0) { rgb = float3(c, x, 0.0); }
    else if (h < 2.0 / 6.0) { rgb = float3(x, c, 0.0); }
    else if (h < 3.0 / 6.0) { rgb = float3(0.0, c, x); }
    else if (h < 4.0 / 6.0) { rgb = float3(0.0, x, c); }
    else if (h < 5.0 / 6.0) { rgb = float3(x, 0.0, c); }
    else { rgb = float3(c, 0.0, x); }
    return rgb + float3(m, m, m);
}

float3 nmsg_kl_rgb2hsv(float3 rgb)
{
    float maxC = max(rgb.r, max(rgb.g, rgb.b));
    float minC = min(rgb.r, min(rgb.g, rgb.b));
    float delta = maxC - minC;
    float h = 0.0;
    if (delta != 0.0)
    {
        if (maxC == rgb.r) { h = ((rgb.g - rgb.b) / delta % 6.0) / 6.0; }
        else if (maxC == rgb.g) { h = ((rgb.b - rgb.r) / delta + 2.0) / 6.0; }
        else { h = ((rgb.r - rgb.g) / delta + 4.0) / 6.0; }
    }
    float s = (maxC != 0.0) ? (delta / maxC) : 0.0;
    return float3(h, s, maxC);
}

float3 nmsg_kl_convolve(UnityTexture2D inputTex, UnitySamplerState ss, float2 uv, float kernel[9], bool divide, float2 res, float effectWidth)
{
    float2 steps = 1.0 / res;
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
        float3 color = SAMPLE_TEXTURE2D(inputTex.tex, ss.samplerstate, uv + offsets[i] * effectWidth).rgb;
        conv += color * kernel[i];
        kernelWeight += kernel[i];
    }
    if (divide && kernelWeight != 0.0) { conv /= kernelWeight; }
    return clamp(conv, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
}

float3 nmsg_kl_derivatives(UnityTexture2D inputTex, UnitySamplerState ss, float3 color, float2 uv, bool divide, float2 res, float ew)
{
    float deriv_x[9] = { 0.0, 0.0, 0.0, 0.0, 1.0, -1.0, 0.0, 0.0, 0.0 };
    float deriv_y[9] = { 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, -1.0, 0.0 };
    return color * distance(nmsg_kl_convolve(inputTex, ss, uv, deriv_x, divide, res, ew), nmsg_kl_convolve(inputTex, ss, uv, deriv_y, divide, res, ew));
}

float3 nmsg_kl_sobel(UnityTexture2D inputTex, UnitySamplerState ss, float3 color, float2 uv, float2 res, float ew)
{
    float sobel_x[9] = { 1.0, 0.0, -1.0, 2.0, 0.0, -2.0, 1.0, 0.0, -1.0 };
    float sobel_y[9] = { 1.0, 2.0, 1.0, 0.0, 0.0, 0.0, -1.0, -2.0, -1.0 };
    return color * distance(nmsg_kl_convolve(inputTex, ss, uv, sobel_x, false, res, ew), nmsg_kl_convolve(inputTex, ss, uv, sobel_y, false, res, ew));
}

float3 nmsg_kl_outline(UnityTexture2D inputTex, UnitySamplerState ss, float3 color, float2 uv, float2 res, float ew)
{
    float sobel_x[9] = { 1.0, 0.0, -1.0, 2.0, 0.0, -2.0, 1.0, 0.0, -1.0 };
    float sobel_y[9] = { 1.0, 2.0, 1.0, 0.0, 0.0, 0.0, -1.0, -2.0, -1.0 };
    return max(color - distance(nmsg_kl_convolve(inputTex, ss, uv, sobel_x, false, res, ew), nmsg_kl_convolve(inputTex, ss, uv, sobel_y, false, res, ew)), float3(0.0, 0.0, 0.0));
}

float3 nmsg_kl_shadow(UnityTexture2D inputTex, UnitySamplerState ss, float3 color_in, float2 uv, float2 res, float ew)
{
    float sobel_x[9] = { 1.0, 0.0, -1.0, 2.0, 0.0, -2.0, 1.0, 0.0, -1.0 };
    float sobel_y[9] = { 1.0, 2.0, 1.0, 0.0, 0.0, 0.0, -1.0, -2.0, -1.0 };
    float3 color = nmsg_kl_rgb2hsv(color_in);
    float shade_dist = distance(nmsg_kl_convolve(inputTex, ss, uv, sobel_x, false, res, ew), nmsg_kl_convolve(inputTex, ss, uv, sobel_y, false, res, ew));
    float highlight = shade_dist * shade_dist;
    float shade = (1.0 - ((1.0 - color.z) * (1.0 - highlight))) * shade_dist;
    color = float3(color.x, color.y, lerp(color.z, shade, 0.75));
    return nmsg_kl_hsv2rgb(color);
}

float3 nmsg_kl_convolutionKernel(UnityTexture2D inputTex, UnitySamplerState ss, float3 color, float2 uv, int KERNEL, float2 res, float ew)
{
    float emboss[9]  = { -2.0, -1.0, 0.0, -1.0, 1.0, 1.0, 0.0, 1.0, 2.0 };
    float sharpen[9] = { -1.0, 0.0, -1.0, 0.0, 5.0, 0.0, -1.0, 0.0, -1.0 };
    float blur[9]    = { 1.0, 2.0, 1.0, 2.0, 4.0, 2.0, 1.0, 2.0, 1.0 };
    float edge2[9]   = { -1.0, 0.0, -1.0, 0.0, 4.0, 0.0, -1.0, 0.0, -1.0 };
    [branch]
    if (KERNEL == 1) { return nmsg_kl_convolve(inputTex, ss, uv, blur, true, res, ew); }
    else if (KERNEL == 2) { return nmsg_kl_derivatives(inputTex, ss, color, uv, true, res, ew); }
    else if (KERNEL == 120) { return clamp(nmsg_kl_derivatives(inputTex, ss, color, uv, false, res, ew) * 2.5, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0)); }
    else if (KERNEL == 3) { return color * nmsg_kl_convolve(inputTex, ss, uv, edge2, true, res, ew); }
    else if (KERNEL == 4) { return nmsg_kl_convolve(inputTex, ss, uv, emboss, false, res, ew); }
    else if (KERNEL == 5) { return nmsg_kl_outline(inputTex, ss, color, uv, res, ew); }
    else if (KERNEL == 6) { return nmsg_kl_shadow(inputTex, ss, color, uv, res, ew); }
    else if (KERNEL == 7) { return nmsg_kl_convolve(inputTex, ss, uv, sharpen, false, res, ew); }
    else if (KERNEL == 8) { return nmsg_kl_sobel(inputTex, ss, color, uv, res, ew); }
    return color;
}

float nmsg_kl_shape(float2 st_in, int sides, float blend, float aspect)
{
    if (sides < 2) { return distance(st_in, float2(0.5, 0.5)); }
    float2 st = float2(st_in.x, 1.0 - st_in.y) * 2.0 - float2(aspect, 1.0);
    float a = atan2(st.x, st.y) + NMSG_KL_PI;
    float r = NMSG_KL_TAU / (float)sides;
    return cos(floor(0.5 + a / r) * r - a) * length(st) * blend;
}

float3 nmsg_kl_posterize(float3 color, float levIn)
{
    float lev = levIn;
    if (lev == 0.0) { return color; }
    else if (lev == 1.0) { lev = 2.0; }
    float3 c = clamp(color, float3(0.0, 0.0, 0.0), float3(0.99, 0.99, 0.99));
    return (floor(c * lev) + 0.5) / lev;
}

float3 nmsg_kl_pixellate(UnityTexture2D inputTex, UnitySamplerState ss, float2 uv, float size, float2 res)
{
    float dx = size / res.x;
    float dy = size / res.y;
    return SAMPLE_TEXTURE2D(inputTex.tex, ss.samplerstate, float2(dx * floor(uv.x / dx), dy * floor(uv.y / dy))).rgb;
}

float nmsg_kl_circles(float2 st, float freq, float aspect)
{
    return length(st - float2(0.5 * aspect, 0.5)) * freq;
}

float nmsg_kl_rings(float2 st, float freq, float aspect)
{
    return cos(length(st - float2(0.5 * aspect, 0.5)) * NMSG_KL_PI * freq);
}

float nmsg_kl_diamonds(float2 st, float freq, float aspect)
{
    float2 s = st; s.x -= 0.5 * aspect; s *= freq;
    return sin(s.x * NMSG_KL_PI) + sin(s.y * NMSG_KL_PI);
}

float nmsg_kl_getMetric(float2 st, int METRIC, float aspect)
{
    float2 diff = float2(0.5 * aspect, 0.5) - st;
    if (METRIC == 0) { return length(st - float2(0.5 * aspect, 0.5)); }
    else if (METRIC == 1) { return abs(diff.x) + abs(diff.y); }
    else if (METRIC == 2) { return max(max(abs(diff.x) - diff.y * -0.5, -1.0 * diff.y), max(abs(diff.x) - diff.y * 0.5, 1.0 * diff.y)); }
    else if (METRIC == 3) { return max((abs(diff.x) + abs(diff.y)) / sqrt(2.0), max(abs(diff.x), abs(diff.y))); }
    else if (METRIC == 4) { return max(abs(diff.x), abs(diff.y)); }
    else if (METRIC == 5) { return max(abs(diff.x) - diff.y * -0.5, -1.0 * diff.y); }
    return 1.0;
}

float nmsg_kl_offset(float2 st, float freq, int LOOP_OFFSET, float aspect, int seed, int wrap, float speed, float time)
{
    if (LOOP_OFFSET == 10) { return nmsg_kl_circles(st, freq, aspect); }
    else if (LOOP_OFFSET == 20) { return nmsg_kl_shape(st, 3, freq * 0.5, aspect); }
    else if (LOOP_OFFSET == 30) { return (abs(st.x - 0.5 * aspect) + abs(st.y - 0.5)) * freq * 0.5; }
    else if (LOOP_OFFSET == 40) { return nmsg_kl_shape(st, 4, freq * 0.5, aspect); }
    else if (LOOP_OFFSET == 50) { return nmsg_kl_shape(st, 5, freq * 0.5, aspect); }
    else if (LOOP_OFFSET == 60) { return nmsg_kl_shape(st, 6, freq * 0.5, aspect); }
    else if (LOOP_OFFSET == 70) { return nmsg_kl_shape(st, 7, freq * 0.5, aspect); }
    else if (LOOP_OFFSET == 80) { return nmsg_kl_shape(st, 8, freq * 0.5, aspect); }
    else if (LOOP_OFFSET == 90) { return nmsg_kl_shape(st, 9, freq * 0.5, aspect); }
    else if (LOOP_OFFSET == 100) { return nmsg_kl_shape(st, 10, freq * 0.5, aspect); }
    else if (LOOP_OFFSET == 110) { return nmsg_kl_shape(st, 11, freq * 0.5, aspect); }
    else if (LOOP_OFFSET == 120) { return nmsg_kl_shape(st, 12, freq * 0.5, aspect); }
    else if (LOOP_OFFSET == 200) { return st.x * freq * 0.5; }
    else if (LOOP_OFFSET == 210) { return st.y * freq * 0.5; }
    else if (LOOP_OFFSET == 300) { return 1.0 - nmsg_kl_value(st, freq, 0, aspect, seed, wrap, speed, time); }
    else if (LOOP_OFFSET == 310) { return 1.0 - nmsg_kl_value(st, freq, 1, aspect, seed, wrap, speed, time); }
    else if (LOOP_OFFSET == 320) { return 1.0 - nmsg_kl_value(st, freq, 2, aspect, seed, wrap, speed, time); }
    else if (LOOP_OFFSET == 330) { return 1.0 - nmsg_kl_value(st, freq, 3, aspect, seed, wrap, speed, time); }
    else if (LOOP_OFFSET == 340) { return 1.0 - nmsg_kl_value(st, freq, 4, aspect, seed, wrap, speed, time); }
    else if (LOOP_OFFSET == 350) { return 1.0 - nmsg_kl_value(st, freq, 5, aspect, seed, wrap, speed, time); }
    else if (LOOP_OFFSET == 360) { return 1.0 - nmsg_kl_value(st, freq, 6, aspect, seed, wrap, speed, time); }
    else if (LOOP_OFFSET == 370) { return 1.0 - nmsg_kl_value(st, freq, 10, aspect, seed, wrap, speed, time); }
    else if (LOOP_OFFSET == 380) { return 1.0 - nmsg_kl_value(st, freq, 11, aspect, seed, wrap, speed, time); }
    else if (LOOP_OFFSET == 400) { return 1.0 - nmsg_kl_rings(st, freq, aspect); }
    else if (LOOP_OFFSET == 410) { return 1.0 - nmsg_kl_diamonds(st, freq, aspect); }
    return 0.0;
}

float2 nmsg_kl_kaleidoscope(float2 st_in, float sides, float blendy, int METRIC, int DIRECTION, float aspect, float time)
{
    float r = nmsg_kl_getMetric(st_in, METRIC, aspect) + blendy;
    float2 st = st_in - float2(0.5 * aspect, 0.5);
    float a = atan2(st.y, st.x);
    float dir = time;
    if (DIRECTION == 1) { dir *= -1.0; }
    else if (DIRECTION == 2) { dir = 1.0; }
    // glslMod(x,y) = x - y*floor(x/y) (sign of divisor). NEVER fmod (H6).
    float mArg = a + radians(90.0) - radians(360.0 / sides * dir);
    float mY = NMSG_KL_TAU / sides;
    float ma = mArg - mY * floor(mArg / mY);
    ma = abs(ma - NMSG_KL_PI / sides);
    st = r * float2(cos(ma), sin(ma));
    return frac(st);
}

// Shader Graph Custom Function entry.
//   UV         : aspect-preserving domain coord = (pixel coord)/Resolution.y
//   Resolution : per-tile render target size (texel-size source for convolve)
//   InputTex/SS: source surface (bilinear, clamp, linear/non-sRGB)
void NM_Kaleido_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float2            Resolution,
    float             Time,
    float             Sides,        // kaleido
    int               Metric,       // METRIC
    int               LoopOffset,   // LOOP_OFFSET
    float             LoopScale,
    float             Speed,
    int               Seed,
    int               Wrap,
    int               Direction,    // DIRECTION
    int               Kernel,       // KERNEL
    float             EffectWidth,
    out float4        Out)
{
    float aspect = Resolution.x / Resolution.y;

    float2 uv = UV;
    float lf = nmsg_kl_map(LoopScale, 1.0, 100.0, 6.0, 1.0);
    if (Wrap != 0) { lf = floor(lf); }

    float t = Time + nmsg_kl_offset(uv, lf, LoopOffset, aspect, Seed, Wrap, Speed, Time) * Speed * 0.01;
    float blendy = nmsg_kl_periodicFunction(t) * nmsg_kl_map(abs(Speed), 0.0, 100.0, 0.0, 2.0);

    uv = nmsg_kl_kaleidoscope(uv, Sides, blendy, Metric, Direction, aspect, Time);
    float4 color = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv);

    [branch]
    if (EffectWidth != 0.0 && Kernel != 0)
    {
        if (Kernel == 10) { color = float4(nmsg_kl_pixellate(InputTex, SS, uv, EffectWidth * 4.0, Resolution), color.a); }
        else if (Kernel == 110) { color = float4(nmsg_kl_posterize(color.rgb, floor(nmsg_kl_map(EffectWidth, 0.0, 10.0, 0.0, 20.0))), color.a); }
        else { color = float4(nmsg_kl_convolutionKernel(InputTex, SS, color.rgb, uv, Kernel, Resolution, EffectWidth), color.a); }
    }

    Out = color;
}

#endif // NM_SG_KALEIDO_INCLUDED
