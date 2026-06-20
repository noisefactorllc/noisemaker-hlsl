#ifndef NM_EFFECT_RENDERCUBEMAP3D_INCLUDED
#define NM_EFFECT_RENDERCUBEMAP3D_INCLUDED

// =============================================================================
// RenderCubemap3D.hlsl — render/renderCubemap3D (func: "renderCubemap3D")
//
// A multi-face clone of render3d: it raymarches the SAME 3D volume atlas
// (volumeCache) with the SAME isosurface/voxel machinery, lighting and gamma —
// the only difference from render3d is the CAMERA. render3d orbits the volume
// (time/orbitSpeed); this renders one seamless CUBE FACE: the camera sits at the
// volume center looking out along a per-face orthonormal basis (cubeBasis), with
// a 90-degree frustum. Driving all 6 faces (the engine's RenderCubemap loop sets
// cubeBasis per face) produces a seamless cubemap. The raw true-color sampler
// lives in the sibling renderCubemapSurface.
//
// Ported PIXEL-IDENTICALLY from the canonical GLSL/WGSL source (golden rule #1).
// All helper functions below are render3d's, copy-pasted verbatim (the reference
// does the same), renamed r3d_ -> rc3_ since each effect inlines its own copy.
//
// CAMERA RAY (the ONLY cube-specific math) — port the GLSL signs VERBATIM:
//   uv = ((fragCoord + tileOffset) - 0.5*fullRes) / (0.5 * fullRes.y)  // [-1,1] sq
//   ro = (0,0,0);  rd = normalize(cubeBasis * vec3(uv.x, -uv.y, 1))    // 90° frustum
// NOTE the 0.5*fullRes.y denominator (2x render3d's /fullRes.y → the [-1,1] square
// that pairs with the z=1 frustum) and the -uv.y inside the basis multiply (GLSL &
// WGSL agree here; matches render3d's "port the GLSL signs" Y-origin reconciliation
// — NM_FragCoord + top-down readback already aligns the origin, no extra flip).
//
// cubeBasis is the reference mat3 [right | up | forward] (column-major), bound by
// the runtime as a float4x4 (3x3 in the upper-left; UniformBinder.BindMatrix3). The
// frag recovers the three columns explicitly and forms the column-vector product
// exactly as GLSL/WGSL do — independent of HLSL matrix storage / mul() convention.
//
// MRT (drawBuffers:2): SV_Target0 = color (-> outputTex), SV_Target1 = geoOut
// (-> screenGeoBuffer): xyz = normal*0.5+0.5, w = depth. Identical to render3d.
//
// FILTERING (isosurface vs voxel) and INVERT were compile-time defines / WGSL
// consts in the reference (perf-only DCE); here they are runtime int uniforms
// branched with [branch]; values identical. Defaults FILTERING=0, INVERT=0.
//
// NOTE: 3D / multi-output / raymarch effect → ships as a runtime-rendered Texture2D.
// No Shader Graph Custom Function wrapper (3D / multi-pass / MRT).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- MRT output struct (matches WGSL FragmentOutput) ------------------------
struct RenderCubemap3dFragmentOutput
{
    float4 color  : SV_Target0;   // -> outputTex
    float4 geoOut : SV_Target1;   // -> screenGeoBuffer (xyz=normal*0.5+0.5, w=depth)
};

// ---- Volume input (vol-tier atlas, read by integer texel fetch) -------------
// definition.js passes[0].inputs: volumeCache <- inputTex3d, analyticalGeo <-
// inputGeo. The fragment samples ONLY volumeCache (.r density / .rgb color).
// analyticalGeo is bound by the runtime per the inputs map but is not read by the
// shader body (the WGSL declares only volumeCache); declared for the runtime
// binding contract but unreferenced — matches the WGSL/render3d.
Texture2D volumeCache;    SamplerState sampler_volumeCache;
Texture2D analyticalGeo;  SamplerState sampler_analyticalGeo;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
// vs render3d: orbitSpeed/time dropped (no orbit camera), cubeBasis added.
float    threshold;    // globals.threshold   default 0.5
int      volumeSize;   // globals.volumeSize  default 64  (inherited from upstream)
float4x4 cubeBasis;    // globals.cubeBasis   default identity (engine-set per face)
float3   bgColor;      // globals.bgColor     default (0.02,0.02,0.02)
float    bgAlpha;      // globals.bgAlpha     default 1.0

// Compile-time defines in the reference, runtime uniforms here (perf-only bake):
int FILTERING;         // globals.filtering   default 0 (0 isosurface, 1 voxel)
int INVERT;            // globals.invert      default 0 (boolean 1/0, tested != 0)

// =============================================================================
// Verbatim constants / helpers (ported inline from renderCubemap3D.wgsl, which is
// render3d's machinery unchanged). r3d_ -> rc3_.
// =============================================================================
static const int   MAX_STEPS = 256;
static const float MAX_DIST  = 10.0;

// Convert 3D volume coordinates to 2D atlas texel coordinates.
int2 rc3_volumeToAtlas(int x, int y, int z, int volSize)
{
    return int2(x, y + z * volSize);
}

// Sample volume at integer voxel coordinates (for voxel mode).
float4 rc3_sampleVoxel(int3 voxel)
{
    int volSize = volumeSize;
    int3 clamped = clamp(voxel, int3(0, 0, 0), int3(volSize - 1, volSize - 1, volSize - 1));
    return volumeCache.Load(int3(rc3_volumeToAtlas(clamped.x, clamped.y, clamped.z, volSize), 0));
}

// Sample the cached 3D volume with trilinear interpolation.
// World position p is in [-1, 1]^3 (bounding box coordinates).
float4 rc3_sampleVolume(float3 worldPos)
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
    float4 c000 = volumeCache.Load(int3(rc3_volumeToAtlas(i0.x, i0.y, i0.z, volSize), 0));
    float4 c100 = volumeCache.Load(int3(rc3_volumeToAtlas(i1.x, i0.y, i0.z, volSize), 0));
    float4 c010 = volumeCache.Load(int3(rc3_volumeToAtlas(i0.x, i1.y, i0.z, volSize), 0));
    float4 c110 = volumeCache.Load(int3(rc3_volumeToAtlas(i1.x, i1.y, i0.z, volSize), 0));
    float4 c001 = volumeCache.Load(int3(rc3_volumeToAtlas(i0.x, i0.y, i1.z, volSize), 0));
    float4 c101 = volumeCache.Load(int3(rc3_volumeToAtlas(i1.x, i0.y, i1.z, volSize), 0));
    float4 c011 = volumeCache.Load(int3(rc3_volumeToAtlas(i0.x, i1.y, i1.z, volSize), 0));
    float4 c111 = volumeCache.Load(int3(rc3_volumeToAtlas(i1.x, i1.y, i1.z, volSize), 0));

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
float rc3_getField(float3 p)
{
    float val = rc3_sampleVolume(p).r;
    // INVERT was a compile-time const in the reference; runtime branch here.
    [branch] if (INVERT != 0)
    {
        val = 1.0 - val;
    }
    return threshold - val;
}

// Check if a voxel is solid (above threshold - high values = solid).
bool rc3_isVoxelSolid(int3 voxel)
{
    float val = rc3_sampleVoxel(voxel).r;
    [branch] if (INVERT != 0)
    {
        val = 1.0 - val;
    }
    return val > threshold;
}

// Convert world position to voxel coordinates.
int3 rc3_worldToVoxel(float3 worldPos)
{
    int volSize = volumeSize;
    float3 uvw = worldPos * 0.5 + 0.5;  // [-1,1] -> [0,1]
    return int3(floor(uvw * (float)volSize));
}

// Convert voxel coordinates to world position (center of voxel).
float3 rc3_voxelToWorld(int3 voxel)
{
    int volSize = volumeSize;
    float3 uvw = ((float3)voxel + 0.5) / (float)volSize;  // center of voxel in [0,1]
    return uvw * 2.0 - 1.0;  // [0,1] -> [-1,1]
}

// DDA voxel traversal - returns hit distance, face normal, and voxel.
// (WGSL VoxelHit struct inlined via out-params.)
float rc3_voxelTrace(float3 ro, float3 rd, out float3 outNormal, out int3 outVoxel)
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
    int3 voxel = rc3_worldToVoxel(pos);
    voxel = clamp(voxel, int3(0, 0, 0), int3(volSize - 1, volSize - 1, volSize - 1));

    // Step direction.
    int3 stepv = int3(sign(rd));

    // Distance to next voxel boundary in each axis.
    float3 voxelBounds = rc3_voxelToWorld(voxel + max(stepv, int3(0, 0, 0)));
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
            if (rc3_isVoxelSolid(voxel))
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
float3 rc3_calcNormal(float3 p)
{
    float eps = 2.0 / (float)volumeSize;

    float dx = rc3_getField(p + float3(eps, 0.0, 0.0)) - rc3_getField(p - float3(eps, 0.0, 0.0));
    float dy = rc3_getField(p + float3(0.0, eps, 0.0)) - rc3_getField(p - float3(0.0, eps, 0.0));
    float dz = rc3_getField(p + float3(0.0, 0.0, eps)) - rc3_getField(p - float3(0.0, 0.0, eps));

    float3 n = float3(dx, dy, dz);

    float len = length(n);
    if (len < 0.0001) { return float3(0.0, 1.0, 0.0); }

    return n / len;
}

// Analytic isosurface raymarching with bisection refinement.
// (WGSL IsoHit struct inlined via out-params; returns hit flag.)
bool rc3_isosurfaceTrace(float3 ro, float3 rd, out float outDist, out float3 outPos)
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
    float prevField = rc3_getField(ro + rd * t);

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
        float field = rc3_getField(p);

        if (prevField * field < 0.0)
        {
            float tLo = t - stepSize;
            float tHi = t;
            float pf = prevField;

            [loop] for (int j = 0; j < 8; j = j + 1)
            {
                float tMid = (tLo + tHi) * 0.5;
                float fMid = rc3_getField(ro + rd * tMid);

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
float3 rc3_shade(float3 p, float3 rd)
{
    float3 n = rc3_calcNormal(p);
    float3 lightDir = normalize(float3(1.0, 1.0, -1.0));

    float diff = max(dot(n, lightDir), 0.0);
    float amb = 0.15;

    float3 halfVec = normalize(lightDir - rd);
    float spec = pow(max(dot(n, halfVec), 0.0), 32.0);

    float rim = pow(1.0 - max(dot(n, -rd), 0.0), 3.0);

    // Use RGB from volume for coloring.
    float4 volColor = rc3_sampleVolume(p);
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
float3 rc3_shadeVoxel(float3 p, float3 rd, float3 n, int3 voxel)
{
    float3 lightDir = normalize(float3(1.0, 1.0, -1.0));

    float diff = max(dot(n, lightDir), 0.0);
    float amb = 0.3;

    // Use RGB from volume for coloring.
    float4 volColor = rc3_sampleVoxel(voxel);
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
// PASS: renderCubemap3D — raymarch the volume atlas to one cube face (frag, MRT x2)
// =============================================================================
RenderCubemap3dFragmentOutput frag_renderCubemap3D(NMVaryings i)
{
    // select(resolution, fullResolution, fullResolution.x > 0.0)
    float2 fullRes = (fullResolution.x > 0.0) ? fullResolution : resolution;
    if (fullRes.x < 1.0) { fullRes = float2(1024.0, 1024.0); }

    float2 position = NM_FragCoord(i);  // gl_FragCoord.xy analog (+0.5 centered)

    // Cube face: uv in [-1,1] (note the 0.5*fullRes.y denominator — 2x render3d's
    // /fullRes.y → the [-1,1] square that pairs with the z=1, 90-degree frustum).
    float2 uv = ((position + tileOffset) - 0.5 * fullRes) / (0.5 * fullRes.y);

    // Camera at the volume center looking out along the per-face basis. cubeBasis is
    // the reference mat3 [right | up | forward] (column-major), bound as a float4x4
    // (UniformBinder.BindMatrix3): recover the columns explicitly so the column-vector
    // product cubeBasis * float3(uv.x, -uv.y, 1) matches GLSL/WGSL exactly, regardless
    // of HLSL matrix storage/mul() convention. -uv.y matches the GLSL golden verbatim.
    float3 cbCol0 = float3(cubeBasis._m00, cubeBasis._m10, cubeBasis._m20);  // right
    float3 cbCol1 = float3(cubeBasis._m01, cubeBasis._m11, cubeBasis._m21);  // up
    float3 cbCol2 = float3(cubeBasis._m02, cubeBasis._m12, cubeBasis._m22);  // forward
    float3 ro = float3(0.0, 0.0, 0.0);
    float3 rd = normalize(uv.x * cbCol0 - uv.y * cbCol1 + cbCol2);

    float3 color;
    float3 normal = float3(0.0, 0.0, 1.0);
    float depth = 1.0;
    float alpha = 1.0;

    // FILTERING was a compile-time const in the reference; runtime branch here.
    [branch] if (FILTERING == 1)
    {
        float3 hitNormal;
        int3 hitVoxel;
        float hitDist = rc3_voxelTrace(ro, rd, hitNormal, hitVoxel);
        if (hitDist > 0.0)
        {
            float3 p = ro + rd * hitDist;
            color = rc3_shadeVoxel(p, rd, hitNormal, hitVoxel);
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
        bool hit = rc3_isosurfaceTrace(ro, rd, hitDist, hitPos);
        if (hit)
        {
            color = rc3_shade(hitPos, rd);
            normal = rc3_calcNormal(hitPos);
            depth = hitDist / MAX_DIST;
        }
        else
        {
            color = bgColor;
            alpha = bgAlpha;
        }
    }

    color = pow(color, float3(1.0 / 2.2, 1.0 / 2.2, 1.0 / 2.2));

    RenderCubemap3dFragmentOutput o;
    o.color = float4(color, alpha);
    o.geoOut = float4(normal * 0.5 + 0.5, depth);
    return o;
}

#endif // NM_EFFECT_RENDERCUBEMAP3D_INCLUDED
