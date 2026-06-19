#ifndef NM_SG_LENSWARP_INCLUDED
#define NM_SG_LENSWARP_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for filter/lensWarp.
//
// Drops the effect into Shader Graph as a node. Globals from definition.js plus
// the engine animation uniforms map to named inputs:
//   displacement -> Displacement (float) [0,0.25] default 0.0625
//   antialias    -> Antialias    (float, >0.5 = true) default 1
//   time         -> Time         (float) normalized 0..1 animation time
//   speed        -> Speed        (float) oscillator speed (engine)
//
// This wraps the NON-TILING branch of the WGSL (tileOffset = (0,0)), which the
// reference documents as byte-identical to the normal-size output. Tiled
// rendering is a runtime-only concern (no fullResolution/tileOffset context in a
// Shader Graph node), so it is intentionally omitted here.
//
// Self-contained (does NOT include NMFullscreen.hlsl / NMCore.hlsl).
// Helpers mirrored VERBATIM from Shaders/Effects/filter/LensWarp.hlsl,
// name-prefixed `nmsg_` to avoid symbol clashes with the runtime include.
// pcg/prng and nm_mod are inlined to avoid the NMCore dependency.
// =============================================================================

static const float NMSG_LENSWARP_TAU = 6.28318530718;

// nm_mod inline (floor-based float mod, matches WGSL %)
float2 nmsg_lensWarp_mod(float2 a, float b) { return a - b * floor(a / b); }

// PCG 3D PRNG — verbatim from NMCore / WGSL pcg/prng.
uint3 nmsg_lensWarp_pcg(uint3 v)
{
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return v;
}

float3 nmsg_lensWarp_prng(float3 p)
{
    p.x = p.x >= 0.0 ? p.x * 2.0 : -p.x * 2.0 + 1.0;
    p.y = p.y >= 0.0 ? p.y * 2.0 : -p.y * 2.0 + 1.0;
    p.z = p.z >= 0.0 ? p.z * 2.0 : -p.z * 2.0 + 1.0;
    return float3(nmsg_lensWarp_pcg((uint3)p)) / 4294967295.0;
}

float nmsg_lensWarp_smootherstep(float x)
{
    return x * x * x * (x * (x * 6.0 - 15.0) + 10.0);
}

float nmsg_lensWarp_smoothlerp(float x, float a, float b)
{
    return a + nmsg_lensWarp_smootherstep(x) * (b - a);
}

float nmsg_lensWarp_grid(float2 st, float2 cell, float t, float spd)
{
    float angle = nmsg_lensWarp_prng(float3(cell, 1.0)).r * NMSG_LENSWARP_TAU;
    angle = angle + t * NMSG_LENSWARP_TAU * spd;
    float2 gradient = float2(cos(angle), sin(angle));
    float2 dist = st - cell;
    return dot(gradient, dist);
}

float nmsg_lensWarp_perlinNoise(float2 st_in, float2 noiseScale, float t, float spd)
{
    float2 st = st_in * noiseScale;
    float2 cell = floor(st);
    float tl = nmsg_lensWarp_grid(st, cell, t, spd);
    float tr = nmsg_lensWarp_grid(st, float2(cell.x + 1.0, cell.y), t, spd);
    float bl = nmsg_lensWarp_grid(st, float2(cell.x, cell.y + 1.0), t, spd);
    float br = nmsg_lensWarp_grid(st, cell + 1.0, t, spd);
    float upper = nmsg_lensWarp_smoothlerp(st.x - cell.x, tl, tr);
    float lower = nmsg_lensWarp_smoothlerp(st.x - cell.x, bl, br);
    float val = nmsg_lensWarp_smoothlerp(st.y - cell.y, upper, lower);
    return val * 0.5 + 0.5;
}

float2 nmsg_lensWarp_warpedUV(float2 pos, float2 frame, float2 originOffset, float disp, float t, float spd)
{
    float aspectRatio = frame.x / frame.y;
    float2 uv = (pos + originOffset) / frame;
    float2 delta = abs(uv - float2(0.5, 0.5));
    float2 scaled = float2(delta.x * aspectRatio, delta.y);
    float maxRadius = length(float2(aspectRatio * 0.5, 0.5));
    float mask = pow(clamp(length(scaled) / maxRadius, 0.0, 1.0), 5.0);
    float2 noiseCoord = uv * float2(aspectRatio, 1.0);
    float noiseX = nmsg_lensWarp_perlinNoise(noiseCoord + 42.0, float2(2.0, 2.0), t, spd);
    float noiseY = nmsg_lensWarp_perlinNoise(noiseCoord + 97.0, float2(2.0, 2.0), t, spd);
    uv.x = uv.x + (noiseX - 0.5) * disp * mask;
    uv.y = uv.y + (noiseY - 0.5) * disp * mask;
    return abs(nmsg_lensWarp_mod(nmsg_lensWarp_mod(uv + 1.0, 2.0) + 2.0, 2.0) - 1.0);
}

// NM_LensWarp_float — Shader Graph Custom Function entry.
// TODO(verify): SS must be a clamp, non-sRGB (linear) sampler state so it
// matches the runtime's bilinear/clamp/linear path (H7).
void NM_LensWarp_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             Displacement,
    float             Antialias,
    float             Time,
    float             Speed,
    out float4        Out)
{
    float texW, texH;
    InputTex.GetDimensions(texW, texH);
    float2 texSize = float2(texW, texH);

    // Non-tiling path: fragcoord = UV * texSize (WGSL pos.xy), originOffset = 0.
    float2 fragPos = UV * texSize;
    float2 uv = nmsg_lensWarp_warpedUV(fragPos, texSize, float2(0.0, 0.0), Displacement, Time, Speed);

    if (Antialias > 0.5)
    {
        float2 dx = ddx(uv);
        float2 dy = ddy(uv);
        float4 col = float4(0.0, 0.0, 0.0, 0.0);
        col += SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv + dx * -0.375 + dy * -0.125);
        col += SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv + dx *  0.125 + dy * -0.375);
        col += SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv + dx *  0.375 + dy *  0.125);
        col += SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv + dx * -0.125 + dy *  0.375);
        Out = col * 0.25;
    }
    else
    {
        Out = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv);
    }
}

#endif // NM_SG_LENSWARP_INCLUDED
