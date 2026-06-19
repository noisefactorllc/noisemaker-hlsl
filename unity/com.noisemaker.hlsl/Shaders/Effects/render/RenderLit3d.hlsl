#ifndef NM_EFFECT_RENDERLIT3D_INCLUDED
#define NM_EFFECT_RENDERLIT3D_INCLUDED

// =============================================================================
// RenderLit3d.hlsl — render/renderLit3d (func: "renderLit3d")
//
// Universal 3D VOLUME RAYMARCHER with advanced (Blinn-Phong + rim) lighting.
// Ported PIXEL-IDENTICALLY from the canonical WGSL source (top-left origin, no
// per-effect Y flip):
//   wgsl/renderLit3d.wgsl   progName "render"   (fragmentMain)
//
// 3D / RENDER TIER — RAYMARCH CONSUMER (reference 04 §8, reference 10 §3):
//   * Single fullscreen pass ("render"), MRT (drawBuffers:2):
//       SV_Target0 (color)  -> outputTex        (lit RGB + alpha, gamma 1/2.2)
//       SV_Target1 (geoOut) -> screenGeoBuffer  (xyz = normal*0.5+0.5, w = depth)
//   * INPUT volume atlas: volumeCache (<- inputTex3d) is the vol-tier 2D ATLAS
//     RenderTexture, volumeSize x volumeSize^2 (default 64 x 4096 == 64 slices
//     of 64x64), rgba16f LINEAR. The shader RAYMARCHES it into a 2D image.
//     Atlas (x, y) <- voxel (vx, vy, vz):  atlasTexel = (vx, vy + vz*volSize).
//     Sampled via textureLoad -> .Load(int3(coord,0)) (integer texel fetch,
//     point, NO filtering). Trilinear filtering is done MANUALLY in sampleVolume
//     by fetching all 8 corners and lerping — reproduced verbatim.
//   * INPUT analyticalGeo (<- inputGeo): bound by the runtime but the WGSL body
//     NEVER samples it (normals come from finite-difference calcNormal on the
//     density field, or calcBoundaryNormal). Declared for binding parity only.
//
// PORTING-GUIDE / parity notes:
//  * Ported from WGSL (golden rule #1). The GLSL bisection loop MUTATES
//    `prevField` inside the refine loop; the WGSL uses a SEPARATE
//    `bisectPrevField`. We follow the WGSL (canonical) — see frag raymarch.
//  * textureLoad(t, vec2i, 0) -> t.Load(int3(coord, 0)). mix->lerp, fract->frac.
//  * select(a,b,cond) -> cond ? b : a (WGSL arg order reversed vs ternary).
//  * any(p < vec3f(-1.0)) -> componentwise OR. abs/sign/normalize/cross map 1:1.
//  * fragCoord = position.xy (@builtin(position), top-left, +0.5) -> NM_FragCoord.
//    uv = ((fragCoord + tileOffset) - 0.5*fullRes) / fullRes.y — divide by .y.
//  * fullRes select: fullResolution if x>0 else resolution; if x<1 -> 1024x1024.
//  * No nm_mod / pcg / random used by this effect. NONE of NMCore's primitives
//    are needed; helpers are ported verbatim inline.
//  * Loop bounds inclusive exactly as written: MAX_STEPS=256, bisection j<8.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input textures (runtime binds per definition.js inputs{}) --------------
// volumeCache  <- inputTex3d  : vol-tier atlas (read via Load, point fetch).
// analyticalGeo <- inputGeo   : geo-tier atlas (bound, NOT sampled by body).
Texture2D    volumeCache;   SamplerState sampler_volumeCache;
Texture2D    analyticalGeo; SamplerState sampler_analyticalGeo;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
int    volumeSize;          // globals.volumeSize        default 64
int    shape;               // globals.shape             default 0 (cube)
float  threshold;           // globals.threshold         default 0.5
int    invert;              // globals.invert            boolean (1/0), == 1
int    orbitSpeed;          // globals.orbitSpeed        default 1
float3 cameraPosition;      // globals.cameraPosition    default (0,0.1425,1)
float3 bgColor;             // globals.bgColor           default (0,0,0)
float  bgAlpha;             // globals.bgAlpha           default 1
float3 lightDirection;      // globals.lightDirection    default (0.5,0.5,1)
float3 diffuseColor;        // globals.diffuseColor      default (1,1,1)
float  diffuseIntensity;    // globals.diffuseIntensity  default 0.7
float3 specularColor;       // globals.specularColor     default (1,1,1)
float  specularIntensity;   // globals.specularIntensity default 0.3
float  shininess;           // globals.shininess         default 32
float  rimIntensity;        // globals.rimIntensity      default 0.15
float  rimPower;            // globals.rimPower          default 3
float3 ambientColor;        // globals.ambientColor      default (0.1,0.1,0.1)

// ---- Constants (verbatim from WGSL) -----------------------------------------
static const float NMR3_TAU       = 6.283185307179586;
static const float NMR3_PI        = 3.141592653589793;
static const int   NMR3_MAX_STEPS = 256;
static const float NMR3_MAX_DIST  = 10.0;
static const float NMR3_NEAR_CLIP = 0.01;

// Helper to convert 3D texel coords to 2D atlas texel coords
int2 r3_atlasTexel(int3 p, int volSize)
{
    return int2(p.x, p.y + p.z * volSize);
}

// Sample the cached 3D volume with trilinear interpolation
float4 r3_sampleVolume(float3 worldPos)
{
    int volSize = volumeSize;
    float volSizeF = (float)volSize;

    // Convert world position [-1, 1] to normalized volume coords [0, 1]
    float3 uvw = worldPos * 0.5 + 0.5;
    uvw = clamp(uvw, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));

    // Convert to texel coordinates
    float3 texelPos = uvw * (volSizeF - 1.0);
    float3 texelFloor = floor(texelPos);
    float3 fracv = texelPos - texelFloor;

    int3 i0 = int3(texelFloor);
    int3 i1 = min(i0 + 1, int3(volSize - 1, volSize - 1, volSize - 1));

    // Trilinear filtering - sample all 8 corners
    float4 c000 = volumeCache.Load(int3(r3_atlasTexel(int3(i0.x, i0.y, i0.z), volSize), 0));
    float4 c100 = volumeCache.Load(int3(r3_atlasTexel(int3(i1.x, i0.y, i0.z), volSize), 0));
    float4 c010 = volumeCache.Load(int3(r3_atlasTexel(int3(i0.x, i1.y, i0.z), volSize), 0));
    float4 c110 = volumeCache.Load(int3(r3_atlasTexel(int3(i1.x, i1.y, i0.z), volSize), 0));
    float4 c001 = volumeCache.Load(int3(r3_atlasTexel(int3(i0.x, i0.y, i1.z), volSize), 0));
    float4 c101 = volumeCache.Load(int3(r3_atlasTexel(int3(i1.x, i0.y, i1.z), volSize), 0));
    float4 c011 = volumeCache.Load(int3(r3_atlasTexel(int3(i0.x, i1.y, i1.z), volSize), 0));
    float4 c111 = volumeCache.Load(int3(r3_atlasTexel(int3(i1.x, i1.y, i1.z), volSize), 0));

    // Trilinear interpolation
    float4 c00 = lerp(c000, c100, fracv.x);
    float4 c10 = lerp(c010, c110, fracv.x);
    float4 c01 = lerp(c001, c101, fracv.x);
    float4 c11 = lerp(c011, c111, fracv.x);

    float4 c0 = lerp(c00, c10, fracv.y);
    float4 c1 = lerp(c01, c11, fracv.y);

    return lerp(c0, c1, fracv.z);
}

// Get the scalar field value at a point
float r3_getField(float3 p)
{
    float val = r3_sampleVolume(p).r;
    if (invert == 1)
    {
        val = 1.0 - val;
    }
    return threshold - val;
}

// Compute smooth normal using central differences
float3 r3_calcNormal(float3 p)
{
    float eps = 2.0 / (float)volumeSize;

    float dx = r3_getField(p + float3(eps, 0.0, 0.0)) - r3_getField(p - float3(eps, 0.0, 0.0));
    float dy = r3_getField(p + float3(0.0, eps, 0.0)) - r3_getField(p - float3(0.0, eps, 0.0));
    float dz = r3_getField(p + float3(0.0, 0.0, eps)) - r3_getField(p - float3(0.0, 0.0, eps));

    float3 n = float3(dx, dy, dz);
    float len = length(n);
    if (len < 0.0001)
    {
        return float3(0.0, 1.0, 0.0);
    }

    return n / len;
}

// Compute outward normal for bounding shape at position p
float3 r3_calcBoundaryNormal(float3 p)
{
    if (shape == 0)
    {
        // Cube: normal points outward from nearest face
        float3 absP = abs(p);
        if (absP.x > absP.y && absP.x > absP.z)
        {
            return float3(sign(p.x), 0.0, 0.0);
        }
        else if (absP.y > absP.z)
        {
            return float3(0.0, sign(p.y), 0.0);
        }
        else
        {
            return float3(0.0, 0.0, sign(p.z));
        }
    }
    else
    {
        // Sphere: normal is just the normalized position
        return normalize(p);
    }
}

// Ray-box intersection (cube shape)
float2 r3_intersectBox(float3 ro, float3 rd)
{
    float3 invRd = 1.0 / rd;
    float3 t0 = (-1.0 - ro) * invRd;
    float3 t1 = (1.0 - ro) * invRd;
    float3 tmin = min(t0, t1);
    float3 tmax = max(t0, t1);
    float tEnter = max(max(tmin.x, tmin.y), tmin.z);
    float tExit = min(min(tmax.x, tmax.y), tmax.z);

    if (tEnter > tExit || tExit < 0.0)
    {
        return float2(-1.0, -1.0);
    }
    return float2(tEnter, tExit);
}

// Ray-sphere intersection (radius 1 centered at origin)
float2 r3_intersectSphere(float3 ro, float3 rd)
{
    float b = dot(ro, rd);
    float c = dot(ro, ro) - 1.0;
    float disc = b * b - c;

    if (disc < 0.0)
    {
        return float2(-1.0, -1.0);
    }

    float sqrtDisc = sqrt(disc);
    float tEnter = -b - sqrtDisc;
    float tExit = -b + sqrtDisc;

    if (tExit < 0.0)
    {
        return float2(-1.0, -1.0);
    }
    return float2(tEnter, tExit);
}

// Get ray bounds based on selected shape
float2 r3_getRayBounds(float3 ro, float3 rd)
{
    float2 t;

    if (shape == 0)
    {
        t = r3_intersectBox(ro, rd);
    }
    else
    {
        t = r3_intersectSphere(ro, rd);
    }

    if (t.x < 0.0 && t.y < 0.0)
    {
        return float2(-1.0, -1.0);
    }

    // Apply near clip (handles camera inside volume)
    t.x = max(t.x, NMR3_NEAR_CLIP);

    return t;
}

// Isosurface hit result
struct R3_IsoHit
{
    float dist;
    float3 pos;
    bool hit;
    bool atBoundary;  // true if hit at bounding shape edge, not isosurface
};

// Raymarching with bisection refinement
R3_IsoHit r3_raymarch(float3 ro, float3 rd)
{
    R3_IsoHit result;
    result.hit = false;
    result.dist = -1.0;
    result.pos = float3(0.0, 0.0, 0.0);
    result.atBoundary = false;

    float2 bounds = r3_getRayBounds(ro, rd);
    if (bounds.x < 0.0)
    {
        return result;
    }

    float tStart = bounds.x;
    float tEnd = bounds.y;

    // Step size based on volume resolution
    float stepSize = 1.5 / (float)volumeSize;

    // March through volume
    float t = tStart;
    float prevField = r3_getField(ro + rd * t);

    // If we start inside solid, hit immediately at boundary
    if (prevField < 0.0)
    {
        result.hit = true;
        result.dist = tStart;
        result.pos = ro + rd * tStart;
        result.atBoundary = true;
        return result;
    }

    for (int i = 0; i < NMR3_MAX_STEPS; i++)
    {
        t += stepSize;
        if (t > tEnd)
        {
            break;
        }

        float3 p = ro + rd * t;

        // For bounded shapes, check if still in bounds
        if (shape == 0)
        {
            // Cube bounds check
            if (any(p < float3(-1.0, -1.0, -1.0)) || any(p > float3(1.0, 1.0, 1.0)))
            {
                break;
            }
        }
        else if (shape == 1)
        {
            // Sphere bounds check
            if (dot(p, p) > 1.0)
            {
                break;
            }
        }

        float field = r3_getField(p);

        // Check for sign change (threshold crossing)
        if (prevField * field < 0.0)
        {
            // Found crossing - refine with bisection
            float tLo = t - stepSize;
            float tHi = t;
            float bisectPrevField = prevField;

            for (int j = 0; j < 8; j++)
            {
                float tMid = (tLo + tHi) * 0.5;
                float fMid = r3_getField(ro + rd * tMid);

                if (bisectPrevField * fMid < 0.0)
                {
                    tHi = tMid;
                }
                else
                {
                    tLo = tMid;
                    bisectPrevField = fMid;
                }
            }

            result.hit = true;
            result.dist = (tLo + tHi) * 0.5;
            result.pos = ro + rd * result.dist;
            return result;
        }

        prevField = field;
    }

    return result;
}

// Advanced lighting calculation
float3 r3_applyLighting(float3 baseColor, float3 n_in, float3 rd, float3 worldLightDir)
{
    float3 lightDir = normalize(worldLightDir);
    float3 viewDir = -rd;

    // Ensure normal faces the camera
    float3 n = n_in;
    if (dot(n, viewDir) < 0.0)
    {
        n = -n;
    }

    // Ambient lighting
    float3 ambient = ambientColor * baseColor;

    // Diffuse lighting (Lambertian)
    float diffuseFactor = max(dot(n, lightDir), 0.0);
    float3 diffuse = diffuseColor * diffuseFactor * baseColor * diffuseIntensity;

    // Specular lighting (Blinn-Phong)
    float3 halfDir = normalize(lightDir + viewDir);
    float specAngle = max(dot(halfDir, n), 0.0);
    float specularFactor = pow(specAngle, shininess);
    float3 specular = specularColor * specularFactor * specularIntensity;

    // Fresnel rim lighting
    float rim = pow(1.0 - max(dot(n, viewDir), 0.0), rimPower);
    float3 rimLight = float3(rim, rim, rim) * rimIntensity;

    return ambient + diffuse + specular + rimLight;
}

// Shading - uses RGB from volume for coloring
float3 r3_shade(float3 p, float3 n, float3 rd, float3 worldLightDir)
{
    float4 volColor = r3_sampleVolume(p);
    float3 baseColor = volColor.rgb;

    // If volume appears grayscale, use neutral gray
    float colorVariance = length(volColor.rgb - float3(volColor.r, volColor.r, volColor.r));
    if (colorVariance < 0.01)
    {
        baseColor = float3(0.75, 0.75, 0.75);
    }

    return r3_applyLighting(baseColor, n, rd, worldLightDir);
}

// ============================================================================
// PASS: render — raymarch + lighting, MRT (frag_render)
//   SV_Target0 (color)  -> outputTex        (lit color, alpha)
//   SV_Target1 (geoOut) -> screenGeoBuffer  (xyz=normal*0.5+0.5, w=depth)
// ============================================================================
struct R3_FragmentOutput
{
    float4 color  : SV_Target0;   // -> outputTex
    float4 geoOut : SV_Target1;   // -> screenGeoBuffer
};

R3_FragmentOutput frag_render(NMVaryings i)
{
    // fullRes select: fullResolution if x>0 else resolution; if x<1 -> 1024.
    float2 fullRes = (fullResolution.x > 0.0) ? fullResolution : resolution;
    if (fullRes.x < 1.0)
    {
        fullRes = float2(1024.0, 1024.0);
    }

    float2 fragCoord = NM_FragCoord(i);
    float2 uv = ((fragCoord + tileOffset) - 0.5 * fullRes) / fullRes.y;

    // Camera setup - fixed position, volume rotates
    // Scale camera position from 0-1 UI range to world coords
    float3 ro = cameraPosition * float3(-1.0, 1.0, 1.0) * 3.5;

    // Camera looks at origin; handle case when at origin
    float3 forward;
    if (length(ro) < 0.001)
    {
        forward = float3(0.0, 0.0, -1.0);  // Default: look into volume
    }
    else
    {
        forward = normalize(-ro);  // Look toward origin
    }
    float3 worldUp = float3(0.0, 1.0, 0.0);
    // Handle looking straight up/down
    if (abs(dot(forward, worldUp)) > 0.999)
    {
        worldUp = float3(0.0, 0.0, 1.0);
    }
    float3 right = normalize(cross(worldUp, forward));
    float3 up = cross(forward, right);

    float3 rd = normalize(forward + uv.x * right + uv.y * up);

    // Light direction is fixed in world space (not view space)
    float3 worldLightDir = normalize(lightDirection * float3(-1.0, 1.0, 1.0));

    // Rotate ray into volume space
    float angle = time * NMR3_TAU * (float)orbitSpeed;
    float c = cos(angle);
    float s = sin(angle);
    // Rotation around Y axis
    float3 roVol = float3(ro.x * c + ro.z * s, ro.y, -ro.x * s + ro.z * c);
    float3 rdVol = float3(rd.x * c + rd.z * s, rd.y, -rd.x * s + rd.z * c);

    float3 color;
    float3 normal = float3(0.0, 0.0, 1.0);
    float depth = 1.0;
    float alpha = 1.0;

    R3_IsoHit hit = r3_raymarch(roVol, rdVol);
    if (hit.hit)
    {
        if (hit.atBoundary)
        {
            normal = r3_calcBoundaryNormal(hit.pos);
        }
        else
        {
            normal = r3_calcNormal(hit.pos);
        }
        // Rotate normal back to world space
        normal = float3(normal.x * c - normal.z * s, normal.y, normal.x * s + normal.z * c);
        // Use world-space rd for consistent lighting (normal is in world space)
        color = r3_shade(hit.pos, normal, rd, worldLightDir);
        depth = hit.dist / NMR3_MAX_DIST;
    }
    else
    {
        color = bgColor;
        alpha = bgAlpha;
    }

    // Gamma correction
    color = pow(color, float3(1.0 / 2.2, 1.0 / 2.2, 1.0 / 2.2));

    R3_FragmentOutput o;
    o.color  = float4(color, alpha);
    o.geoOut = float4(normal * 0.5 + 0.5, depth);
    return o;
}

#endif // NM_EFFECT_RENDERLIT3D_INCLUDED
