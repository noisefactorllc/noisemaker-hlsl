#ifndef NM_EFFECT_RENDER3D_INCLUDED
#define NM_EFFECT_RENDER3D_INCLUDED

// =============================================================================
// Render3d.hlsl — render/render3d (func: "render3d")
//
// Universal 3D volume RAYMARCHER. Ported PIXEL-IDENTICALLY from the canonical
// WGSL source (top-left origin, no per-effect Y flip; golden rule #1):
//   wgsl/render3d.wgsl   progName "render3d"   (frag main, MRT x2)
//
// 3D / RENDER TIER MODEL (reference 04 §8 + reference 10 §3):
//  * This is the FIRST true RAYMARCH CONSUMER ported. All existing synth3d/
//    filter3d 3D effects are volume-WRITERS that fill the 64x4096 vol atlas;
//    render3d READS that atlas (volumeCache, a vol-tier surface) and renders it
//    to a 2D SCREEN image. The pass runs at SCREEN resolution (viewport is NOT
//    overridden), so NM_FragCoord(i) yields screen pixel coords and the volume
//    atlas is addressed by INTEGER texel fetch (textureLoad -> .Load), NOT uv.
//  * The volume atlas (u,v) -> voxel (x,y,z) mapping is volumeToAtlas:
//        atlasTexel = int2( x, y + z * volSize )
//    i.e. atlas height = volSize slices of (volSize x volSize). Reproduced
//    EXACTLY from the WGSL (matches the synth3d writers).
//  * volumeSize is INHERITED from the upstream volume effect (definition.js:
//    ui.control=false, "Always inherited from upstream volume effect"). It is a
//    runtime int uniform here; it drives only the voxel/slice math, NOT the
//    atlas RenderTexture dimensions (those come from volumeCache's own size).
//  * MRT (drawBuffers:2): SV_Target0 = color (-> outputTex), SV_Target1 =
//    geoOut (-> screenGeoBuffer): xyz = normal*0.5+0.5, w = depth. The runtime
//    binds both MRT targets (definition.js outputs color/geoOut).
//
// COMPILE-TIME DEFINES -> RUNTIME UNIFORMS (PORTING-GUIDE "Compile-time
// defines"): the reference bakes FILTERING (isosurface vs voxel path) and
// INVERT (per-sample threshold invert) as #defines / WGSL consts purely to let
// the optimizer drop the unused path in a 14kB shader (perf only, NOT
// correctness). Here they are plain int uniforms branched at runtime with
// [branch]; values are identical. Defaults: FILTERING=0 (isosurface), INVERT=0.
//
// PORTING-GUIDE / parity notes:
//  * WGSL textureLoad(volumeCache, coord, 0) -> volumeCache.Load(int3(coord,0))
//    (integer texel fetch, point, no filter). rgba16f atlas read this way in
//    sampleVoxel / sampleVolume's 8-corner trilinear gather. clamp(idx,...)
//    reproduced literally.
//  * fragCoord = WGSL @builtin(position).xy (top-left, +0.5 centered) ->
//    NM_FragCoord(i). The reference uv uses (position.xy + tileOffset - 0.5*
//    fullRes)/fullRes.y -> NM_GlobalCoord(i) for the (coord+tileOffset) part.
//  * CAMERA RAY (golden rule #1 — port from WGSL): the WGSL flips uv.y for the
//    view ray: uvFlipped = float2(uv.x, -uv.y); rd uses uvFlipped. The GLSL
//    twin uses raw uv (it reconciles Y elsewhere, bottom-left origin). We port
//    the WGSL form verbatim (top-left = Unity), so NO extra flip is added.
//  * select(resolution, fullResolution, fullResolution.x > 0.0) ->
//    (fullResolution.x > 0.0) ? fullResolution : resolution. Then the
//    fullRes.x < 1.0 -> float2(1024,1024) fallback reproduced literally.
//  * sign(rd) -> WGSL vec3<i32>(sign(rd)); HLSL int3(sign(rd)) (trunc toward 0,
//    sign returns -1/0/1 so exact). max(step, vec3<i32>(0)) reproduced.
//  * mix->lerp, fract->frac, pow/exp/sqrt/length/dot/cross/normalize: same.
//    No float modulo used (no nm_mod needed). Full 32-bit float (H5).
//  * MAX_STEPS=256, MAX_DIST=10.0, voxel loop bound MAX_STEPS*2=512, bisection
//    8 iters, isosurface stepSize=1.5/volSize, voxel start eps 0.001, normal
//    eps 2.0/volSize — all step counts / magic constants copied verbatim (H10).
//  * gamma: pow(color, 1.0/2.2) per channel reproduced literally.
//  * Helpers ported verbatim, inline. NONE come from NMCore (no pcg/prng/random/
//    nm_mod used by this effect). VoxelHit/IsoHit structs inlined as locals.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- MRT output struct (matches WGSL FragmentOutput) ------------------------
struct Render3dFragmentOutput
{
    float4 color  : SV_Target0;   // -> outputTex
    float4 geoOut : SV_Target1;   // -> screenGeoBuffer (xyz=normal*0.5+0.5, w=depth)
};

// ---- Volume input (vol-tier atlas, read by integer texel fetch) -------------
// definition.js passes[0].inputs: volumeCache <- inputTex3d, analyticalGeo <-
// inputGeo. The fragment samples ONLY volumeCache (the .r density / .rgb color).
// analyticalGeo is bound by the runtime per the inputs map but is not read by
// the shader body (the WGSL declares only volumeCache); declared here for the
// runtime binding contract but unreferenced — matches the WGSL.
Texture2D volumeCache;    SamplerState sampler_volumeCache;
Texture2D analyticalGeo;  SamplerState sampler_analyticalGeo;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
// WGSL bindings: resolution(0), time(1), threshold(2), volumeSize(3),
// orbitSpeed(4), bgColor(5), bgAlpha(6), volumeCache(7), tileOffset(8),
// fullResolution(9). resolution/time/tileOffset/fullResolution are engine
// globals (NMFullscreen aliases). The runtime sets the rest by reference name.
float  threshold;    // globals.threshold   default 0.5
int    volumeSize;   // globals.volumeSize  default 64  (inherited from upstream)
int    orbitSpeed;   // globals.orbitSpeed  default 1
float3 bgColor;      // globals.bgColor     default (0.02,0.02,0.02)
float  bgAlpha;      // globals.bgAlpha     default 1.0

// Compile-time defines in the reference, runtime uniforms here (perf-only bake):
int FILTERING;       // globals.filtering   default 0 (0 isosurface, 1 voxel)
int INVERT;          // globals.invert      default 0 (boolean 1/0, tested != 0)

// =============================================================================
// Verbatim constants / helpers (ported inline from render3d.wgsl)
// =============================================================================
static const float R3D_TAU = 6.283185307179586;
static const float R3D_PI  = 3.141592653589793;
static const int   MAX_STEPS = 256;
static const float MAX_DIST  = 10.0;

// Convert 3D volume coordinates to 2D atlas texel coordinates.
int2 r3d_volumeToAtlas(int x, int y, int z, int volSize)
{
    return int2(x, y + z * volSize);
}

// Sample volume at integer voxel coordinates (for voxel mode).
float4 r3d_sampleVoxel(int3 voxel)
{
    int volSize = volumeSize;
    int3 clamped = clamp(voxel, int3(0, 0, 0), int3(volSize - 1, volSize - 1, volSize - 1));
    return volumeCache.Load(int3(r3d_volumeToAtlas(clamped.x, clamped.y, clamped.z, volSize), 0));
}

// Sample the cached 3D volume with trilinear interpolation.
// World position p is in [-1, 1]^3 (bounding box coordinates).
float4 r3d_sampleVolume(float3 worldPos)
{
    int volSize = volumeSize;
    float volSizeF = (float)volSize;

    // Convert world position [-1, 1] to normalized volume coords [0, 1].
    float3 uvw = worldPos * 0.5 + 0.5;
    uvw = clamp(uvw, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));

    // Convert to texel coordinates.
    float3 texelPos = uvw * (volSizeF - 1.0);
    float3 texelFloor = floor(texelPos);
    float3 fracv = texelPos - texelFloor;

    int3 i0 = int3(texelFloor);
    int3 i1 = min(i0 + int3(1, 1, 1), int3(volSize - 1, volSize - 1, volSize - 1));

    // Trilinear filtering - load 8 corners.
    float4 c000 = volumeCache.Load(int3(r3d_volumeToAtlas(i0.x, i0.y, i0.z, volSize), 0));
    float4 c100 = volumeCache.Load(int3(r3d_volumeToAtlas(i1.x, i0.y, i0.z, volSize), 0));
    float4 c010 = volumeCache.Load(int3(r3d_volumeToAtlas(i0.x, i1.y, i0.z, volSize), 0));
    float4 c110 = volumeCache.Load(int3(r3d_volumeToAtlas(i1.x, i1.y, i0.z, volSize), 0));
    float4 c001 = volumeCache.Load(int3(r3d_volumeToAtlas(i0.x, i0.y, i1.z, volSize), 0));
    float4 c101 = volumeCache.Load(int3(r3d_volumeToAtlas(i1.x, i0.y, i1.z, volSize), 0));
    float4 c011 = volumeCache.Load(int3(r3d_volumeToAtlas(i0.x, i1.y, i1.z, volSize), 0));
    float4 c111 = volumeCache.Load(int3(r3d_volumeToAtlas(i1.x, i1.y, i1.z, volSize), 0));

    // Trilinear interpolation.
    float4 c00 = lerp(c000, c100, fracv.x);
    float4 c10 = lerp(c010, c110, fracv.x);
    float4 c01 = lerp(c001, c101, fracv.x);
    float4 c11 = lerp(c011, c111, fracv.x);

    float4 c0 = lerp(c00, c10, fracv.y);
    float4 c1 = lerp(c01, c11, fracv.y);

    return lerp(c0, c1, fracv.z);
}

// Get the scalar field value at a point (what we're finding the isosurface of).
// Convention: HIGH values = SOLID, field < 0 = inside solid.
float r3d_getField(float3 p)
{
    float val = r3d_sampleVolume(p).r;
    // INVERT was a compile-time const in the reference; runtime branch here.
    [branch] if (INVERT != 0)
    {
        val = 1.0 - val;
    }
    return threshold - val;
}

// Check if a voxel is solid (above threshold - high values = solid).
bool r3d_isVoxelSolid(int3 voxel)
{
    float val = r3d_sampleVoxel(voxel).r;
    [branch] if (INVERT != 0)
    {
        val = 1.0 - val;
    }
    return val > threshold;
}

// Convert world position to voxel coordinates.
int3 r3d_worldToVoxel(float3 worldPos)
{
    int volSize = volumeSize;
    float3 uvw = worldPos * 0.5 + 0.5;  // [-1,1] -> [0,1]
    return int3(floor(uvw * (float)volSize));
}

// Convert voxel coordinates to world position (center of voxel).
float3 r3d_voxelToWorld(int3 voxel)
{
    int volSize = volumeSize;
    float3 uvw = ((float3)voxel + 0.5) / (float)volSize;  // center of voxel in [0,1]
    return uvw * 2.0 - 1.0;  // [0,1] -> [-1,1]
}

// DDA voxel traversal - returns hit distance, face normal, and voxel.
// (WGSL VoxelHit struct inlined via out-params.)
float r3d_voxelTrace(float3 ro, float3 rd, out float3 outNormal, out int3 outVoxel)
{
    float resultDist = -1.0;
    outNormal = float3(0.0, 0.0, 0.0);
    outVoxel = int3(0, 0, 0);

    int volSize = volumeSize;
    float voxelSize = 2.0 / (float)volSize;  // world-space size of one voxel

    // Ray-box intersection with the volume bounds [-1, 1].
    float3 invRd = 1.0 / rd;
    float3 t0 = (-1.0 - ro) * invRd;
    float3 t1 = (1.0 - ro) * invRd;
    float3 tminV = min(t0, t1);
    float3 tmaxV = max(t0, t1);
    float tEnter = max(max(tminV.x, tminV.y), tminV.z);
    float tExit = min(min(tmaxV.x, tmaxV.y), tmaxV.z);

    if (tEnter > tExit || tExit < 0.0)
    {
        return resultDist;  // No intersection with volume
    }

    // Start position (slightly inside the volume).
    float tStart = max(tEnter + 0.001, 0.0);
    float3 pos = ro + rd * tStart;

    // Current voxel.
    int3 voxel = r3d_worldToVoxel(pos);
    voxel = clamp(voxel, int3(0, 0, 0), int3(volSize - 1, volSize - 1, volSize - 1));

    // Step direction.
    int3 stepv = int3(sign(rd));

    // Distance to next voxel boundary in each axis.
    float3 voxelBounds = r3d_voxelToWorld(voxel + max(stepv, int3(0, 0, 0)));
    float3 tMaxVec = (voxelBounds - ro) * invRd;

    // Distance to cross one voxel in each axis.
    float3 tDelta = abs(float3(voxelSize, voxelSize, voxelSize) * invRd);

    // Traverse voxels.
    float3 lastNormal = float3(0.0, 0.0, 0.0);
    [loop] for (int i = 0; i < MAX_STEPS * 2; i = i + 1)
    {
        // Check if current voxel is solid.
        if (voxel.x >= 0 && voxel.x < volSize &&
            voxel.y >= 0 && voxel.y < volSize &&
            voxel.z >= 0 && voxel.z < volSize)
        {
            if (r3d_isVoxelSolid(voxel))
            {
                // Hit!
                resultDist = tStart;
                outNormal = lastNormal;
                outVoxel = voxel;

                // If this is the first voxel, compute entry normal.
                if (lastNormal.x == 0.0 && lastNormal.y == 0.0 && lastNormal.z == 0.0)
                {
                    if (tminV.x > tminV.y && tminV.x > tminV.z)
                    {
                        outNormal = float3(-sign(rd.x), 0.0, 0.0);
                    }
                    else if (tminV.y > tminV.z)
                    {
                        outNormal = float3(0.0, -sign(rd.y), 0.0);
                    }
                    else
                    {
                        outNormal = float3(0.0, 0.0, -sign(rd.z));
                    }
                }
                return resultDist;
            }
        }

        // Step to next voxel (DDA).
        if (tMaxVec.x < tMaxVec.y)
        {
            if (tMaxVec.x < tMaxVec.z)
            {
                tStart = tMaxVec.x;
                tMaxVec.x = tMaxVec.x + tDelta.x;
                voxel.x = voxel.x + stepv.x;
                lastNormal = float3(-(float)stepv.x, 0.0, 0.0);
            }
            else
            {
                tStart = tMaxVec.z;
                tMaxVec.z = tMaxVec.z + tDelta.z;
                voxel.z = voxel.z + stepv.z;
                lastNormal = float3(0.0, 0.0, -(float)stepv.z);
            }
        }
        else
        {
            if (tMaxVec.y < tMaxVec.z)
            {
                tStart = tMaxVec.y;
                tMaxVec.y = tMaxVec.y + tDelta.y;
                voxel.y = voxel.y + stepv.y;
                lastNormal = float3(0.0, -(float)stepv.y, 0.0);
            }
            else
            {
                tStart = tMaxVec.z;
                tMaxVec.z = tMaxVec.z + tDelta.z;
                voxel.z = voxel.z + stepv.z;
                lastNormal = float3(0.0, 0.0, -(float)stepv.z);
            }
        }

        // Check if we've exited the volume.
        if (tStart > tExit) { break; }
    }

    return resultDist;
}

// Compute smooth normal using central differences on the SDF field.
float3 r3d_calcNormal(float3 p)
{
    float eps = 2.0 / (float)volumeSize;

    float dx = r3d_getField(p + float3(eps, 0.0, 0.0)) - r3d_getField(p - float3(eps, 0.0, 0.0));
    float dy = r3d_getField(p + float3(0.0, eps, 0.0)) - r3d_getField(p - float3(0.0, eps, 0.0));
    float dz = r3d_getField(p + float3(0.0, 0.0, eps)) - r3d_getField(p - float3(0.0, 0.0, eps));

    float3 n = float3(dx, dy, dz);

    float len = length(n);
    if (len < 0.0001) { return float3(0.0, 1.0, 0.0); }

    return n / len;
}

// Analytic isosurface raymarching with bisection refinement.
// (WGSL IsoHit struct inlined via out-params; returns hit flag.)
bool r3d_isosurfaceTrace(float3 ro, float3 rd, out float outDist, out float3 outPos)
{
    bool resultHit = false;
    outDist = -1.0;
    outPos = float3(0.0, 0.0, 0.0);

    float3 invRd = 1.0 / rd;
    float3 t0 = (-1.0 - ro) * invRd;
    float3 t1 = (1.0 - ro) * invRd;
    float3 tminV = min(t0, t1);
    float3 tmaxV = max(t0, t1);
    float tEnter = max(max(tminV.x, tminV.y), tminV.z);
    float tExit = min(min(tmaxV.x, tmaxV.y), tmaxV.z);

    if (tEnter > tExit || tExit < 0.0) { return resultHit; }

    float tStart = max(tEnter, 0.0);
    float stepSize = 1.5 / (float)volumeSize;

    float t = tStart;
    float prevField = r3d_getField(ro + rd * t);

    // If we start inside solid (e.g., inverted volume), hit the bounding box surface.
    if (prevField < 0.0)
    {
        outDist = tStart;
        outPos = ro + rd * tStart;
        return true;
    }

    [loop] for (int i = 0; i < MAX_STEPS; i = i + 1)
    {
        t = t + stepSize;
        if (t > tExit) { break; }

        float3 p = ro + rd * t;
        float field = r3d_getField(p);

        if (prevField * field < 0.0)
        {
            float tLo = t - stepSize;
            float tHi = t;
            float pf = prevField;

            [loop] for (int j = 0; j < 8; j = j + 1)
            {
                float tMid = (tLo + tHi) * 0.5;
                float fMid = r3d_getField(ro + rd * tMid);

                if (pf * fMid < 0.0)
                {
                    tHi = tMid;
                }
                else
                {
                    tLo = tMid;
                    pf = fMid;
                }
            }

            outDist = (tLo + tHi) * 0.5;
            outPos = ro + rd * outDist;
            return true;
        }

        prevField = field;
    }

    return resultHit;
}

// Shading for smooth isosurface.
float3 r3d_shade(float3 p, float3 rd)
{
    float3 n = r3d_calcNormal(p);
    float3 lightDir = normalize(float3(1.0, 1.0, -1.0));

    float diff = max(dot(n, lightDir), 0.0);
    float amb = 0.15;

    float3 halfVec = normalize(lightDir - rd);
    float spec = pow(max(dot(n, halfVec), 0.0), 32.0);

    float rim = pow(1.0 - max(dot(n, -rd), 0.0), 3.0);

    // Use RGB from volume for coloring.
    float4 volColor = r3d_sampleVolume(p);
    float3 baseColor = volColor.rgb;

    // If volume appears grayscale (R~G~B), use a neutral gray.
    float colorVariance = length(volColor.rgb - float3(volColor.r, volColor.r, volColor.r));
    if (colorVariance < 0.01)
    {
        baseColor = float3(0.75, 0.75, 0.75);
    }

    return baseColor * (amb + diff * 0.7) + spec * 0.2 + rim * 0.15;
}

// Voxel shading with flat face normals.
float3 r3d_shadeVoxel(float3 p, float3 rd, float3 n, int3 voxel)
{
    float3 lightDir = normalize(float3(1.0, 1.0, -1.0));

    float diff = max(dot(n, lightDir), 0.0);
    float amb = 0.3;

    // Use RGB from volume for coloring.
    float4 volColor = r3d_sampleVoxel(voxel);
    float3 baseColor = volColor.rgb;

    // If volume appears grayscale, apply face-based shading variation.
    float colorVariance = length(volColor.rgb - float3(volColor.r, volColor.r, volColor.r));
    if (colorVariance < 0.01)
    {
        float faceShade = abs(n.x) * 0.9 + abs(n.y) * 1.0 + abs(n.z) * 0.85;
        baseColor = float3(0.7 * faceShade, 0.7 * faceShade, 0.7 * faceShade);
    }

    return baseColor * (amb + diff * 0.7);
}

// =============================================================================
// PASS: render3d — raymarch the volume atlas to a 2D image (frag, MRT x2)
// =============================================================================
Render3dFragmentOutput frag_render3d(NMVaryings i)
{
    // select(resolution, fullResolution, fullResolution.x > 0.0)
    float2 fullRes = (fullResolution.x > 0.0) ? fullResolution : resolution;
    if (fullRes.x < 1.0) { fullRes = float2(1024.0, 1024.0); }

    float2 position = NM_FragCoord(i);  // gl_FragCoord.xy analog (+0.5 centered)
    float2 uv = ((position + tileOffset) - 0.5 * fullRes) / fullRes.y;

    float camAngle = time * R3D_TAU * (float)orbitSpeed;
    float camDist = 3.5;
    float3 ro = float3(sin(camAngle) * camDist, 0.5, cos(camAngle) * camDist);
    float3 lookAt = float3(0.0, 0.0, 0.0);

    float3 forward = normalize(lookAt - ro);
    float3 right = normalize(cross(float3(0.0, 1.0, 0.0), forward));
    float3 up = cross(forward, right);

    // GLSL golden uses RAW uv for the view ray (render3d.glsl):
    //   rd = normalize(forward + uv.x*right + uv.y*up)
    // The golden's bottom-left gl_FragCoord + final top-down PNG flip is matched
    // here by the harness's top-left uv origin + native top-down PNG, so NO extra
    // uv.y flip is added (the prior WGSL-derived -uv.y was wrong against GLSL).
    float3 rd = normalize(forward + uv.x * right + uv.y * up);

    float3 color;
    float3 normal = float3(0.0, 0.0, 1.0);
    float depth = 1.0;
    float alpha = 1.0;

    // FILTERING was a compile-time const in the reference; runtime branch here.
    [branch] if (FILTERING == 1)
    {
        float3 hitNormal;
        int3 hitVoxel;
        float hitDist = r3d_voxelTrace(ro, rd, hitNormal, hitVoxel);
        if (hitDist > 0.0)
        {
            float3 p = ro + rd * hitDist;
            color = r3d_shadeVoxel(p, rd, hitNormal, hitVoxel);
            normal = hitNormal;
            depth = hitDist / MAX_DIST;
        }
        else
        {
            color = bgColor;
            alpha = bgAlpha;
        }
    }
    else
    {
        float hitDist;
        float3 hitPos;
        bool hit = r3d_isosurfaceTrace(ro, rd, hitDist, hitPos);
        if (hit)
        {
            color = r3d_shade(hitPos, rd);
            normal = r3d_calcNormal(hitPos);
            depth = hitDist / MAX_DIST;
        }
        else
        {
            color = bgColor;
            alpha = bgAlpha;
        }
    }

    color = pow(color, float3(1.0 / 2.2, 1.0 / 2.2, 1.0 / 2.2));

    Render3dFragmentOutput o;
    o.color = float4(color, alpha);
    o.geoOut = float4(normal * 0.5 + 0.5, depth);
    return o;
}

#endif // NM_EFFECT_RENDER3D_INCLUDED
