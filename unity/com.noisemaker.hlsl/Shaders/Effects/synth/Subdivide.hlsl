#ifndef NM_SUBDIVIDE_INCLUDED
#define NM_SUBDIVIDE_INCLUDED

// =============================================================================
// Subdivide.hlsl — synth/subdivide, ported PIXEL-IDENTICALLY from the canonical
// WGSL source:
//   shaders/effects/synth/subdivide/wgsl/subdivide.wgsl
//
// Recursive grid subdivision with shapes. A pixel walks down a binary/quad
// subdivision tree (up to 6 levels), then is shaded with a per-cell crossfaded
// shape + background, with an optional input-texture blend and cell outlines.
//
// KIND: filter (definition.js inputs: { inputTex: "tex" }; tex default "none").
//       The WGSL samples inputTex ONLY inside the `blend > 0` branch with a
//       GENERATED cell-relative UV (NOT fragCoord/texSize). Because that sample
//       coordinate is computed deep inside main(), the whole body lives in the
//       core fn and the input Texture2D + SamplerState are passed in as params
//       (legal at target 4.5; same bridge the UvRemap node uses).
//
// PORTING-GUIDE notes / numeric hazards:
//  * st = NM_FragCoord(i) / resolution  (WGSL: pos.xy / u.data[0].xy = the RENDER
//    resolution, NOT fullResolution, and NO tileOffset). The GLSL variant uses
//    fullResolution + tileOffset + renderScale; WGSL is canonical (golden rule 1).
//  * outlineWidth{X,Y} = outline / resolution.{x,y}  (WGSL uses resolution, and
//    does NOT multiply by renderScale; the GLSL does — WGSL is canonical).
//  * cellRand reads the `seed` global (WGSL u.data[1].y).
//  * pcg/prng ported VERBATIM inline (this WGSL inlines its own copy; /0xffffffff
//    = 4294967295.0). prng here is the SIMPLE variant (no sign-fold) — (uint3)p is
//    float->uint TRUNCATION toward zero, matching uvec3(uint(p.x),...). Copy as-is;
//    do NOT substitute NMCore's sign-fold nm_prng.
//  * texUv wrap modes use nm_mod (NEVER fmod): WGSL `(texUv + 1.0) % 2.0`,
//    `texUv % 1.0` -> nm_mod(texUv + 1.0, 2.0), nm_mod(texUv, 1.0).
//  * Shape/shade helpers (circleShape/diamondShape/squareShape/arcShape/drawShape/
//    shadeFromHash) are this effect's OWN copies — ported VERBATIM inline.
//  * i32() truncation toward zero -> (int) cast. step()/length()/min/max/mix/frac/
//    smoothstep map directly to HLSL step/length/min/max/lerp/frac/smoothstep.
//  * Input sampler: bilinear, LINEAR (non-sRGB). Wrap is applied in-shader (the
//    coord is pre-wrapped), so clamp-to-edge on the SamplerState is correct.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
// Bound by the runtime via MaterialPropertyBlock under these exact names.
int   mode;       // enum 0 binary, 1 quad        (global "mode")    default 1
int   depth;      // [1,6]                         (global "depth")   default 5
float density;    // [30,100]                      (global "density") default 75
int   seed;       // [1,100]                       (global "seed")    default 69
int   fill;       // enum 0..5                      (global "fill")    default 0
float outline;    // [0,10]                         (global "outline") default 3
float inputMix;   // [0,100]                        (global "inputMix") default 0
int   speed;      // [0,20]                         (global "speed")   default 1
int   wrap;       // enum 0 mirror,1 repeat,2 clamp (global "wrap")    default 0

// Golden ratio for staggering level transitions (WGSL: const PHI).
static const float NMS_PHI = 1.618033988749895;

// ---- pcg PRNG (verbatim; this WGSL inlines its own copy) --------------------
// uvec3 pcg(uvec3 v){ v=v*1664525u+1013904223u; v.x+=v.y*v.z; ...; v^=v>>16u; ...}
uint3 nms_pcg(uint3 v_in)
{
    uint3 v = v_in * 1664525u + 1013904223u;
    v.x = v.x + v.y * v.z;
    v.y = v.y + v.z * v.x;
    v.z = v.z + v.x * v.y;
    v = v ^ (v >> 16u);
    v.x = v.x + v.y * v.z;
    v.y = v.y + v.z * v.x;
    v.z = v.z + v.x * v.y;
    return v;
}

// prng(vec3 p): SIMPLE variant — (uint3)p is float->uint TRUNCATION toward zero
// (WGSL: vec3<u32>(u32(p.x), u32(p.y), u32(p.z))). Divisor 4294967295.0.
float3 nms_prng(float3 p)
{
    return float3(nms_pcg((uint3)p)) / 4294967295.0;
}

// cellRand: per-cell deterministic random for a (level, channel, animSeed).
// WGSL reads u.data[1].y as the seed -> our `seed` global cast to float.
float nms_cellRand(float2 cellMin, float level, float channel, float animSeed)
{
    float cx = floor(cellMin.x * 1000.0);
    float cy = floor(cellMin.y * 1000.0);
    float s = (float)seed;
    return nms_prng(float3(cx + level * 7.0, cy + level * 13.0, s + channel + animSeed * 100.0)).x;
}

// ---- Shape functions (1.0 inside, 0.0 outside) ------------------------------
float nms_circleShape(float2 centered)
{
    return step(length(centered), 0.32);
}

float nms_diamondShape(float2 centered)
{
    return step(abs(centered.x) + abs(centered.y), 0.32);
}

float nms_squareShape(float2 centered)
{
    return step(max(abs(centered.x), abs(centered.y)), 0.28);
}

float nms_arcShape(float2 centered, float halfW, float halfH, float h)
{
    int corner = (int)(h * 4.0);
    float2 origin;
    if (corner == 0) { origin = float2(-halfW, -halfH); }
    else if (corner == 1) { origin = float2(halfW, -halfH); }
    else if (corner == 2) { origin = float2(-halfW, halfH); }
    else { origin = float2(halfW, halfH); }
    float dist = length(centered - origin);
    return step(dist, 0.7) * (1.0 - step(dist, 0.5));
}

float nms_drawShape(int shapeType, float2 centered, float halfW, float halfH, float h)
{
    if (shapeType == 0) { return 1.0; }  // solid
    if (shapeType == 1) { return nms_circleShape(centered); }
    if (shapeType == 2) { return nms_diamondShape(centered); }
    if (shapeType == 3) { return nms_squareShape(centered); }
    if (shapeType == 4) { return nms_arcShape(centered, halfW, halfH, h); }
    return 1.0;
}

float nms_shadeFromHash(float h)
{
    int idx = (int)(h * 5.0);
    if (idx == 0) { return 0.15; }
    if (idx == 1) { return 0.35; }
    if (idx == 2) { return 0.55; }
    if (idx == 3) { return 0.75; }
    return 1.0;
}

// =============================================================================
// nm_subdivide — core per-pixel evaluation. Mirrors WGSL main() exactly.
//   fragCoord : NM_FragCoord(i) (top-left, +0.5)        (= WGSL pos.xy)
//   res       : the render resolution                   (= WGSL u.data[0].xy)
//   timeVal   : normalized animation time               (= WGSL u.data[2].z)
//   inputTex / ss : the input surface + sampler (sampled only when blend > 0)
// Returns RGBA.
// =============================================================================
float4 nm_subdivide(float2 fragCoord, float2 res, float timeVal,
                    Texture2D inputTex, SamplerState ss)
{
    // Use the `res` param directly — the bare name `resolution` collides with an
    // NMFullscreen.hlsl object-macro and cannot be declared as a local.
    int modeType = (int)mode;                       // WGSL i32(u.data[0].z)
    int maxDepth = (int)depth;                       // WGSL i32(u.data[0].w)
    float dens = density / 100.0;                    // WGSL u.data[1].x / 100
    int fillType = (int)fill;                        // WGSL i32(u.data[1].z)
    float outlineWidthX = outline / resolution.x;    // WGSL u.data[1].w / res.x
    float outlineWidthY = outline / resolution.y;    // WGSL u.data[1].w / res.y

    float timeV = timeVal;                           // WGSL u.data[2].z
    float spd = floor((float)speed) * 2.0;           // WGSL floor(u.data[2].w)*2

    float2 st = fragCoord / resolution;              // WGSL pos.xy / resolution

    // Subdivision loop
    float2 cellMin = float2(0.0, 0.0);
    float2 cellMax = float2(1.0, 1.0);
    bool isOutline = false;

    [loop]
    for (int level = 0; level < 6; level = level + 1)
    {
        if (level >= maxDepth) { break; }

        // Stagger each level's transition using golden ratio
        float levelTime = floor(timeV * spd + (float)level * NMS_PHI);
        float h = nms_cellRand(cellMin, (float)level, 0.0, levelTime);

        if (h < dens)
        {
            // Skip splits that would create too-narrow cells (max 5:1 aspect)
            float cellW = (cellMax.x - cellMin.x) * resolution.x;
            float cellH = (cellMax.y - cellMin.y) * resolution.y;
            bool canSplitH = min(cellW, cellH * 0.5) / max(cellW, cellH * 0.5) >= 0.2;
            bool canSplitV = min(cellW * 0.5, cellH) / max(cellW * 0.5, cellH) >= 0.2;

            if (modeType == 0)
            {
                float dir = nms_cellRand(cellMin, (float)level, 1.0, levelTime);
                int splitDir = -1;
                if (dir < 0.5)
                {
                    if (canSplitH) { splitDir = 0; }
                    else if (canSplitV) { splitDir = 1; }
                }
                else
                {
                    if (canSplitV) { splitDir = 1; }
                    else if (canSplitH) { splitDir = 0; }
                }
                if (splitDir == 0)
                {
                    float mid = (cellMin.y + cellMax.y) * 0.5;
                    if (abs(st.y - mid) < outlineWidthY) { isOutline = true; }
                    if (st.y < mid) { cellMax.y = mid; }
                    else { cellMin.y = mid; }
                }
                else if (splitDir == 1)
                {
                    float mid = (cellMin.x + cellMax.x) * 0.5;
                    if (abs(st.x - mid) < outlineWidthX) { isOutline = true; }
                    if (st.x < mid) { cellMax.x = mid; }
                    else { cellMin.x = mid; }
                }
            }
            else
            {
                if (canSplitH && canSplitV)
                {
                    float2 mid = (cellMin + cellMax) * 0.5;
                    if (abs(st.x - mid.x) < outlineWidthX || abs(st.y - mid.y) < outlineWidthY)
                    {
                        isOutline = true;
                    }
                    if (st.x < mid.x) { cellMax.x = mid.x; }
                    else { cellMin.x = mid.x; }
                    if (st.y < mid.y) { cellMax.y = mid.y; }
                    else { cellMin.y = mid.y; }
                }
            }
        }
    }

    // Cell properties
    float2 cellSize = cellMax - cellMin;
    float2 cellUv = (st - cellMin) / cellSize;

    // 1:1 aspect-corrected coords, scaled to fit shorter side
    float cellPixelW = cellSize.x * resolution.x;
    float cellPixelH = cellSize.y * resolution.y;
    float minDim = min(cellPixelW, cellPixelH);
    float2 centered = cellUv - 0.5;
    centered.x = centered.x * (cellPixelW / minDim);
    centered.y = centered.y * (cellPixelH / minDim);
    float halfW = cellPixelW / minDim * 0.5;
    float halfH = cellPixelH / minDim * 0.5;

    // Visual properties crossfade between current and next state
    float visualT = timeV * spd + NMS_PHI * 7.0;
    float curVisualTime = floor(visualT);
    float nextVisualTime = curVisualTime + 1.0;
    float visualBlend = smoothstep(0.0, 1.0, frac(visualT));

    // Crossfade shades
    float shade = lerp(
        nms_shadeFromHash(nms_cellRand(cellMin, 0.0, 2.0, curVisualTime)),
        nms_shadeFromHash(nms_cellRand(cellMin, 0.0, 2.0, nextVisualTime)),
        visualBlend);
    float bgShade = lerp(
        nms_shadeFromHash(nms_cellRand(cellMin, 0.0, 8.0, curVisualTime)),
        nms_shadeFromHash(nms_cellRand(cellMin, 0.0, 8.0, nextVisualTime)),
        visualBlend);

    // Crossfade shapes (dissolve between current and next)
    int curShapeType = fillType;
    int nextShapeType = fillType;
    if (modeType == 0)
    {
        curShapeType = 0;
        nextShapeType = 0;
    }
    else if (fillType == 5)
    {
        curShapeType = (int)(nms_cellRand(cellMin, 0.0, 3.0, curVisualTime) * 5.0);
        nextShapeType = (int)(nms_cellRand(cellMin, 0.0, 3.0, nextVisualTime) * 5.0);
    }
    float curCorner = nms_cellRand(cellMin, 0.0, 4.0, curVisualTime);
    float nextCorner = nms_cellRand(cellMin, 0.0, 4.0, nextVisualTime);
    float curMask = nms_drawShape(curShapeType, centered, halfW, halfH, curCorner);
    float nextMask = nms_drawShape(nextShapeType, centered, halfW, halfH, nextCorner);
    float shapeMask = lerp(curMask, nextMask, visualBlend);

    float color = lerp(bgShade, shade, shapeMask);
    float3 result = float3(color, color, color);

    // Input texture blend (random scale, offset, aspect-preserving)
    float blend = inputMix / 100.0;
    if (blend > 0.0)
    {
        float curTexScale = 0.3 + nms_cellRand(cellMin, 0.0, 5.0, curVisualTime) * 0.7;
        float nextTexScale = 0.3 + nms_cellRand(cellMin, 0.0, 5.0, nextVisualTime) * 0.7;
        float texScale = lerp(curTexScale, nextTexScale, visualBlend);

        float2 texUv = cellUv;
        // Correct for aspect ratio difference between cell and texture
        float cellAspect = (cellSize.x * resolution.x) / (cellSize.y * resolution.y);
        float texAspect = resolution.x / resolution.y;
        float ratio = cellAspect / texAspect;
        if (ratio > 1.0)
        {
            texUv.x = 0.5 + (texUv.x - 0.5) * ratio;
        }
        else
        {
            texUv.y = 0.5 + (texUv.y - 0.5) / ratio;
        }
        texUv = texUv * texScale;
        texUv.x = texUv.x + lerp(
            nms_cellRand(cellMin, 0.0, 6.0, curVisualTime),
            nms_cellRand(cellMin, 0.0, 6.0, nextVisualTime),
            visualBlend) * (1.0 - texScale);
        texUv.y = texUv.y + lerp(
            nms_cellRand(cellMin, 0.0, 7.0, curVisualTime),
            nms_cellRand(cellMin, 0.0, 7.0, nextVisualTime),
            visualBlend) * (1.0 - texScale);
        // Apply wrap mode
        int wrapMode = (int)wrap;
        if (wrapMode == 0)
        {
            texUv = abs(nm_mod(texUv + 1.0, float2(2.0, 2.0)) - 1.0);
        }
        else if (wrapMode == 1)
        {
            texUv = nm_mod(texUv, float2(1.0, 1.0));
        }
        else
        {
            texUv = clamp(texUv, float2(0.0, 0.0), float2(1.0, 1.0));
        }
        float3 inputColor = inputTex.Sample(ss, texUv).rgb;
        result = lerp(result, inputColor, blend);
    }

    // Outline (black, drawn after texture so it stays visible)
    if (isOutline && outline > 0.0)
    {
        result = float3(0.0, 0.0, 0.0);
    }

    return float4(result, 1.0);
}

#endif // NM_SUBDIVIDE_INCLUDED
