#ifndef NM_EFFECT_RENDERCUBEMAPSURFACE_INCLUDED
#define NM_EFFECT_RENDERCUBEMAPSURFACE_INCLUDED

// =============================================================================
// RenderCubemapSurface.hlsl — render/renderCubemapSurface (func: "renderCubemapSurface")
//
// Samples a 3D volume (volumeCache) along the per-face cube camera rays and shows
// the RAW, TRUE color of the field exactly as sampled — front-to-back
// emission/absorption, with NO lighting and NO gamma. The volume's red channel
// drives per-step opacity; RGB is the emitted color. (The lit isosurface/voxel
// "blob in space" view lives in the sibling renderCubemap3D.)
//
// Ported PIXEL-IDENTICALLY from the canonical GLSL/WGSL source (golden rule #1).
// atlasTexel + sampleVolume are render3d's trilinear atlas gather (verbatim); the
// only volume-specific code is intersectBox + the front-to-back integration loop.
//
// CAMERA RAY (the cube-specific math) — port the GLSL signs VERBATIM:
//   res = (fullResolution.x > 0.0) ? fullResolution : resolution;   // NO 1024 guard
//   uv  = ((fragCoord + tileOffset) - 0.5*res) / (0.5 * res.y);     // [-1,1] square
//   ro  = (0,0,0);  rd = normalize(cubeBasis * vec3(uv.x, -uv.y, 1));// 90° frustum
// NOTE the 0.5*res.y denominator and the -uv.y (GLSL & WGSL agree; matches the
// "port the GLSL signs" Y-origin reconciliation — NM_FragCoord + top-down readback
// align the origin, no extra flip). UNLIKE renderCubemap3D there is NO fullRes<1
// fallback here (the reference Surface shader omits it) — preserve that asymmetry.
//
// cubeBasis is the reference mat3 [right | up | forward] (column-major), bound by
// the runtime as a float4x4 (UniformBinder.BindMatrix3). The frag recovers the
// three columns explicitly and forms the column-vector product exactly as GLSL/WGSL
// do — independent of HLSL matrix storage / mul() convention.
//
// MRT (drawBuffers:2): SV_Target0 = color (-> outputTex), SV_Target1 = geoOut
// (-> screenGeoBuffer). The Surface renderer is a volumetric integral with no
// surface, so geoOut is the constant (0.5,0.5,0.5,1.0) (flat mid normal, far depth).
//
// NOTE: 3D / multi-output / raymarch effect → ships as a runtime-rendered Texture2D.
// No Shader Graph Custom Function wrapper (3D / multi-pass / MRT).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- MRT output struct (matches WGSL FragmentOutput) ------------------------
struct RenderCubemapSurfaceFragmentOutput
{
    float4 color  : SV_Target0;   // -> outputTex
    float4 geoOut : SV_Target1;   // -> screenGeoBuffer (constant flat geo)
};

// ---- Volume input (vol-tier atlas, read by integer texel fetch) -------------
// definition.js passes[0].inputs: volumeCache <- inputTex3d, analyticalGeo <-
// inputGeo. The fragment samples ONLY volumeCache; analyticalGeo is bound by the
// runtime per the inputs map but unreferenced (the GLSL/WGSL declare only
// volumeCache) — declared for the runtime binding contract, matching render3d.
Texture2D volumeCache;    SamplerState sampler_volumeCache;
Texture2D analyticalGeo;  SamplerState sampler_analyticalGeo;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
int      volumeSize;   // globals.volumeSize  default 64  (inherited from upstream)
float4x4 cubeBasis;    // globals.cubeBasis   default identity (engine-set per face)
float3   bgColor;      // globals.bgColor     default (0.02,0.02,0.02)
float    bgAlpha;      // globals.bgAlpha     default 1.0
float    density;      // globals.density     default 4.0
float    absorption;   // globals.absorption  default 1.0
float    emission;     // globals.emission    default 1.0

static const int MAX_STEPS = 256;

// Convert 3D volume coordinates to 2D atlas texel coordinates.
int2 rcs_volumeToAtlas(int x, int y, int z, int volSize)
{
    return int2(x, y + z * volSize);
}

// Sample the cached 3D volume with trilinear interpolation.
// World position p is in [-1, 1]^3 (bounding box coordinates).
float4 rcs_sampleVolume(float3 worldPos)
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
    float4 c000 = volumeCache.Load(int3(rcs_volumeToAtlas(i0.x, i0.y, i0.z, volSize), 0));
    float4 c100 = volumeCache.Load(int3(rcs_volumeToAtlas(i1.x, i0.y, i0.z, volSize), 0));
    float4 c010 = volumeCache.Load(int3(rcs_volumeToAtlas(i0.x, i1.y, i0.z, volSize), 0));
    float4 c110 = volumeCache.Load(int3(rcs_volumeToAtlas(i1.x, i1.y, i0.z, volSize), 0));
    float4 c001 = volumeCache.Load(int3(rcs_volumeToAtlas(i0.x, i0.y, i1.z, volSize), 0));
    float4 c101 = volumeCache.Load(int3(rcs_volumeToAtlas(i1.x, i0.y, i1.z, volSize), 0));
    float4 c011 = volumeCache.Load(int3(rcs_volumeToAtlas(i0.x, i1.y, i1.z, volSize), 0));
    float4 c111 = volumeCache.Load(int3(rcs_volumeToAtlas(i1.x, i1.y, i1.z, volSize), 0));

    // Trilinear interpolation.
    float4 c00 = lerp(c000, c100, fracv.x);
    float4 c10 = lerp(c010, c110, fracv.x);
    float4 c01 = lerp(c001, c101, fracv.x);
    float4 c11 = lerp(c011, c111, fracv.x);

    float4 c0 = lerp(c00, c10, fracv.y);
    float4 c1 = lerp(c01, c11, fracv.y);

    return lerp(c0, c1, fracv.z);
}

// Ray-box intersection against [-1,1]^3. Returns float2(tEnter, tExit), or
// float2(-1,-1) when there is no intersection (matches GLSL intersectBox).
float2 rcs_intersectBox(float3 ro, float3 rd)
{
    float3 invRd = 1.0 / rd;
    float3 t0 = (-1.0 - ro) * invRd;
    float3 t1 = (1.0 - ro) * invRd;
    float3 tminV = min(t0, t1);
    float3 tmaxV = max(t0, t1);
    float tEnter = max(max(tminV.x, tminV.y), tminV.z);
    float tExit = min(min(tmaxV.x, tmaxV.y), tmaxV.z);
    if (tEnter > tExit || tExit < 0.0)
    {
        return float2(-1.0, -1.0);
    }
    return float2(tEnter, tExit);
}

// =============================================================================
// PASS: renderCubemapSurface — front-to-back emission/absorption into one cube face
// =============================================================================
RenderCubemapSurfaceFragmentOutput frag_renderCubemapSurface(NMVaryings i)
{
    // select(resolution, fullResolution, fullResolution.x > 0.0). No fullRes<1 guard.
    float2 res = (fullResolution.x > 0.0) ? fullResolution : resolution;

    float2 position = NM_FragCoord(i);  // gl_FragCoord.xy analog (+0.5 centered)

    // Cube face: uv in [-1,1] (0.5*res.y denominator), 90-degree frustum. Camera at
    // the volume center looking out along the per-face basis. cubeBasis is the
    // reference mat3 [right | up | forward] (column-major), bound as a float4x4
    // (UniformBinder.BindMatrix3): recover the columns explicitly so the column-vector
    // product cubeBasis * float3(uv.x, -uv.y, 1) matches GLSL/WGSL exactly.
    float2 uv = ((position + tileOffset) - 0.5 * res) / (0.5 * res.y);
    float3 cbCol0 = float3(cubeBasis._m00, cubeBasis._m10, cubeBasis._m20);  // right
    float3 cbCol1 = float3(cubeBasis._m01, cubeBasis._m11, cubeBasis._m21);  // up
    float3 cbCol2 = float3(cubeBasis._m02, cubeBasis._m12, cubeBasis._m22);  // forward
    float3 ro = float3(0.0, 0.0, 0.0);
    float3 rd = normalize(uv.x * cbCol0 - uv.y * cbCol1 + cbCol2);

    // Front-to-back emission/absorption. NO gamma, NO lighting: the raw field
    // color shows through exactly as sampled.
    float3 col = float3(0.0, 0.0, 0.0);
    float trans = 1.0;
    float2 tb = rcs_intersectBox(ro, rd);
    if (tb.y > 0.0)
    {
        float t0 = max(tb.x, 0.0);
        float dt = (tb.y - t0) / (float)MAX_STEPS;
        float t = t0;
        [loop] for (int idx = 0; idx < MAX_STEPS; idx = idx + 1)
        {
            float4 s = rcs_sampleVolume(ro + rd * t);
            float a = 1.0 - exp(-s.r * density * absorption * dt);
            col += trans * a * s.rgb * emission;
            trans *= (1.0 - a);
            if (trans < 0.01) { break; }
            t += dt;
        }
    }

    float3 outc = col + bgColor * trans;

    RenderCubemapSurfaceFragmentOutput o;
    o.color = float4(outc, 1.0 - trans + bgAlpha * trans);
    o.geoOut = float4(0.5, 0.5, 0.5, 1.0);
    return o;
}

#endif // NM_EFFECT_RENDERCUBEMAPSURFACE_INCLUDED
