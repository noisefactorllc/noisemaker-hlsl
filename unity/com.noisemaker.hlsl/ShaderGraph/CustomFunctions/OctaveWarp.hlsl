#ifndef NM_SG_OCTAVEWARP_INCLUDED
#define NM_SG_OCTAVEWARP_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for filter/octaveWarp.
//
// Single render pass — exposed as one Custom Function node. Each global param
// from definition.js maps to a named input:
//   freq         -> Frequency    (float, frequency)     default 2
//   octaves      -> Octaves      (float, octaves)        default 3   (truncated to int)
//   displacement -> Displacement (float)                 default 0.2
//   speed        -> Speed        (float, speed)          default 1
//   seed         -> Seed         (float, seed)           default 1   (truncated to int)
//   wrap         -> Wrap         (float)                 default 0   (0/1/2)
//   antialias    -> Antialias    (float, bool as 0/1)    default 1
//   Time         -> normalized 0..1 animation time (engine global `time`)
// InputTex/SS/UV provide the source surface. UV must be the input texture's own
// 0..1 UV: the WGSL derives all coordinates from `pos.xy / textureDimensions
// (inputTex)`, so fragPos = UV * texSize is reconstructed here.
//
// Self-contained (does NOT include NMFullscreen.hlsl / NMCore.hlsl) so it is
// safe to drop into a Shader Graph Custom Function node. Helpers/core are
// mirrored VERBATIM from Shaders/Effects/filter/OctaveWarp.hlsl, name-prefixed
// `nmsg_` to avoid symbol clashes with the runtime include. The PCG is inlined
// here (it lives in NMCore for the runtime path; SG nodes must be standalone).
//
// TODO(verify): SS must be a clamp, non-sRGB (linear) sampler state so it
// matches the runtime's bilinear/clamp/linear path (H7). Antialias uses ddx/ddy
// on UV — valid only in a fragment-stage Custom Function node.
// =============================================================================

static const float NMSG_OCTAVEWARP_TAU = 6.28318530717959;

// PCG 3D PRNG (verbatim from NMCore nm_pcg / the effect's WGSL pcg).
uint3 nmsg_octaveWarp_pcg(uint3 v)
{
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return v;
}

float nmsg_octaveWarp_hash21(float2 p, int seed)
{
    uint3 v = uint3(
        (uint)(p.x >= 0.0 ? p.x * 2.0 : -p.x * 2.0 + 1.0),
        (uint)(p.y >= 0.0 ? p.y * 2.0 : -p.y * 2.0 + 1.0),
        (uint)seed
    );
    return (float)(nmsg_octaveWarp_pcg(v).x) / (float)(0xffffffffu);
}

float nmsg_octaveWarp_noise(float2 p, int seed)
{
    float2 i = floor(p);
    float2 f = frac(p);
    float2 ff = f * f * (3.0 - 2.0 * f);

    float a = nmsg_octaveWarp_hash21(i, seed);
    float b = nmsg_octaveWarp_hash21(i + float2(1.0, 0.0), seed);
    float c = nmsg_octaveWarp_hash21(i + float2(0.0, 1.0), seed);
    float d = nmsg_octaveWarp_hash21(i + float2(1.0, 1.0), seed);

    return lerp(lerp(a, b, ff.x), lerp(c, d, ff.x), ff.y);
}

float nmsg_octaveWarp_simplexNoise(float2 p, float t, float phase, float radius, int seed)
{
    float angle = t * NMSG_OCTAVEWARP_TAU + phase;
    float cx = cos(angle) * radius;
    float cy = sin(angle) * radius;
    float n = nmsg_octaveWarp_noise(p + float2(cx, cy), seed);
    n = n + nmsg_octaveWarp_noise(p * 2.0 + float2(-cy, cx) * 0.75, seed) * 0.5;
    n = n + nmsg_octaveWarp_noise(p * 4.0 + float2(cx, -cy) * 0.5, seed) * 0.25;
    return n / 1.75;
}

float nmsg_octaveWarp_wrapFloat(float value, float limit, int mode)
{
    if (limit <= 0.0)
    {
        return 0.0;
    }
    float norm = value / limit;
    if (mode == 0)
    {
        float m = (norm + 1.0) - floor((norm + 1.0) * 0.5) * 2.0;
        return abs(m - 1.0) * limit;
    }
    else if (mode == 1)
    {
        return (norm - floor(norm)) * limit;
    }
    return clamp(value, 0.0, limit);
}

float2 nmsg_octaveWarp_warpCoord(float2 fragPos, float2 texSize, float frequency,
                                 int octaves, float displacement, float t,
                                 int seed, int wrap)
{
    float width = texSize.x;
    float height = texSize.y;

    float baseFreq = 11.0 - frequency;
    float aspect = width / height;
    float2 freq = float2(baseFreq, baseFreq);
    if (aspect > 1.0)
    {
        freq.y = freq.y * aspect;
    }
    else
    {
        freq.x = freq.x / aspect;
    }

    float2 uv = fragPos / texSize;
    float2 sampleCoord = uv * texSize;

    int numOctaves = max(octaves, 1);
    float displaceBase = displacement;

    [loop]
    for (int octave = 1; octave <= 10; octave = octave + 1)
    {
        if (octave > numOctaves)
        {
            break;
        }

        float multiplier = pow(2.0, (float)octave);
        float2 freqScaled = freq * 0.5 * multiplier;

        if (freqScaled.x >= width || freqScaled.y >= height)
        {
            break;
        }

        float phase = (float)octave * 2.399;
        float radius = 0.5 / sqrt(multiplier);

        float2 noiseCoord = (sampleCoord / texSize) * freqScaled;
        float refX = nmsg_octaveWarp_simplexNoise(noiseCoord + float2(17.0, 29.0), t, phase, radius, seed) * 2.0 - 1.0;
        float refY = nmsg_octaveWarp_simplexNoise(noiseCoord + float2(23.0, 31.0), t, phase, radius, seed) * 2.0 - 1.0;

        float displaceScale = displaceBase / multiplier;
        float2 offset = float2(refX * displaceScale * width, refY * displaceScale * height);

        sampleCoord = sampleCoord + offset;
        sampleCoord = float2(
            nmsg_octaveWarp_wrapFloat(sampleCoord.x, width, wrap),
            nmsg_octaveWarp_wrapFloat(sampleCoord.y, height, wrap)
        );
    }

    float2 finalUV = float2(
        nmsg_octaveWarp_wrapFloat(sampleCoord.x, width, wrap),
        nmsg_octaveWarp_wrapFloat(sampleCoord.y, height, wrap)
    ) / texSize;

    return finalUV;
}

void NM_OctaveWarp_float(
    float          Frequency,
    float          Octaves,
    float          Displacement,
    float          Speed,
    float          Seed,
    float          Wrap,
    float          Antialias,
    float          Time,
    UnityTexture2D InputTex,
    UnitySamplerState SS,
    float2         UV,
    out float4     Out)
{
    float texW, texH;
    InputTex.GetDimensions(texW, texH);
    float2 texSize = float2(texW, texH);

    // Reconstruct WGSL fragPos: uv = pos.xy / texSize, so pos.xy = UV * texSize.
    float2 fragPos = UV * texSize;

    int   octaves = max((int)Octaves, 1);
    int   seed    = (int)Seed;
    int   wrap    = (int)Wrap;
    float t       = Time * Speed;

    float2 finalUV = nmsg_octaveWarp_warpCoord(fragPos, texSize, Frequency,
                                               octaves, Displacement, t, seed, wrap);

    if (Antialias != 0.0)
    {
        float2 dx = ddx(finalUV);
        float2 dy = ddy(finalUV);
        float4 col = float4(0.0, 0.0, 0.0, 0.0);
        col += SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, finalUV + dx * -0.375 + dy * -0.125);
        col += SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, finalUV + dx *  0.125 + dy * -0.375);
        col += SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, finalUV + dx *  0.375 + dy *  0.125);
        col += SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, finalUV + dx * -0.125 + dy *  0.375);
        Out = col * 0.25;
    }
    else
    {
        Out = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, finalUV);
    }
}

#endif // NM_SG_OCTAVEWARP_INCLUDED
