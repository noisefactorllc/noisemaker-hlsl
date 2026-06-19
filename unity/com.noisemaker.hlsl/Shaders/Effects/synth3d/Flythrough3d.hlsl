#ifndef NM_EFFECT_FLYTHROUGH3D_INCLUDED
#define NM_EFFECT_FLYTHROUGH3D_INCLUDED

// =============================================================================
// Flythrough3d.hlsl — synth3d/flythrough3d (func: "flythrough3d")
//
// 3D fractal flythrough VOLUME GENERATOR. Ported PIXEL-IDENTICALLY from the
// canonical WGSL source (top-left origin, no per-effect Y flip):
//   wgsl/precompute.wgsl   progName "precompute"   (frag_precompute)
//
// SINGLE PASS, VOLUME-WRITE + MRT (drawBuffers:2). The render target is a 2D
// ATLAS RenderTexture 64x4096 (volumeSize x volumeSize^2 = 64 slices of 64x64),
// rgba16f, written by this fragment. Each atlas texel maps to a (vx,vy,vz)
// voxel; the fragment samples camera-relative fractal world space at that voxel
// and writes:
//   SV_Target0 (color  -> volumeCache): rgba16f density field
//        = (normalizedDist, trap, iterRatio, 1.0)
//   SV_Target1 (geoOut  -> geoBuffer):  rgba16f geometry buffer
//        = (normal*0.5+0.5, normalizedDist)   [xyz=encoded normal, w=depth]
//
// The downstream render3d/renderLit3d effect RAYMARCHES this atlas into a 2D
// image. This effect performs NO raymarch — it only fills the volume.
//
// ATLAS (u,v) -> (vx,vy,vz) MAPPING (reproduced exactly from WGSL):
//   pixelCoord = int2(fragCoord.xy)              // fragCoord = atlas px center
//   vx = pixelCoord.x
//   vy = pixelCoord.y % volumeSize               // int %, trunc toward 0
//   vz = pixelCoord.y / volumeSize               // int /, trunc toward 0
// Bounds-rejected voxels write color=0 and geo=(0.5,0.5,0.5,0.0).
//
// PORTING-GUIDE / parity notes:
//  * fragCoord = WGSL @builtin(position).xy (top-left, +0.5 centered) ->
//    NM_FragCoord(i). The render target IS the atlas, so _NM_Resolution.xy is
//    the atlas size (64,4096) and NM_FragCoord yields atlas pixel coords. The
//    WGSL derives vx/vy/vz directly from fragCoord (it does NOT use tileOffset
//    or fullResolution for the voxel math). Reproduced literally.
//  * vec2i(fragCoord.xy) truncates toward zero; the non-negative atlas coords
//    make int2((int)..) exact. % and / on ints match WGSL (trunc toward 0); no
//    nm_positiveModulo needed (operands are non-negative).
//  * atan2(z.y, z.x) — WGSL arg order copied literally (H3).
//  * pow(r, n) / pow(r, n-1.0) reproduced verbatim (n may be negative; matches
//    WGSL pow semantics for r>0).
//  * 'noiseType' is the GPU uniform name for the 'type' global (WGSL reserves
//    'type'); declared as int noiseType.
//  * 'seed' is a FLOAT uniform here (WGSL: var<uniform> seed: f32) even though
//    definition.js types it int — the GPU binds it as f32. Declared float seed.
//  * hash() is declared verbatim though unused by the fragment (kept for source
//    fidelity; matches WGSL which also declares but never calls it).
//  * frac->frac, mix->lerp; no float modulo used. Helpers ported verbatim inline
//    per program. NONE come from NMCore (no pcg/prng/random/nm_mod used here).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
// time is the engine global (NMFullscreen alias). volumeSize drives the atlas
// dims AND the voxel slice math.
int   volumeSize;   // globals.volumeSize  default 64   (uniform "volumeSize")
int   noiseType;    // globals.type        default 0    (uniform "noiseType")
float power;        // globals.power       default 8.0  (uniform "power")
int   iterations;   // globals.iterations  default 12   (uniform "iterations")
float bailout;      // globals.bailout     default 4.0  (uniform "bailout")
float speed;        // globals.speed       default 0.2  (uniform "speed")
float voiSize;      // globals.voiSize     default 0.5  (uniform "voiSize")
float seed;         // globals.seed        default 0    (uniform "seed", bound f32)

static const float SAFETY_RADIUS = 0.08;
static const float FT3_PI  = 3.141592653589793;
static const float FT3_TAU = 6.283185307179586;

// ============================================================================
// FLYTHROUGH ENGINE - Orbital path through fractal interior
// ============================================================================

// Verbatim from WGSL (declared but unused by main; kept for source fidelity).
float ft3_hash(float n)
{
    return frac(sin(n + seed) * 43758.5453123);
}

// ============================================================================
// ORBIT PATH GENERATION
// ============================================================================

float3 ft3_trefoilKnot(float t, float scale)
{
    float p = 2.0;
    float q = 3.0;
    float r = 0.5 + 0.2 * cos(q * t);
    return scale * float3(
        r * cos(p * t),
        r * sin(p * t),
        0.3 * sin(q * t)
    );
}

float3 ft3_tiltedOrbit(float t, float scale)
{
    float tilt = 0.4;

    float a = 1.0;
    float b = 0.7;
    float3 pos = float3(
        a * cos(t),
        b * sin(t),
        0.0
    );

    float c = cos(tilt);
    float s = sin(tilt);
    pos = float3(pos.x, pos.y * c - pos.z * s, pos.y * s + pos.z * c);

    return scale * pos;
}

float3 ft3_lissajousOrbit(float t, float scale)
{
    float fx = 1.0;
    float fy = 1.618;
    float fz = 2.0;
    float px = 0.0;
    float py = FT3_PI * 0.5;
    float pz = FT3_PI * 0.25;

    return scale * float3(
        sin(fx * t + px),
        sin(fy * t + py) * 0.6,
        sin(fz * t + pz) * 0.4
    );
}

float3 ft3_getOrbitPosition(float t)
{
    float orbitScale = 0.7;
    int orbitType = (int)(seed * 3.0) % 3;

    if (orbitType == 0)
    {
        return ft3_trefoilKnot(t, orbitScale);
    }
    else if (orbitType == 1)
    {
        return ft3_tiltedOrbit(t, orbitScale);
    }
    else
    {
        return ft3_lissajousOrbit(t, orbitScale);
    }
}

float3 ft3_getOrbitTangent(float t)
{
    float dt = 0.01;
    float3 p0 = ft3_getOrbitPosition(t);
    float3 p1 = ft3_getOrbitPosition(t + dt);
    return normalize(p1 - p0);
}

float3 ft3_getWobbleOffset(float t, float3 tangent)
{
    float3 up = float3(0.0, 1.0, 0.0);
    if (abs(dot(tangent, up)) > 0.99)
    {
        up = float3(1.0, 0.0, 0.0);
    }
    float3 right = normalize(cross(tangent, up));
    float3 realUp = normalize(cross(right, tangent));

    float wobbleAmp = 0.15;
    float wx = sin(t * 2.7 + seed * FT3_PI) * wobbleAmp;
    float wy = sin(t * 1.9 + seed * FT3_TAU) * wobbleAmp * 0.7;

    return right * wx + realUp * wy;
}

// ============================================================================
// CAMERA STATE
// ============================================================================

struct FT3_CameraState
{
    float3 pos;
    float3 dir;
    float3 up;
};

FT3_CameraState ft3_getCameraState(float t)
{
    float orbitTime = t * speed * 0.3;

    float3 orbitPos = ft3_getOrbitPosition(orbitTime);
    float3 tangent  = ft3_getOrbitTangent(orbitTime);
    float3 wobble   = ft3_getWobbleOffset(orbitTime, tangent);
    float3 pos = orbitPos + wobble;

    float3 dir = tangent;

    float3 worldUp = float3(0.0, 1.0, 0.0);
    float3 right = normalize(cross(worldUp, dir));
    float3 up    = normalize(cross(dir, right));

    float roll = sin(orbitTime * 0.5) * 0.1;
    float3 rollRight = right * cos(roll) + up * sin(roll);
    up = normalize(cross(rollRight, dir));

    FT3_CameraState cs;
    cs.pos = pos;
    cs.dir = dir;
    cs.up  = up;
    return cs;
}

// ============================================================================
// FRACTAL DISTANCE ESTIMATORS
// ============================================================================

struct FT3_FractalResult
{
    float dist;
    float trap;
    float iterRatio;
};

FT3_FractalResult ft3_mandelbulb(float3 pos, float n, int maxIter, float bail)
{
    float3 z = pos;
    float dr = 1.0;
    float r = 0.0;
    float trap = 1e10;
    float iter = 0.0;

    for (int i = 0; i < maxIter; i++)
    {
        r = length(z);
        if (r > bail) { break; }

        trap = min(trap, r);

        float theta = acos(z.z / r);
        float phi = atan2(z.y, z.x);

        dr = pow(r, n - 1.0) * n * dr + 1.0;

        float zr = pow(r, n);
        float newTheta = theta * n;
        float newPhi = phi * n;

        z = zr * float3(
            sin(newTheta) * cos(newPhi),
            sin(newTheta) * sin(newPhi),
            cos(newTheta)
        );
        z += pos;

        iter += 1.0;
    }

    float dist = 0.5 * log(r) * r / dr;
    FT3_FractalResult result;
    result.dist = dist;
    result.trap = trap;
    result.iterRatio = iter / (float)maxIter;
    return result;
}

float3 ft3_boxFold(float3 z, float foldLimit)
{
    return clamp(z, float3(-foldLimit, -foldLimit, -foldLimit),
                    float3(foldLimit, foldLimit, foldLimit)) * 2.0 - z;
}

FT3_FractalResult ft3_mandelbox(float3 pos, float scale, int maxIter, float bail)
{
    float3 z = pos;
    float dr = 1.0;
    float trap = 1e10;
    float iter = 0.0;

    float foldLimit = 1.0;
    float minRadius2 = 0.25;
    float fixedRadius2 = 1.0;

    for (int i = 0; i < maxIter; i++)
    {
        z = ft3_boxFold(z, foldLimit);

        float r2 = dot(z, z);
        if (r2 < minRadius2)
        {
            float factor = fixedRadius2 / minRadius2;
            z *= factor;
            dr *= factor;
        }
        else if (r2 < fixedRadius2)
        {
            float factor = fixedRadius2 / r2;
            z *= factor;
            dr *= factor;
        }

        z = z * scale + pos;
        dr = dr * abs(scale) + 1.0;

        float planeTrap = min(min(abs(z.x), abs(z.y)), abs(z.z));
        trap = min(trap, planeTrap);

        iter += 1.0;

        if (length(z) > bail) { break; }
    }

    float r = length(z);
    float dist = r / abs(dr);
    FT3_FractalResult result;
    result.dist = dist;
    result.trap = trap;
    result.iterRatio = iter / (float)maxIter;
    return result;
}

FT3_FractalResult ft3_computeFractal(float3 p)
{
    if (noiseType == 0)
    {
        return ft3_mandelbulb(p, power, iterations, bailout);
    }
    else
    {
        return ft3_mandelbox(p, power, iterations, bailout);
    }
}

float3 ft3_computeGradient(float3 p, float eps)
{
    float d0 = ft3_computeFractal(p).dist;
    float dx = ft3_computeFractal(p + float3(eps, 0.0, 0.0)).dist;
    float dy = ft3_computeFractal(p + float3(0.0, eps, 0.0)).dist;
    float dz = ft3_computeFractal(p + float3(0.0, 0.0, eps)).dist;
    return float3(dx - d0, dy - d0, dz - d0) / eps;
}

// ============================================================================
// COLLISION AVOIDANCE
// ============================================================================

float3 ft3_applyCollisionAvoidance(float3 pos)
{
    FT3_FractalResult fr = ft3_computeFractal(pos);

    if (fr.dist < SAFETY_RADIUS)
    {
        float3 grad = ft3_computeGradient(pos, 0.01);
        float3 pushDir = normalize(grad + float3(1e-6, 1e-6, 1e-6));
        float pushDist = SAFETY_RADIUS - fr.dist;
        return pos + pushDir * pushDist * 1.5;
    }

    return pos;
}

// ============================================================================
// PASS: precompute — volume-write + geo MRT (frag_precompute)
//   SV_Target0 (color)  -> volumeCache
//   SV_Target1 (geoOut) -> geoBuffer
// ============================================================================

struct FT3_FragmentOutput
{
    float4 color  : SV_Target0;   // -> volumeCache (density field)
    float4 geoOut : SV_Target1;   // -> geoBuffer   (xyz=normal*0.5+0.5, w=depth)
};

FT3_FragmentOutput frag_precompute(NMVaryings i)
{
    int volSize = volumeSize;
    float volSizeF = (float)volSize;

    // fragCoord = atlas pixel-center coords (render target IS the atlas).
    float2 fragCoord = NM_FragCoord(i);

    int2 pixelCoord = int2((int)fragCoord.x, (int)fragCoord.y);
    int vx = pixelCoord.x;
    int vy = pixelCoord.y % volSize;
    int vz = pixelCoord.y / volSize;

    FT3_FragmentOutput o;

    if (vx >= volSize || vy >= volSize || vz >= volSize)
    {
        o.color  = float4(0.0, 0.0, 0.0, 0.0);
        o.geoOut = float4(0.5, 0.5, 0.5, 0.0);
        return o;
    }

    // Get camera state
    FT3_CameraState cam = ft3_getCameraState(time);

    // Apply collision avoidance
    float3 camPos = ft3_applyCollisionAvoidance(cam.pos);

    // Build camera basis
    float3 camRight = normalize(cross(cam.dir, cam.up));
    float3 camUp    = normalize(cross(camRight, cam.dir));

    // Convert voxel coords to normalized coords [-1,1]^3
    float3 normalizedCoord = (float3((float)vx, (float)vy, (float)vz) / (volSizeF - 1.0)) * 2.0 - 1.0;

    // VOI centered on camera, looking forward
    float halfExtent = voiSize * 0.5;
    float3 voiOffset = cam.dir * halfExtent;

    float3 worldPos = camPos + voiOffset
                    + camRight * normalizedCoord.x * halfExtent
                    + camUp    * normalizedCoord.y * halfExtent
                    + cam.dir  * normalizedCoord.z * halfExtent;

    // Compute fractal
    FT3_FractalResult fr = ft3_computeFractal(worldPos);

    // Distance to density mapping
    float dist = fr.dist;
    float normalizedDist = 1.0 - clamp(dist * 2.0 + 0.5, 0.0, 1.0);

    float trap = clamp(fr.trap * 0.5, 0.0, 1.0);
    float iterRatio = fr.iterRatio;

    // Compute normal from gradient
    float eps = 0.02;
    float3 gradient = ft3_computeGradient(worldPos, eps);
    float3 normal = normalize(gradient + float3(1e-6, 1e-6, 1e-6));

    o.color  = float4(normalizedDist, trap, iterRatio, 1.0);
    o.geoOut = float4(normal * 0.5 + 0.5, normalizedDist);
    return o;
}

#endif // NM_EFFECT_FLYTHROUGH3D_INCLUDED
