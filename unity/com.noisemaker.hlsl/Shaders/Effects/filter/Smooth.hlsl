#ifndef NM_EFFECT_SMOOTH_INCLUDED
#define NM_EFFECT_SMOOTH_INCLUDED

// =============================================================================
// Smooth.hlsl — filter/smooth (func: "smooth")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL sources:
//   shaders/effects/filter/smooth/wgsl/smoothEdge.wgsl  (progName "smoothEdge")
//   shaders/effects/filter/smooth/wgsl/smoothBlend.wgsl (progName "smoothBlend")
//
// Two-pass anti-aliasing. Pass 1 (smoothEdge): inputTex -> _smoothEdges. For SMAA
// (type 1) / Blur (type 2) it writes a luma edge map (R=horizontal, G=vertical
// edge flags); for MSAA (type 0) it passes the input through unchanged. Pass 2
// (smoothBlend): inputTex + edgeTex(_smoothEdges) -> outputTex, dispatching on
// smoothType to MSAA supersampling, SMAA morphological blend, or edge-selective
// Gaussian blur, then lerps original->result by `strength`.
//
// NOTE: this effect is multi-pass and ships as a runtime-rendered Texture2D (the
// C# runtime renders smoothEdge into the internal _smoothEdges target, then
// smoothBlend into the output). No Shader Graph Custom Function wrapper.
//
// PORTING-GUIDE notes / hazards handled:
//  * Ported from WGSL (top-left, canonical). No per-effect Y flip (H8).
//  * `_smoothEdges` is a '_'-prefixed INTERNAL texture: written pass 1, read pass
//    2 in the SAME frame. It is NOT self-sampling feedback and is NOT ping-ponged
//    (no repeat:). No persistent/global state textures, no MRT.
//  * WGSL `textureLoad(tex, coordI32, 0)` is an exact integer-texel fetch -> HLSL
//    `tex.Load(int3(coord, 0))` (NO sampler, NO filtering). Used everywhere except
//    the MSAA path. We mirror it exactly.
//  * WGSL `textureSampleLevel(inputTex, inputSampler, uv, 0.0)` is BILINEAR clamp
//    sampling at mip 0 -> HLSL `inputTex.Sample(sampler_inputTex, uv)` with a
//    linear-clamp SamplerState. Only the MSAA path uses this; the edge map is
//    always read via Load. Keep the load/sample distinction — they differ at
//    fractional offsets (H-class sampling hazard).
//  * `uv = pos.xy / texSize` where texSize = textureDimensions(inputTex). We use
//    NM_FragCoord(i) / float2(w,h) (input texture's OWN size, no tileOffset, no
//    fullResolution). NM_FragCoord is the @builtin(position) analog (top-left,
//    +0.5 centered).
//  * smoothBlend's `original` is read via textureSampleLevel(uv) in WGSL (the
//    GLSL uses texelFetch; at integer uv = (px+0.5)/size a linear-clamp sample
//    returns the same texel, so they agree). We follow the WGSL: Sample(uv).
//  * `i32(float)` / `int(float)` -> HLSL (int) cast (truncation toward zero).
//  * step(edge,x) -> HLSL step(edge,x) (1:1, returns x>=edge). max/abs/exp/sqrt/
//    ceil/clamp/mix(->lerp)/dot map 1:1. Loop bounds kept inclusive exactly as
//    written (`i <= 32`, `dy <= 4`, `dx <= 4`).
//  * Dynamic-bound loops (searchEdge, MSAA sample loop) marked [loop].
//  * Linear, clamp-to-edge, non-sRGB sampler (H7) — set on the SamplerState in
//    Smooth.shader. RGBA, no sRGB decode.
//  * `samples`/`searchSteps` declared as int uniforms (reference does i32(float)).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input textures + samplers ----------------------------------------------
// smoothEdge binds inputTex@1 only (WGSL binding(0) sampler is dead; only
// textureLoad is used there). smoothBlend binds inputSampler@0, inputTex@1,
// edgeTex@2. The runtime rebinds inputTex per pass; edgeTex = _smoothEdges in
// pass 2. inputTex's Sample (MSAA bilinear) needs a linear-clamp sampler;
// every other read uses .Load (sampler-free integer fetch).
Texture2D    inputTex;
SamplerState sampler_inputTex;   // linear, clamp (MSAA bilinear path only)
Texture2D    edgeTex;            // = _smoothEdges in pass 2 (read via .Load)

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
int   smoothType;   // globals.type.uniform "smoothType": 0=MSAA,1=SMAA,2=Blur
float strength;     // globals.strength.uniform, [0,1], default 1.0
float threshold;    // globals.threshold.uniform, [0,1], default 0.1
float radius;       // globals.radius.uniform, [0.5,4], default 2.0
int   samples;      // globals.samples.uniform, {2,4,8}, default 4
int   searchSteps;  // globals.searchSteps.uniform, [1,32], default 8

static const float3 LUMA_WEIGHTS = float3(0.299, 0.587, 0.114);

float luminance(float3 rgb)
{
    return dot(rgb, LUMA_WEIGHTS);
}

// =============================================================================
// Pass 1: smoothEdge  (progName "smoothEdge")
// WGSL main(): MSAA passes input through; SMAA/Blur write luma edge map.
// =============================================================================
float4 frag_smoothEdge(NMVaryings i) : SV_Target
{
    int localType = smoothType;
    float thr = threshold;

    uint w, h;
    inputTex.GetDimensions(w, h);
    int2 size = int2((int)w, (int)h);
    int2 coord = int2((int)NM_FragCoord(i).x, (int)NM_FragCoord(i).y);

    // MSAA mode: pass through input (blend pass does its own edge detection)
    if (localType == 0)
    {
        return inputTex.Load(int3(coord, 0));
    }

    // SMAA and Blur modes: luma-based edge detection
    int2 maxCoord = size - int2(1, 1);
    float L  = luminance(inputTex.Load(int3(coord, 0)).rgb);
    float Ln = luminance(inputTex.Load(int3(clamp(coord + int2(0, -1), int2(0, 0), maxCoord), 0)).rgb);
    float Ls = luminance(inputTex.Load(int3(clamp(coord + int2(0,  1), int2(0, 0), maxCoord), 0)).rgb);
    float Lw = luminance(inputTex.Load(int3(clamp(coord + int2(-1, 0), int2(0, 0), maxCoord), 0)).rgb);
    float Le = luminance(inputTex.Load(int3(clamp(coord + int2( 1, 0), int2(0, 0), maxCoord), 0)).rgb);

    float edgeH = step(thr, max(abs(L - Ln), abs(L - Ls)));
    float edgeV = step(thr, max(abs(L - Lw), abs(L - Le)));

    return float4(edgeH, edgeV, 0.0, 1.0);
}

// =============================================================================
// Pass 2: smoothBlend  (progName "smoothBlend")  — helpers ported verbatim.
// =============================================================================

// --- MSAA: rotated grid sample offsets ---

float2 sampleOffset2x(int i)
{
    if (i == 0) { return float2(-0.25, 0.25); }
    return float2(0.25, -0.25);
}

float2 sampleOffset4x(int i)
{
    if (i == 0) { return float2(-0.125, -0.375); }
    if (i == 1) { return float2( 0.375, -0.125); }
    if (i == 2) { return float2(-0.375,  0.125); }
    return float2( 0.125,  0.375);
}

float2 sampleOffset8x(int i)
{
    if (i == 0) { return float2(-0.375, -0.375); }
    if (i == 1) { return float2( 0.125, -0.375); }
    if (i == 2) { return float2(-0.125, -0.125); }
    if (i == 3) { return float2( 0.375, -0.125); }
    if (i == 4) { return float2(-0.375,  0.125); }
    if (i == 5) { return float2( 0.125,  0.125); }
    if (i == 6) { return float2(-0.125,  0.375); }
    return float2( 0.375,  0.375);
}

float2 getSampleOffset(int i, int count)
{
    if (count <= 2) { return sampleOffset2x(i); }
    if (count <= 4) { return sampleOffset4x(i); }
    return sampleOffset8x(i);
}

float4 msaaBlend(float2 uv, float2 texelSize, float thr, int sampleCount, float rad)
{
    // textureSampleLevel(...,0.0) -> bilinear clamp sample at mip 0.
    float4 center = inputTex.Sample(sampler_inputTex, uv);

    // Threshold check: skip AA for low-contrast pixels
    float L = luminance(center.rgb);
    float Ln = luminance(inputTex.Sample(sampler_inputTex, uv + float2(0.0, -texelSize.y)).rgb);
    float Ls = luminance(inputTex.Sample(sampler_inputTex, uv + float2(0.0,  texelSize.y)).rgb);
    float Lw = luminance(inputTex.Sample(sampler_inputTex, uv + float2(-texelSize.x, 0.0)).rgb);
    float Le = luminance(inputTex.Sample(sampler_inputTex, uv + float2( texelSize.x, 0.0)).rgb);

    float maxDiff = max(max(abs(L - Ln), abs(L - Ls)),
                        max(abs(L - Lw), abs(L - Le)));

    if (maxDiff < thr)
    {
        return center;
    }

    // Supersample at radius-scaled offsets (bilinear filtering via sampler)
    float4 sum = float4(0.0, 0.0, 0.0, 0.0);
    [loop]
    for (int i = 0; i < 8; i = i + 1)
    {
        if (i >= sampleCount) { break; }
        float2 offset = getSampleOffset(i, sampleCount) * rad;
        sum = sum + inputTex.Sample(sampler_inputTex, uv + offset * texelSize);
    }
    return sum / (float)sampleCount;
}

// --- SMAA: morphological edge search and blending ---

float searchEdge(int2 coord, int2 dir, int2 maxCoord, int component, int maxSteps)
{
    [loop]
    for (int i = 1; i <= 32; i = i + 1)
    {
        if (i > maxSteps) { break; }
        int2 sampleCoord = clamp(coord + dir * i, int2(0, 0), maxCoord);
        float edge;
        if (component == 0)
        {
            edge = edgeTex.Load(int3(sampleCoord, 0)).r;
        }
        else
        {
            edge = edgeTex.Load(int3(sampleCoord, 0)).g;
        }
        if (edge < 0.5)
        {
            return (float)(i - 1);
        }
    }
    return (float)maxSteps;
}

float4 smaaBlend(float2 fragPos, int localSearchSteps, float rad)
{
    uint w, h;
    inputTex.GetDimensions(w, h);
    int2 size = int2((int)w, (int)h);
    int2 coord = int2((int)fragPos.x, (int)fragPos.y);
    int2 maxCoord = size - int2(1, 1);

    float4 edges = edgeTex.Load(int3(coord, 0));
    float edgeH = edges.r;
    float edgeV = edges.g;

    float4 center = inputTex.Load(int3(coord, 0));
    if (edgeH < 0.5 && edgeV < 0.5)
    {
        return center;
    }

    float4 blended = center;

    // Horizontal edge: search left/right, blend with vertical neighbor
    if (edgeH > 0.5)
    {
        float distLeft  = searchEdge(coord, int2(-1, 0), maxCoord, 0, localSearchSteps);
        float distRight = searchEdge(coord, int2( 1, 0), maxCoord, 0, localSearchSteps);
        float edgeLength = distLeft + distRight + 1.0;

        // Stronger blend for shorter edges (more jaggy), scaled by radius
        float weight = clamp(rad * 0.5 / sqrt(edgeLength), 0.0, 0.5);

        float4 neighbor = inputTex.Load(int3(clamp(coord + int2(0, 1), int2(0, 0), maxCoord), 0));
        blended = lerp(blended, neighbor, weight);
    }

    // Vertical edge: search up/down, blend with horizontal neighbor
    if (edgeV > 0.5)
    {
        float distUp   = searchEdge(coord, int2(0, -1), maxCoord, 1, localSearchSteps);
        float distDown = searchEdge(coord, int2(0,  1), maxCoord, 1, localSearchSteps);
        float edgeLength = distUp + distDown + 1.0;

        float weight = clamp(rad * 0.5 / sqrt(edgeLength), 0.0, 0.5);

        float4 neighbor = inputTex.Load(int3(clamp(coord + int2(1, 0), int2(0, 0), maxCoord), 0));
        blended = lerp(blended, neighbor, weight);
    }

    return blended;
}

// --- Blur: edge-selective Gaussian ---

float4 edgeBlur(float2 fragPos, float rad)
{
    uint w, h;
    inputTex.GetDimensions(w, h);
    int2 size = int2((int)w, (int)h);
    int2 coord = int2((int)fragPos.x, (int)fragPos.y);
    int2 maxCoord = size - int2(1, 1);

    float4 edges = edgeTex.Load(int3(coord, 0));
    float4 center = inputTex.Load(int3(coord, 0));

    if (edges.r < 0.5 && edges.g < 0.5)
    {
        return center;
    }

    int r = (int)ceil(rad);
    float sigma = rad * 0.5;
    float sigma2 = 2.0 * sigma * sigma;

    float4 sum = center;
    float totalWeight = 1.0;

    [loop]
    for (int dy = -4; dy <= 4; dy = dy + 1)
    {
        [loop]
        for (int dx = -4; dx <= 4; dx = dx + 1)
        {
            if (dx == 0 && dy == 0) { continue; }
            if (abs(dx) > r || abs(dy) > r) { continue; }

            float d = (float)(dx * dx + dy * dy);
            float ww = exp(-d / sigma2);

            sum = sum + inputTex.Load(int3(clamp(coord + int2(dx, dy), int2(0, 0), maxCoord), 0)) * ww;
            totalWeight = totalWeight + ww;
        }
    }

    return sum / totalWeight;
}

float4 frag_smoothBlend(NMVaryings i) : SV_Target
{
    int localType = smoothType;
    float localStrength = strength;
    float localThreshold = threshold;
    int localSamples = samples;
    int localSearchSteps = searchSteps;
    float localRadius = radius;

    float2 pos = NM_FragCoord(i);

    uint w, h;
    inputTex.GetDimensions(w, h);
    float2 texSize = float2((float)w, (float)h);
    float2 uv = pos / texSize;
    float2 texelSize = 1.0 / texSize;

    float4 original = inputTex.Sample(sampler_inputTex, uv);
    float4 result;

    if (localType == 0)
    {
        result = msaaBlend(uv, texelSize, localThreshold, localSamples, localRadius);
    }
    else if (localType == 1)
    {
        result = smaaBlend(pos, localSearchSteps, localRadius);
    }
    else
    {
        result = edgeBlur(pos, localRadius);
    }

    return lerp(original, result, localStrength);
}

#endif // NM_EFFECT_SMOOTH_INCLUDED
